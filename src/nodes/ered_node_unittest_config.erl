-module(ered_node_unittest_config).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% this node just returns the configuration setup for the unit testing.
%%

-import(ered_nodes, [
    send_msg_to_connected_nodes/2
]).

-import(ered_nodes, [
    jstr/1
]).

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
handle_msg({incoming, Msg}, NodeDef) ->
    Msg2 = Msg#{
        <<"utcfg">> => #{
            <<"priv">> => jstr(code:priv_dir(erlang_red)),
            <<"host">> => jstr(ered_webserver:host_url())
        }
    },
    send_msg_to_connected_nodes(NodeDef, Msg2),
    {handled, NodeDef, Msg2};
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.
