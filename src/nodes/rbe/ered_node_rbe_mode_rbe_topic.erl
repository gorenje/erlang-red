-module(ered_node_rbe_mode_rbe_topic).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Module for the filter settings:
%%   -- block unless value changes (mode: rbe)
%%   -- apply mode separately for each topic (settopics: true)
%%
-import(ered_nodes, [
    jstr/2,
    send_msg_to_connected_nodes/2
]).
-import(ered_nodered_comm, [
    unsupported/3
]).
-import(ered_messages, [
    get_prop/2
]).

start(_, _) ->
    throw(should_not_be_called).

%%
%%
handle_event({registered, _WsName, _MyPid}, NodeDef) ->
    Store = ets:new(
        ered_node_rbe_mode_rbe_topic_store,
        [set, private, {write_concurrency, true}]
    ),
    NodeDef#{'_store' => Store};
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
%% handle the reset messages
handle_msg(
    {incoming, #{<<"reset">> := ResetValue} = Msg},
    #{
        <<"topi">> := GrpPropName,
        '_store' := Store
    } = NodeDef
) when ResetValue =:= true; ResetValue =:= <<"true">>; ResetValue =:= 1 ->
    case get_prop(GrpPropName, Msg) of
        {ok, Topic, _} ->
            ets:select_delete(Store, [{{Topic, '_'}, [], [true]}]);
        _ ->
            ets:select_delete(Store, [{{<<>>, '_'}, [], [true]}])
    end,
    send_msg_to_connected_nodes(NodeDef, Msg),
    {handled, NodeDef, Msg};
%%
handle_msg(
    {incoming, #{<<"reset">> := _ResetValue} = Msg},
    NodeDef
) ->
    %% Ignore any messages with reset set to something invalid.
    send_msg_to_connected_nodes(NodeDef, Msg),
    {handled, NodeDef, dont_send_complete_msg};
%% handle a new value - potentially
handle_msg(
    {incoming, Msg},
    #{
        <<"topi">> := GrpPropName,
        <<"property">> := PropName
    } = NodeDef
) ->
    case get_prop(PropName, Msg) of
        {ok, Payload, _} ->
            case get_prop(GrpPropName, Msg) of
                {ok, Topic, _} ->
                    check_topic_value(Topic, Payload, NodeDef, Msg);
                _ ->
                    check_topic_value(<<>>, Payload, NodeDef, Msg)
            end;
        _ ->
            {handled, NodeDef, dont_send_complete_msg}
    end;
%%
handle_msg(
    {incoming, _Msg},
    NodeDef
) ->
    %% ignore all other messages
    {handled, NodeDef, dont_send_complete_msg};
%%
%% fall through
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% ------------------ helpers
%%
check_topic_value(
    Topic,
    Payload,
    #{'_store' := Store} = NodeDef,
    Msg
) ->
    case ets:select(Store, [{{Topic, '_'}, [], ['$_']}]) of
        [{Topic, CurrentValue}] when CurrentValue =/= Payload ->
            ets:insert(Store, {Topic, Payload}),
            send_msg_to_connected_nodes(NodeDef, Msg),
            {handled, NodeDef, Msg};
        [] ->
            ets:insert(Store, {Topic, Payload}),
            send_msg_to_connected_nodes(NodeDef, Msg),
            {handled, NodeDef, Msg};
        _ ->
            {handled, NodeDef, dont_send_complete_msg}
    end.
