-module(ered_node_erlcaptureio).

-behaviour(ered_node).

-include("ered_nodes.hrl").

-export([
    start/2,
    handle_msg/2,
    handle_event/2
]).

%%
%% Capture I/O messages from specific nodes and pass these on.
%%
%% This node is heavily dependent on the capture io exchange server.
%%

-import(ered_nodered_comm, [
    unsupported/3
]).

-import(ered_capture_io_exchange, [
    capture/3,
    capture_remove/2
]).

%%
%%

start(#{<<"scope">> := <<"group">>} = NodeDef, WsName) ->
    unsupported(NodeDef, {websocket, WsName}, "unsupported scope 'group'"),
    ered_node:start(NodeDef, ered_node_ignore);
start(#{<<"scope">> := <<"flow">>} = NodeDef, WsName) ->
    unsupported(NodeDef, {websocket, WsName}, "unsupported scope 'group'"),
    ered_node:start(NodeDef, ered_node_ignore);
start(
    #{<<"scope">> := NodeIds, <<"wires">> := Wires} = NodeDef, WsName
) when NodeIds =/= [], Wires =/= [[]] ->
    [capture(NodeId, Wires, WsName) || NodeId <- NodeIds],
    ered_node:start(NodeDef, ?MODULE);
start(NodeDef, _WsName) ->
    ered_node:start(NodeDef, ?MODULE).

%%
%%
handle_event(
    {stop, WsName}, #{<<"scope">> := NodeIds} = NodeDef
) when NodeIds =/= [] ->
    [capture_remove(NodeId, WsName) || NodeId <- NodeIds],
    NodeDef;
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.
