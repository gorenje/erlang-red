-module(ered_node_disabled).

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% No Operation node that is used for all unknown types. It represents
%% a deadend for a message, it stops here.
%%

%%
%% if an disabled node receives a message its not an error, the design is
%% such that nodes do not know anything about other nodes so if a disabled
%% node is replaced by this, then so be it. Ignore the message and move on.
%%

%%
%%
start(NodeDef, _WsName) ->
    ered_node:start(NodeDef, ?MODULE).

%%
%%
handle_event(_, NodeDef) ->
    NodeDef.

handle_msg({incoming, Msg}, NodeDef) ->
    {handled, NodeDef, Msg};
handle_msg({outgoing, Msg}, NodeDef) ->
    {handled, NodeDef, Msg};
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.
