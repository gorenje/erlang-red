-module(ered_node_binary).

-include("ered_nodes.hrl").
-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Node implements the Packet type definition. Is the Erlang implementation of
%% this node --> https://flows.nodered.org/node/node-red-contrib-binary
%%
%% {
%%     "id": "92c658f48ba49e2d",
%%     "type": "binary",
%%     "z": "8f1ed58b183fe5d3",
%%     "name": "array collection",
%%     "property": "payload",
%%     "raise_exception_on_mismatch": false,
%%     "pattern": "x8, \nb8[3] => value,\nb16{b4 => f1,b12 => f2},\nb16{b6 => f3,b10 => f4}",
%%     "x": 760,
%%     "y": 737.25,
%%     "wires": [
%%         [
%%             "c3edf17855f8d494",
%%             "69204c5eb3eb248f"
%%         ]
%%     ]
%% }

-import(ered_nodered_comm, [
    node_status/5,
    node_status_clear/2,
    post_exception_or_debug/3,
    send_out_debug_msg/4,
    unsupported/3
]).

-import(ered_messages, [
    any_to_binary/1,
    get_prop/2
]).

-import(ered_nodes, [
    jstr/2,
    send_msg_to_connected_nodes/2
]).

%%
%%
start(#{<<"pattern">> := Pattern} = NodeDef, WsName) ->
    try
        case erl_packetparser:packetdef_to_erlang(binary_to_list(Pattern)) of
            {ok, ErlangCode} ->
                case erl_packetparser:evaluate_erlang(ErlangCode) of
                    {ok, Func} ->
                        %% io:format("Binary code: ~p~n", [ErlangCode]),
                        ?NodeStatus("ready", "green", "dot"),
                        spawn(fun() ->
                            clear_status_after_one_sec(WsName, NodeDef)
                        end),
                        ered_node:start(NodeDef#{'_func' => Func}, ?MODULE);
                    {error, ErrMsg} ->
                        post_exception_or_debug(
                            NodeDef, ?AddWsName(#{}), ErrMsg
                        ),
                        ?NodeStatus("eval erlang error", "red", "dot"),
                        ered_node:start(NodeDef, ered_node_ignore)
                end;
            {error, ErrMsg} ->
                post_exception_or_debug(NodeDef, ?AddWsName(#{}), ErrMsg),
                ?NodeStatus("parser error", "red", "dot"),
                ered_node:start(NodeDef, ered_node_ignore)
        end
    catch
        E:F:S ->
            ?PostExceptionOrDebug(E, F, S),
            ?NodeStatus("exception", "red", "dot"),
            ered_node:start(NodeDef, ered_node_ignore)
    end.

%%
%%
handle_event(_, NodeDef) ->
    NodeDef.

%%
%% erlfmt:ignore - alignment
handle_msg(
    {incoming, Msg},
    #{
        '_func' := Func,
        <<"property">> := PropName
    } = NodeDef
) ->
    case get_prop(PropName, Msg) of
        {ok, Value, _} ->
            try
                {ok, Hash, MatchedData, UnmatchedData} = Func(
                    any_to_binary(Value)
                ),
                send_msg_to_connected_nodes(NodeDef, Msg#{
                    <<"original">> => Value,
                    <<"payload">>  => stack_payload(PropName, Hash, Msg),
                    <<"matched">>  => MatchedData,
                    <<"rest">>     => binary_to_list(UnmatchedData)
                })
            catch
                E:F:_S ->
                    case
                        maps:get(
                            <<"raise_exception_on_mismatch">>, NodeDef, false
                        )
                    of
                        true ->
                            post_exception_or_debug(
                                NodeDef, Msg#{error_details => F}, E
                            );
                        _ ->
                            ignore
                    end
            end,
            {handled, NodeDef, Msg};
        _ ->
            ErrMsg = jstr("property not found '~p'", [PropName]),
            unsupported(NodeDef, Msg, ErrMsg),
            {handled, NodeDef, dont_send_complete_msg}
    end;
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% -------------- helpers
clear_status_after_one_sec(WsName, NodeDef) ->
    timer:sleep(1000),
    node_status_clear(WsName, NodeDef).

%% stack up the payloads. Even this is a chain of binary nodes,
%% then each is parsing a part of the stream.
stack_payload(
    <<"rest">>,
    Hash,
    #{<<"payload">> := ExistingPayload}
) when is_list(ExistingPayload) ->
    [Hash | ExistingPayload];
stack_payload(
    <<"rest">>,
    Hash,
    #{<<"payload">> := ExistingPayload}
) when is_map(ExistingPayload) ->
    [Hash, ExistingPayload];
stack_payload(_, Hash, _) ->
    Hash.
