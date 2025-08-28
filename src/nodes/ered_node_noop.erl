-module(ered_node_noop).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% No Operation node that is used for all unknown types. It represents
%% a deadend for a message, it stops here but with an error message.
%%

-import(ered_nodes, [
    get_prop_value_from_map/2,
    get_prop_value_from_map/3,
    jstr/2,
    this_should_not_happen/2
]).
-import(ered_nodered_comm, [
    debug/3,
    node_status/5
]).

%%
%%
start(NodeDef, WsName) ->
    {ok, TypeStr} = maps:find(<<"type">>, NodeDef),
    debug(WsName, create_data_for_debug(NodeDef, TypeStr), warning),
    ered_node:start(NodeDef, ?MODULE).

%%
%%
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg(
    {incoming, #{?GetWsName} = Msg},
    #{?GetIdStr, ?GetTypeStr} = NodeDef
) ->
    %%
    %% This output is for eunit testing. This does in fact does end
    %% up in the Node-RED frontend as a notice, but that's only
    %% because I changed the code after writing the initial comment.
    this_should_not_happen(
        NodeDef,
        io_lib:format(
            "Noop Node (incoming). Nothing Done for [~p](~p) ~p\n",
            [TypeStr, IdStr, Msg]
        )
    ),

    %%
    %% this output is for Node-RED frontend when doing unit testing
    %% inside node red.
    debug(WsName, create_data_for_debug(NodeDef, TypeStr), warning),

    %%
    %% again for node red, show a status value for the corresponding node.
    node_status(WsName, NodeDef, "type not implemented", "grey", "dot"),

    {handled, NodeDef, Msg};
%%
%%
handle_msg(
    {outgoing, #{?GetWsName} = Msg},
    #{?GetIdStr, ?GetTypeStr} = NodeDef
) ->
    %%
    %% This output is for eunit testing. This does in fact does end
    %% up in the Node-RED frontend as a notice, but that's only
    %% because I changed the code after writing the initial comment.
    this_should_not_happen(
        NodeDef,
        io_lib:format(
            "Noop Node (outgoing) Nothing Done for [~p](~p) ~p\n",
            [TypeStr, IdStr, Msg]
        )
    ),

    %%
    %% this output is for Node-RED frontend when doing unit testing
    %% inside node red.
    debug(WsName, create_data_for_debug(NodeDef, TypeStr), warning),

    %%
    %% again for node red, show a status value for the corresponding node.
    node_status(WsName, NodeDef, "type not implemented", "grey", "dot"),

    {handled, NodeDef, Msg};
%%
%%
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% --------------- helpers
%%
create_data_for_debug(NodeDef, TypeStr) ->
    D = ?BASE_DATA,

    D#{
        ?AddTopic(<<>>),
        <<"msg">> => jstr("node type '~s' is not implemented", [TypeStr]),
        <<"format">> => <<"string">>
    }.
