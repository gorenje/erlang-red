-module(ered_node_assert_success).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([
    start/2,
    handle_msg/2,
    handle_event/2
]).

%%
%% This assert node is simply being reached is success, if it never receives
%% a message, it fails.
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
-import(ered_messages, [
    convert_to_integer/1
]).

%%
%%
start(NodeDef, _WsName) ->
    ered_node:start(NodeDef, ?MODULE).

%%
%%
handle_event(
    {stop, WsName},
    #{
        <<"id">> := IdStr,
        <<"type">> := TypeStr,
        <<"count">> := ExpMsgCount,
        '_mc_incoming' := MsgCount
    } = NodeDef
) ->
    ExpMsgCountInt = convert_to_integer(ExpMsgCount),
    case ExpMsgCountInt of
        MsgCount ->
            ?NodeStatus("assert succeed", "green", "ring");
        _ ->
            this_should_not_happen(
                NodeDef,
                io_lib:format(
                    "Assert Error: Msg Count not matched [~p](~p) ~b != ~b\n",
                    [TypeStr, IdStr, ExpMsgCountInt, MsgCount]
                )
            ),

            D = ?BASE_DATA,

            Data = D#{
                <<"_alias">> => IdStr,
                <<"topic">> => <<"">>,
                <<"format">> => <<"string">>,
                <<"msg">> => jstr(
                    "Assert Success Msg Count Not Matched ~p != ~p",
                    [ExpMsgCountInt, MsgCount]
                )
            },

            debug(WsName, Data, error),
            ?NodeStatus(
                jstr(
                    "assert failed: mc ~p != ~p",
                    [ExpMsgCountInt, MsgCount]
                ),
                "red",
                "dot"
            )
    end,
    NodeDef;
handle_event(
    {stop, WsName},
    #{
        <<"id">> := IdStr,
        <<"type">> := TypeStr,
        '_mc_incoming' := MsgCount
    } = NodeDef
) ->
    case MsgCount of
        0 ->
            this_should_not_happen(
                NodeDef,
                io_lib:format(
                    "Assert Error: Node was not reached [~p](~p)\n",
                    [TypeStr, IdStr]
                )
            ),

            D = ?BASE_DATA,

            Data = D#{
                <<"_alias">> => IdStr,
                <<"topic">> => <<"">>,
                <<"msg">> => <<"Assert Success Not Reached">>,
                <<"format">> => <<"string">>
            },

            debug(WsName, Data, error),
            ?NodeStatus("assert failed", "red", "dot");
        _ ->
            ?NodeStatus("assert succeed", "green", "ring")
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
