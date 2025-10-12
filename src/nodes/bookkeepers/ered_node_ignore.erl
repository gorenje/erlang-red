-module(ered_node_ignore).

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% This is for nodes that appear in the flow data but that its ok not to
%% implement and really they do nothing.
%%
%% For example, tab and comment nodes are both ignored. These nodes so not
%% receive messages, if they do, then an unhandled message error is raised.
%%
%% Similar to sink and ignore nodes but different. Ignore nodes can also be
%% used to highlight unsupported configurations of nodes that are otherwise
%% supported.
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
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.
