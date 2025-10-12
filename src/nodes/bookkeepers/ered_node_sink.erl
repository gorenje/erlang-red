-module(ered_node_sink).

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Placeholder node where messages go to die. Sink node is a node but can
%% be used by other nodes to ignore configurations without errors.
%%
%% Similar to a ignore node but a sink node ignores incoming messages without
%% an error message.
%%

%%
%%
start(NodeDef, _WsName) ->
    ered_node:start(NodeDef, ?MODULE).

%%
%%
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg({incoming, _Msg}, NodeDef) ->
    {handled, NodeDef, dont_send_complete_msg};
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.
