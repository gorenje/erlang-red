-module(ered_node_complete).

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% The complete node is a complex character. It raises the question "when is
%% a node complete?" - think here join node or switch node, for example.
%%
%% A join node isn't complete, it's handling of a subset of messages might
%% be completed but itself is never complete. Hence a join is configured to
%% collect four messages into a single message, will be completed when four
%% messages have arrived and once it sends out the message containing
%% those four messages, it has completed with the individual four messages.
%%
%% A swich node - does it do anything to a message? A node that does not
%% alter the message, does it have a completion?
%%
%% A switch raises no complete messages and a join node raises complete messages
%% once it is ready to send out a message. The wonderful world of the complete
%% node.
%%
%% Not forgetting the dangers of endless loops by listening to nodes that
%% are (directly or indirectly) connected to the complete node doing the
%% sending.
%%
%% Complete nodes can also listen to each other and cause endless loops.
%%
-import(ered_nodes, [
    send_msg_to_connected_nodes/2
]).
-import(ered_message_exchange, [
    subscribe_to_completed/3
]).

%%
%%
start(NodeDef, _WsName) ->
    ered_node:start(NodeDef, ?MODULE).

%%
%% To avoid infinite loops by listening to nodes that are connected to this
%% complete node (nodes connected to those nodes, i.e. second or third degree
%% nodes), we mark the messages we handle and ignore those that come
%% back to us - like a bad boomarang ready to hit us in the head.
mark_msg(#{<<"id">> := ThisId} = _NodeDef, #{'_complete_list' := Ary} = Msg) ->
    case lists:member(ThisId, Ary) of
        true ->
            {error, already_handled_msg};
        false ->
            {ok, Msg#{'_complete_list' => [ThisId | Ary]}}
    end;
mark_msg(#{<<"id">> := ThisId} = _NodeDef, Msg) ->
    {ok, Msg#{'_complete_list' => [ThisId]}};
mark_msg(_NodeDef, _Msg) ->
    {error, no_node_id_found}.

%%
%%
define_source_details(
    #{<<"type">> := FromType, <<"id">> := FromId, <<"name">> := FromName}
) ->
    #{<<"id">> => FromId, <<"type">> => FromType, <<"name">> => FromName};
define_source_details(
    #{<<"type">> := FromType, <<"id">> := FromId}
) ->
    #{<<"id">> => FromId, <<"type">> => FromType, <<"name">> => <<"">>};
define_source_details(
    #{<<"id">> := FromId}
) ->
    #{<<"id">> => FromId, <<"type">> => <<"">>, <<"name">> => <<"">>};
define_source_details(
    _
) ->
    #{<<"id">> => <<"">>, <<"type">> => <<"">>, <<"name">> => <<"">>}.

%%
%%
add_complete_attribute(FromDef, MarkedMsg) ->
    MarkedMsg#{
        <<"complete">> => #{
            <<"source">> =>
                define_source_details(FromDef)
        }
    }.

%%
%%
handle_event({registered, WsName, Pid}, NodeDef) ->
    subscribe_to_completed(NodeDef, WsName, Pid),
    NodeDef;
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_completed_msg(
    #{<<"scope">> := Scope} = NodeDef,
    #{<<"id">> := FromId} = FromDef,
    Msg
) ->
    case lists:member(FromId, Scope) of
        true ->
            case mark_msg(NodeDef, Msg) of
                {ok, MarkedMsg} ->
                    CompletelyMarkedMsg =
                        add_complete_attribute(FromDef, MarkedMsg),
                    send_msg_to_connected_nodes(NodeDef, CompletelyMarkedMsg),
                    {NodeDef, CompletelyMarkedMsg};
                _ ->
                    {NodeDef, dont_send_complete_msg}
            end;
        _ ->
            {NodeDef, dont_send_complete_msg}
    end;
handle_completed_msg(NodeDef, _FromDef, _Msg) ->
    {NodeDef, dont_send_complete_msg}.

%%
%%
handle_msg({completed_msg, FromNodeDef, Msg}, NodeDef) ->
    {NodeDef2, Msg2} = handle_completed_msg(NodeDef, FromNodeDef, Msg),
    {handled, NodeDef2, Msg2};
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.
