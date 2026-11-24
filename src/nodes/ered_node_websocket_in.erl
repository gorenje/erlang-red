-module(ered_node_websocket_in).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%% Websocket in node that can either connect to or listen to a websocket
%% server.
%%
%% This implementation only supports the "connect to" version of the node.

%% {
%%     "id": "fdd625bfadca7ee0",
%%     "type": "websocket in",
%%     "z": "7a912b51f7a3b590",
%%     "name": "",
%%     "server": "", <--- listen to, if this is blank and client is set, then
%%     "client": "80ed3d41c0bd26f1", <--- its a "connect to" node.
%%     "x": 1088.75,
%%     "y": 883.75,
%%     "wires": [
%%         [
%%             "193555265c65ec01"
%%         ]
%%     ]
%% },
%%
%% The client config is something like:
%% {
%%     "id": "80ed3d41c0bd26f1",
%%     "type": "websocket-client",
%%     "path": "ws://erlangred-nodered-template:1880/cfg/comms",
%%     "tls": "", <--- set to another tls-config node for handling SSL
%%     "wholemsg": "true",
%%     "hb": "0", <--- send heartbeat interval in seconds, zero is no heartbeat
%%     "subprotocol": "",
%%     "headers": []
%% }
%%
%% the path configuration is a full URL with either 'ws://' or 'wss://' as
%% protocol. If wss is used, then tls is also set.
%%
-import(ered_nodes, [
    check_node_config/3,
    jstr/2,
    send_msg_to_connected_nodes/2
]).

-import(ered_messages, [
    convert_to_num/1,
    create_outgoing_msg/1
]).

-import(ered_nodered_comm, [
    node_status/5,
    unsupported/3
]).

-import(ered_websocket_manager, [
    listen_to/2
]).

%%
%%
start(
    #{<<"client">> := CfgNodeId, <<"server">> := <<"">>} = NodeDef, WsName
) when CfgNodeId =/= <<"">> ->
    case ered_config_store:retrieve_config_node(CfgNodeId, WsName) of
        {ok, #{<<"path">> := Path} = _Cfg} ->
            case uri_string:parse(Path) of
                {error, Reason} ->
                    io:format(
                        "Error Parsing Path : ~p ==> ~p~n",
                        [Path, Reason]
                    ),
                    ered_node:start(NodeDef, ered_node_ignore);
                UriMap ->
                    ered_node:start(
                        NodeDef#{'_listento' => UriMap, ?SetWsName},
                        ?MODULE
                    )
            end;
        {error, Error} ->
            io:format("Error looking up config : ~p~n", [Error]),
            ered_node:start(NodeDef, ered_node_ignore)
    end;
start(NodeDef, WsName) ->
    ErrMsg = jstr("unsupported configuration ~p", [NodeDef]),
    unsupported(NodeDef, {websocket, WsName}, ErrMsg),
    ered_node:start(NodeDef, ered_node_ignore).

%%
%%
handle_event(
    {registered, _WsName, MyPid},
    #{'_listento' := UriMap} = NodeDef
) ->
    ok = ered_websocket_manager:listen_to(UriMap, MyPid),
    NodeDef;
handle_event(
    {websocket, {frame, Frame}},
    #{?GetWsName} = NodeDef
) ->
    {outgoing, Msg} = create_outgoing_msg(WsName),
    Msg2 = Msg#{
        <<"payload">> => Frame
    },
    send_msg_to_connected_nodes(NodeDef, Msg2),

    NodeDef;
handle_event({websocket, connected}, #{?GetWsName} = NodeDef) ->
    ?NodeStatus("connected", "green", "dot"),
    NodeDef;
handle_event(_, NodeDef) ->
    NodeDef.

%%
%% Has no input port, handles no incoming messages.
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.
