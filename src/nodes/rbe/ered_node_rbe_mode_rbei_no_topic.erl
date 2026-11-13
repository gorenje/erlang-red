-module(ered_node_rbe_mode_rbei_no_topic).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Module for the filter settings:
%%   -- block unless value changes but igore the initial value (mode: rbei)
%%   -- Don't apply mode separately for each topic (settopics: false)
%%

-import(ered_nodes, [
    jstr/2,
    send_msg_to_connected_nodes/2
]).
-import(ered_messages, [
    get_prop/2
]).

start(_, _) ->
    throw(should_not_be_called).

%%
%%
handle_event({registered, _WsName, _MyPid}, NodeDef) ->
    NodeDef#{'_lastvalue' => undefined};
handle_event(_, NodeDef) ->
    NodeDef.

%%
%% Reset messages.
%%
%% This has a number of nuances:
%%
%%   - reset and payload value that is the same as the initial value
%%      --> _lastvalue set to payload and no message is sent
%%   - reset and no payload value set
%%      --> don't send reset message and set the lastvalue to undefined
%%   - reset and payload set to something else than the initial value
%%      --> _lastvalue is reset and no message is sent.
%%
%% Also the value of the reset is ignored, it's only important that the
%% 'reset' property is set.

handle_msg(
    {incoming, #{<<"reset">> := _IsSet} = Msg},
    #{
        '_lastvalue' := undefined,
        <<"property">> := PropName
    } = NodeDef
) ->
    case get_prop(PropName, Msg) of
        {ok, Value, _} ->
            {handled, NodeDef#{'_lastvalue' => Value}, dont_send_complete_msg};
        _ ->
            {handled, NodeDef, dont_send_complete_msg}
    end;
handle_msg(
    {incoming, #{<<"reset">> := _IsSet} = Msg},
    #{
        '_lastvalue' := LastValue,
        <<"property">> := PropName
    } = NodeDef
) ->
    case get_prop(PropName, Msg) of
        {ok, LastValue, _} ->
            {handled, NodeDef, dont_send_complete_msg};
        {ok, Payload, _} ->
            {handled, NodeDef#{'_lastvalue' => Payload},
                dont_send_complete_msg};
        _ ->
            {handled, NodeDef#{'_lastvalue' => undefined},
                dont_send_complete_msg}
    end;
handle_msg(
    {incoming, #{<<"reset">> := _IsSet}},
    NodeDef
) ->
    %% this doesn't make sense and shouldn't happen. This is the case
    %% that the node has not been configured with a message property that
    %% should be checked - that is non-sensical.
    {handled, NodeDef#{'_lastvalue' => undefined}, dont_send_complete_msg};
%%
%%
handle_msg(
    {incoming, Msg},
    #{
        '_lastvalue' := undefined,
        <<"property">> := PropName
    } = NodeDef
) ->
    case get_prop(PropName, Msg) of
        {ok, Payload, _} ->
            {handled, NodeDef#{'_lastvalue' => Payload},
                dont_send_complete_msg};
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
