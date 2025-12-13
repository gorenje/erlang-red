-module(ered_node_assert_debug).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Assert node for checking whether another node generated a debug
%% message for the debug panel.
%%

-import(ered_nodered_comm, [
    assert_failure/3,
    node_status/5
]).
-import(ered_nodes, [
    jstr/2,
    send_msg_to_connected_nodes/2
]).
-import(ered_ws_event_exchange, [
    subscribe/5
]).
-import(ered_messages, [
    create_outgoing_msg/1
]).

-define(TestSuccess, '_failed_' := false).

start(NodeDef, _WsName) ->
    ered_node:start(NodeDef#{'_failed_' => false}, ?MODULE).

%%
%%
handle_event(
    {registered, WsName, _Pid},
    #{
        <<"inverse">> := true,
        <<"scope">> := [TgtNodeId],
        ?NodePid
    } = NodeDef
) ->
    %% inverse means that there should be **no** debug message, this
    %% means that this node needs to subscribe too all types of debug
    %% messages.
    ered_ws_event_exchange:subscribe(WsName, TgtNodeId, debug, any, NodePid),
    NodeDef;
handle_event(
    {registered, WsName, _Pid},
    #{
        <<"inverse">> := false,
        <<"scope">> := [TgtNodeId],
        <<"msgtype">> := MsgType,
        ?NodePid
    } = NodeDef
) ->
    ered_ws_event_exchange:subscribe(
        WsName, TgtNodeId, debug, MsgType, NodePid
    ),
    NodeDef;
handle_event({registered, _WsName, _Pid}, NodeDef) ->
    NodeDef;
%%
%%
handle_event(
    {stop, WsName},
    #{<<"inverse">> := false, '_mc_websocket' := 0, ?NodePid} = NodeDef
) ->
    {ok, [NodeId]} = maps:find(<<"scope">>, NodeDef),
    ErrMsg = jstr("Expected debug from ~p\n", [NodeId]),
    assert_failure(NodeDef, WsName, ErrMsg),
    ered_ws_event_exchange:unsubscribe(WsName, NodePid),
    NodeDef;
handle_event(
    {stop, WsName},
    #{?TestSuccess, ?NodePid} = NodeDef
) ->
    % message received, must have been correct type, test passes
    node_status(WsName, NodeDef, "assert succeed", "green", "ring"),
    ered_ws_event_exchange:unsubscribe(WsName, NodePid),
    NodeDef;
handle_event(
    {stop, WsName},
    #{?NodePid} = NodeDef
) ->
    % Test result is asserted, i.e., inverse true and message received.
    ered_ws_event_exchange:unsubscribe(WsName, NodePid),
    NodeDef;
handle_event(_, NodeDef) ->
    NodeDef.

%%
%% Because the debug assert node registers for specific types,
%% this event will only be happening if the type matches.
%% So there is no need to check message types here.
%% If inverse is set, then this is an error.
handle_websocket(
    {debug, WsName, NodeId, _Type, _Data},
    #{<<"inverse">> := true} = NodeDef
) ->
    ErrMsg = jstr("No debug expected from ~p\n", [NodeId]),
    assert_failure(NodeDef, WsName, ErrMsg),
    NodeDef#{'_failed_' => true};
handle_websocket({debug, WsName, NodeId, Type, Data}, NodeDef) ->
    {outgoing, Msg} = create_outgoing_msg(WsName),
    send_msg_to_connected_nodes(NodeDef, Msg#{
       <<"debug">> => #{
          <<"type">> => Type,
          <<"nodeid">> => NodeId
       },
       <<"payload">> => Data
    }),
    NodeDef.

%%
%%
handle_msg({ws_event, Details}, NodeDef) ->
    {handled, handle_websocket(Details, NodeDef), empty};
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.
