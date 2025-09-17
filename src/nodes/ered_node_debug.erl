-module(ered_node_debug).

-include("ered_nodes.hrl").
-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Debug nodes has no outgoing wires.
%% Debug node dumps messages to the debug panel in the flow editor.
%% It's data is transmitted via a websocket to the browser.
%%

%% {
%%     "id": "bb5a08e8c74d6e06",
%%     "type": "debug",
%%     "z": "182731f54d855071",
%%     "name": "debug 1",
%%     "active": true, <<--- active is the toggle attached to the debug node
%%     "tosidebar": true,
%%     "console": false,
%%     "tostatus": false,
%%     "complete": "true", <<--- true, "payload" or "jsonata string"
%%     "targetType": "full", <<----- "full", "jsonata", "msg"
%%     "statusVal": "",
%%     "statusType": "auto", <<---- "auto" is "same as debug output" but isn't supported here.
%%     "x": 415,
%%     "y": 277,
%%     "wires": []
%% }

-import(ered_nodered_comm, [
    node_status/5,
    send_to_debug_sidebar/2,
    unsupported/3
]).
-import(ered_nodes, [
    jstr/2
]).
-import(ered_messages, [
    jsonata_eval_or_error_msg/2,
    retrieve_prop_value/2
]).

%%
%%
start(
    #{
        <<"tostatus">> := true,
        <<"statusType">> := <<"counter">>
    } = NodeDef,
    WsName
) ->
    node_status(WsName, NodeDef, 0, "blue", "ring"),
    ered_node:start(NodeDef, ?MODULE);
start(NodeDef, _WsName) ->
    ered_node:start(NodeDef, ?MODULE).

%%
%%
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg(
    {incoming, Msg},
    #{
        <<"active">> := true,
        <<"tosidebar">> := SideBar,
        <<"console">> := Console
    } =
        NodeDef
) ->
    handle_settings(SideBar, Console, NodeDef, Msg),
    handle_status_setting(NodeDef, Msg),
    {handled, NodeDef, Msg};
%%
handle_msg(
    {incoming, Msg},
    #{<<"active">> := false} = NodeDef
) ->
    handle_status_setting(NodeDef, Msg),
    {handled, NodeDef, Msg};
%%
%%
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%%
%% ------------------- Helpers
%%
%%
handle_settings(true, true, NodeDef, Msg) ->
    handle_log_to_console(NodeDef, Msg),
    send_to_debug_sidebar(NodeDef, Msg);
handle_settings(true, false, NodeDef, Msg) ->
    send_to_debug_sidebar(NodeDef, Msg);
handle_settings(false, true, NodeDef, Msg) ->
    handle_log_to_console(NodeDef, Msg);
handle_settings(_, _, _, _) ->
    ok.

%%
%%
handle_log_to_console(#{<<"name">> := <<>>}, Msg) ->
    io:format("DEBUG [undefined]: ~p\n", [Msg]);
handle_log_to_console(#{<<"name">> := NodeName}, Msg) ->
    io:format("DEBUG [~p]: ~p\n", [NodeName, Msg]).

%%
%%
handle_status_setting(
    #{
        <<"tostatus">> := true,
        <<"statusType">> := <<"msg">>,
        <<"statusVal">> := PropName
    } = NodeDef,
    #{?GetWsName} = Msg
) ->
    Val = retrieve_prop_value(PropName, Msg),
    node_status(WsName, NodeDef, Val, "grey", "dot");
handle_status_setting(
    #{
        <<"tostatus">> := true,
        <<"statusType">> := <<"counter">>,
        '_mc_incoming' := Cnt
    } = NodeDef,
    #{?GetWsName} = _Msg
) ->
    node_status(WsName, NodeDef, Cnt, "blue", "ring");
handle_status_setting(
    #{
        <<"tostatus">> := true,
        <<"statusType">> := <<"jsonata">>,
        <<"statusVal">> := Jsonata
    } = NodeDef,
    #{?GetWsName} = Msg
) ->
    Status = jsonata_eval_or_error_msg(Jsonata, Msg),
    node_status(WsName, NodeDef, Status, "blue", "ring");
handle_status_setting(
    #{
        <<"tostatus">> := true,
        <<"statusType">> := StatusType
    } = NodeDef,
    Msg
) ->
    unsupported(NodeDef, Msg, jstr("StatusType: ~p", [StatusType]));
handle_status_setting(#{<<"tostatus">> := false}, _) ->
    ok.
