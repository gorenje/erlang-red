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
%%
handle_msg(
    {incoming, Msg},
    #{<<"property">> := PropName, '_func' := Func} = NodeDef
) ->
    case get_prop(PropName, Msg) of
        {ok, Value, _} ->
            try
                {ok, Hash, MatchedData, UnmatchedData} = Func(any_to_binary(Value)),
                send_msg_to_connected_nodes(NodeDef, Msg#{
                     <<"original">> => Value,
                     <<"payload">> => Hash,
                     <<"matched">> => MatchedData,
                     <<"rest">> => UnmatchedData
                 })
            catch
                _E:_F:_S ->
                    %% A litte undecided what to do here, if the pattern
                    %% didn't match, post up an exception, is it an exception?
                    %% Not sure.
                    %post_exception_or_debug(NodeDef, Msg#{error_details => F}, E)
                    ignore_as_per_original_node
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
