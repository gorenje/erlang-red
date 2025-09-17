-module(ered_node_assert_failure).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Assert node that fails if it receives a message. This is basically a node
%% that indicates paths that should not be reached.
%%

-import(ered_nodered_comm, [
    debug/3,
    node_status/5,
    ws_from/1
]).
-import(ered_nodes, [
    this_should_not_happen/2
]).

start(NodeDef, _WsName) ->
    ered_node:start(NodeDef, ?MODULE).

%%
%%
handle_event({stop, WsName}, NodeDef) ->
    case maps:find('_mc_incoming', NodeDef) of
        {ok, 0} ->
            node_status(WsName, NodeDef, "assert succeed", "green", "ring");
        _ ->
            ignore
    end,
    NodeDef;
handle_event(_, NodeDef) ->
    NodeDef.

handle_incoming(#{<<"id">> := IdStr, <<"type">> := TypeStr} = NodeDef, Msg) ->
    this_should_not_happen(
        NodeDef,
        io_lib:format(
            "Assert Error: Node should not have been reached [~p](~p) ~p\n",
            [TypeStr, IdStr, Msg]
        )
    ),

    Data = ?ObtainFrom(NodeDef)#{
        <<"_alias">> => IdStr,
        <<"msg">> => Msg,
        <<"topic">> => ?TopicFrom(Msg),
        <<"format">> => <<"object">>
    },

    debug(ws_from(Msg), Data, error),

    node_status(ws_from(Msg), NodeDef, "assert failed", "red", "dot"),

    {NodeDef, Msg}.

%%
%%
handle_msg({incoming, Msg}, NodeDef) ->
    {NodeDef2, Msg2} = handle_incoming(NodeDef, Msg),
    {handled, NodeDef2, Msg2};
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.
