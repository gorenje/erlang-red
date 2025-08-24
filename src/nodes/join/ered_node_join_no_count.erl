-module(ered_node_join_no_count).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% join node is the companion of the split node that generates many messages
%% from a single message. The join node collects these together again and
%% sends them out as a single message.
%%
%% This module handles the case of useparts is off and count is negative or not
%% set so the only possibility is obtaining a message with complete set to
%% true.
%%
-import(ered_nodes, [
    jstr/2,
    send_msg_to_connected_nodes/2
]).
-import(ered_nodered_comm, [
    node_status/5,
    unsupported/3
]).
-import(ered_message_exchange, [
    post_completed/2
]).
-import(ered_messages, [
    retrieve_prop_value/2
]).

%%
%%
start(_, _) ->
    throw(should_not_be_called).

%%
%%
handle_event({registered, _WsName, _MyPid}, NodeDef) ->
    Store = ets:new(
        ered_node_join_store_no_count,
        [ordered_set, private, {write_concurrency, true}]
    ),
    NodeDef#{'_store' => Store};
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg(
    {incoming, #{<<"complete">> := true} = Msg},
    #{
        '_store' := Store,
        '_counter' := Counter
    } = NodeDef
) ->
    NewCounter = Counter + 1,
    true = ets:insert(Store, {NewCounter, term_to_binary(Msg)}),
    Batch = ets:foldl(fun({_, M}, Acc) -> [M | Acc] end, [], Store),
    ets:delete_all_objects(Store),
    NodeDef2 = send_out_collected_messages(
        NodeDef,
        Msg,
        lists:reverse(Batch)
    ),
    {handled, NodeDef2, dont_send_complete_msg};
handle_msg(
    {incoming, Msg},
    #{
        '_store' := Store,
        '_counter' := Counter
    } = NodeDef
) ->
    NewCounter = Counter + 1,
    true = ets:insert(Store, {NewCounter, term_to_binary(Msg)}),
    {handled, NodeDef#{'_counter' => NewCounter}, dont_send_complete_msg};
%%
%%
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%%
%% --------------- helpers

%%
%%
send_out_collected_messages(
    #{<<"propertyType">> := <<"full">>} = NodeDef,
    Msg,
    RevStore
) ->
    Store = [binary_to_term(M) || M <- RevStore],
    send_out_collected_messages(NodeDef, Msg, Store, Store);
send_out_collected_messages(
    #{<<"propertyType">> := <<"msg">>, <<"property">> := PropName} = NodeDef,
    Msg,
    RevStore
) ->
    Store = [binary_to_term(M) || M <- RevStore],
    Lst2 = [retrieve_prop_value(PropName, M) || M <- Store],
    send_out_collected_messages(NodeDef, Msg, Store, Lst2).

%%
send_out_collected_messages(NodeDef, Msg, AllMsgs, PayloadForNodes) ->
    %% retrieve the latest message and use that as a basis for sending out
    %% these messages - TODO perhaps this is wrong but will do for now.
    send_msg_to_connected_nodes(NodeDef, Msg#{?AddPayload(PayloadForNodes)}),

    %% now that we are ready to send out our message, we are completed
    %% with the message that make up that message (!!) so those
    %% messages should be sent to a complete node - if there is one
    %% See this post for details:
    %%   https://discourse.nodered.org/t/complete-node-msg-before-or-after-computation/96648/5
    [post_completed(NodeDef, M) || M <- AllMsgs],

    %% reset the store, ready to receive more messages
    NodeDef#{'_counter' => 0}.
