-module(ered_node_assert_success).

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% This assert node is simply being reached is success, if it never receives
%% a message, it fails.
%%

-import(ered_nodes, [
    get_prop_value_from_map/2,
    get_prop_value_from_map/3,
    this_should_not_happen/2
]).
-import(ered_nodered_comm, [
    debug/3,
    node_status/5
]).

%%
%%
start(NodeDef, _WsName) ->
    ered_node:start(NodeDef, ?MODULE).

%%
%%
%% erlfmt:ignore equals and arrows should line up here.
handle_event({stop,WsName}, NodeDef) ->
    case maps:find('_mc_incoming',NodeDef) of
        {ok,0} ->
            {ok, IdStr}   = maps:find(id,NodeDef),
            {ok, TypeStr} = maps:find(type,NodeDef),

            this_should_not_happen(
              NodeDef,
              io_lib:format("Assert Error: Node was not reached [~p](~p)\n",
                            [TypeStr,IdStr])
            ),

            IdStr   = get_prop_value_from_map(id,   NodeDef),
            ZStr    = get_prop_value_from_map(z,    NodeDef),
            NameStr = get_prop_value_from_map(name, NodeDef, TypeStr),
            Data = #{
                     id       => IdStr,
                     z        => ZStr,
                     '_alias' => IdStr,
                     path     => ZStr,
                     name     => NameStr,
                     topic    => <<"">>,
                     msg      => <<"Assert Success Not Reached">>,
                     format   => <<"string">>
            },

            debug(WsName, Data, error),
            node_status(WsName, NodeDef, "assert failed", "red", "dot");
        _ ->
            node_status(WsName, NodeDef, "assert succeed", "green", "ring")
    end,
    NodeDef;

handle_event(_, NodeDef) ->
    NodeDef.

%%
%% even though it does nothing with these messages, it still needs to
%% recieve them, after all it counts them.
handle_msg({incoming, Msg}, NodeDef) ->
    {handled, NodeDef, Msg};
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.
