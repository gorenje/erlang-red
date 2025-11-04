-module(ered_node_rbe_mode_narrowbandeq).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Module for the filter settings:
%%   -- mode: narrowbandEq - block if value change is >=
%%   -- Don't apply mode separately for each topic (settopics: false)
%%
%% "id": "1d6080fae6ad4519",
%% "type": "rbe",
%% "z": "6ea4c6b373eeaa8d",
%% "g": "83bed288b0431f74",
%% "name": "...",
%% "func": "narrowbandEq",
%% "gap": "10%",  <<---- difference either absolute or percent
%% "start": "", <<--- initial value
%% "inout": "in",
%% "septopics": false,
%% "property": "payload",
%% "topi": "topic",
%% "x": 1132.7779235839844,
%% "y": 151.94444131851196,
%% "wires": [
%%

-import(ered_nodes, [
    jstr/2,
    send_msg_to_connected_nodes/2
]).
-import(ered_messages, [
    convert_to_num/1,
    get_prop/2
]).

start(_, _) ->
    throw(should_not_be_called).

%%
%%
handle_event(
    {registered, _WsName, _MyPid},
    #{<<"start">> := <<>>, <<"gap">> := Gap} = NodeDef
) ->
    maps:merge(
        NodeDef#{'_lastvalue' => undefined},
        gap_convert(binary_to_list(Gap))
    );
handle_event(
    {registered, _WsName, _MyPid},
    #{<<"start">> := Value, <<"gap">> := Gap} = NodeDef
) ->
    maps:merge(
        NodeDef#{'_lastvalue' => convert_to_num(Value)},
        gap_convert(binary_to_list(Gap))
    );
handle_event(_, NodeDef) ->
    NodeDef.

%%
%% Reset messages
handle_msg(
    {incoming, #{<<"reset">> := Value} = Msg},
    NodeDef
) when Value =:= true; Value =:= <<"true">>; Value =:= 1 ->
    send_msg_to_connected_nodes(NodeDef, Msg),
    {handled, NodeDef#{'_lastvalue' => undefined}, Msg};
handle_msg(
    {incoming, #{<<"reset">> := _Value} = Msg},
    NodeDef
) ->
    send_msg_to_connected_nodes(NodeDef, Msg),
    {handled, NodeDef, dont_send_complete_msg};
%%
%%
handle_msg(
    {incoming, Msg},
    #{
        '_lastvalue' := undefined,
        <<"property">> := PropName
    } = NodeDef
) ->
    case get_prop(PropName, Msg) of
        {ok, Payload, _} ->
            send_msg_to_connected_nodes(NodeDef, Msg),
            {handled, NodeDef#{'_lastvalue' => convert_to_num(Payload)}, Msg};
        _ ->
            {handled, NodeDef, dont_send_complete_msg}
    end;
%%
handle_msg(
    {incoming, Msg},
    #{
        '_lastvalue' := LastValue,
        <<"property">> := PropName
    } = NodeDef
) ->
    case get_prop(PropName, Msg) of
        {ok, Payload, _} ->
            NodeDef2 = is_greater_equal_to(
                LastValue,
                convert_to_num(Payload),
                NodeDef,
                Msg
            ),
            {handled, NodeDef2, Msg};
        _ ->
            {handled, NodeDef, dont_send_complete_msg}
    end;
%%
%% fall through
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% -------------- helpers
%%
is_greater_equal_to(
    LastValue,
    PayloadNum,
    #{
        '_gap' := Gap,
        <<"inout">> := <<"in">>
    } = NodeDef,
    Msg
) ->
    (abs(PayloadNum - LastValue) < Gap) andalso
        send_msg_to_connected_nodes(NodeDef, Msg),
    NodeDef#{'_lastvalue' => PayloadNum};
is_greater_equal_to(
    LastValue,
    PayloadNum,
    #{
        '_gap' := Gap,
        <<"inout">> := <<"out">>
    } = NodeDef,
    Msg
) ->
    case (abs(PayloadNum - LastValue) < Gap) of
        true ->
            send_msg_to_connected_nodes(NodeDef, Msg),
            NodeDef#{'_lastvalue' => PayloadNum};
        false ->
            NodeDef
    end;
%%
is_greater_equal_to(
    LastValue,
    PayloadNum,
    #{
        '_gappercent' := GapPercent,
        <<"inout">> := <<"in">>
    } = NodeDef,
    Msg
) ->
    Gap = erlang:abs(LastValue * GapPercent),
    (abs(PayloadNum - LastValue) < Gap) andalso
        send_msg_to_connected_nodes(NodeDef, Msg),
    NodeDef#{'_lastvalue' => PayloadNum};
is_greater_equal_to(
    LastValue,
    PayloadNum,
    #{
        '_gappercent' := GapPercent,
        <<"inout">> := <<"out">>
    } = NodeDef,
    Msg
) ->
    Gap = erlang:abs(LastValue * GapPercent),
    case (abs(PayloadNum - LastValue) < Gap) of
        true ->
            send_msg_to_connected_nodes(NodeDef, Msg),
            NodeDef#{'_lastvalue' => PayloadNum};
        false ->
            NodeDef
    end.

%%
%%
gap_convert(Gap) ->
    case lists:suffix("%", Gap) of
        true ->
            %% Percent value
            [$% | Num] = lists:reverse(Gap),
            Val = convert_to_num(lists:reverse(Num)),
            #{'_gappercent' => Val / 100};
        false ->
            #{'_gap' => convert_to_num(Gap)}
    end.
