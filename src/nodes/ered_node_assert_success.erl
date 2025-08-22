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
start(#{<<"count">> := C} = NodeDef, _WsName) ->
    ered_node:start(NodeDef#{<<"count">> => convert_to_integer(C)}, ?MODULE);
start(NodeDef, _WsName) ->
    ered_node:start(NodeDef#{<<"count">> => 1}, ?MODULE).

%%
%% Test has completed, msg count expected was zero
%%
handle_event(
    {stop, WsName},
    #{
        <<"count">> := 0,
        '_mc_incoming' := MsgCount
    } = NodeDef
) when MsgCount > 0 ->
    ?NodeStatus(jstr("assert succeed: mc ~b", [MsgCount]), "green", "ring");
%%
handle_event(
    {stop, WsName},
    #{
        <<"count">> := 0
    } = NodeDef
) ->
    this_should_not_happen(
        NodeDef,
        io_lib:format(
            "Assert Error: No message received when at least one was required",
            []
        )
    ),
    ?NodeStatus("assert failed", "red", "dot");
%%
%% Expected message count > 0
%%
handle_event(
    {stop, WsName},
    #{
        <<"id">> := IdStr,
        <<"type">> := TypeStr,
        <<"count">> := ExpMsgCount,
        '_mc_incoming' := MsgCount
    } = NodeDef
) when ExpMsgCount > 0 ->
    case ExpMsgCount of
        MsgCount ->
            ?NodeStatus("assert succeed", "green", "ring");
        _ ->
            this_should_not_happen(
                NodeDef,
                io_lib:format(
                    "Assert Error: Msg Count not matched [~p](~p) ~b != ~b\n",
                    [TypeStr, IdStr, ExpMsgCount, MsgCount]
                )
            ),

            D = ?BASE_DATA,

            Data = D#{
                <<"_alias">> => IdStr,
                <<"topic">> => <<"">>,
                <<"format">> => <<"string">>,
                <<"msg">> => jstr(
                    "Assert Success Msg Count Not Matched ~p != ~p",
                    [ExpMsgCount, MsgCount]
                )
            },

            debug(WsName, Data, error),
            ?NodeStatus(
                jstr(
                    "assert failed: mc ~p != ~p",
                    [ExpMsgCount, MsgCount]
                ),
                "red",
                "dot"
            )
    end,
    NodeDef;
%%
%% What? How did we get here! Unhandled stop event.
%%
handle_event(
    {stop, WsName},
    NodeDef
) ->
    this_should_not_happen(
        NodeDef,
        io_lib:format(
            "Assert Error: failed",
            []
        )
    ),
    ?NodeStatus("assert failed", "red", "dot");
handle_event(_, NodeDef) ->
    NodeDef.

%%
%% even though it does nothing with these messages, it still needs to
%% recieve them, after all it counts them.
handle_msg({incoming, Msg}, NodeDef) ->
    {handled, NodeDef, Msg};
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.
