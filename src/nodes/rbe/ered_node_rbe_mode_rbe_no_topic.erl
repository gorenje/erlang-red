-module(ered_node_rbe_mode_rbe_no_topic).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Module for the filter settings:
%%   -- block unless value changes (mode: rbe)
%%   -- Don't apply mode separately for each topic (settopics: false)
%%

-import(ered_nodes, [
    jstr/2,
    send_msg_to_connected_nodes/2
]).
-import(ered_messages, [
    get_prop/2
]).

start(_,_) ->
    throw(should_not_be_called).

%%
%%
handle_event({registered, _WsName, _MyPid}, NodeDef) ->
    NodeDef#{'_lastvalue' => undefined};
handle_event(_, NodeDef) ->
    NodeDef.

%%
%% Not per-topic filtering
handle_msg(
    {incoming,
     #{ <<"reset">> := Value } = Msg},
    NodeDef
) when Value =:= true; Value =:= <<"true">>; Value =:= 1 ->
    {handled, NodeDef#{'_lastvalue' => undefined}, dont_send_complete_msg};

handle_msg(
    {incoming,
     #{<<"reset">> := _Value } = _Msg},
    NodeDef
) ->
    {handled, NodeDef, dont_send_complete_msg};

handle_msg(
    {incoming, Msg},
    #{
        '_lastvalue' := undefined,
        <<"property">> := PropName
    } = NodeDef
) ->
    case get_prop(PropName, Msg) of
        {ok, Payload, _} ->
            send_msg_to_connected_nodes(NodeDef, Msg),
            {handled, NodeDef#{'_lastvalue' => Payload}, Msg};
        _ ->
            {handled, NodeDef, dont_send_complete_msg}
    end;
%%
handle_msg(
    {incoming, Msg},
    #{
        '_lastvalue' := Value,
        <<"property">> := PropName
    } = NodeDef
) ->
    case get_prop(PropName, Msg) of
        {ok, Value, _} ->
            {handled, NodeDef, dont_send_complete_msg};
        {ok, Payload, _} ->
            send_msg_to_connected_nodes(NodeDef, Msg),
            {handled, NodeDef#{'_lastvalue' => Payload}, Msg};
        _ ->
            {handled, NodeDef, dont_send_complete_msg}
    end;

%%
%% fall through
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.
