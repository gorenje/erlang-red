-module(ered_node_join_timeout).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% after X seconds send out all message that have been collected. Send them
%% out as an array of things - either property value or complete message
%% objects.
%%
%% This ignores the "useparts" object.
%%
-import(ered_nodes, [
    send_msg_to_connected_nodes/2
]).
-import(ered_nodered_comm, [
    node_status/5
]).
-import(ered_message_exchange, [
    post_completed/2
]).
-import(ered_messages, [
    create_outgoing_msg/1,
    retrieve_prop_value/2
]).

%%
%%
start(_, _) ->
    throw(should_not_be_called).

%%
%%
handle_event(
    {registered, WsName, _MyPid},
    #{'_timeout' := TimeOutInSeconds} = NodeDef
) ->
    node_status(WsName, NodeDef, 0, "blue", "ring"),

    Store = ets:new(
        ered_node_join_store_timeout,
        [ordered_set, private, {write_concurrency, true}]
    ),
    NodeDef#{
        '_store' => Store,
        '_timer' => timer:send_after(
            TimeOutInSeconds * 1000,
            {join_send_message_buffer, WsName}
        )
    };
handle_event(
    {join_send_message_buffer, WsName},
    #{
        '_store' := Store,
        '_timeout' := TimeOutInSeconds
    } = NodeDef
) ->
    {outgoing, Msg} = create_outgoing_msg(WsName),
    Batch = ets:foldl(fun({_, M}, Acc) -> [M | Acc] end, [], Store),
    ets:delete_all_objects(Store),
    node_status(WsName, NodeDef, 0, "blue", "ring"),
    %% send out the messages and bang on another timer to cook the eggs
    begin
        send_out_collected_messages(NodeDef, Msg, lists:reverse(Batch))
    end#{
        '_timer' => timer:send_after(
            TimeOutInSeconds * 1000,
            {join_send_message_buffer, WsName}
        )
    };
handle_event(
    {stop, _WsName},
    #{'_timer' := {ok, TRef}} = NodeDef
) ->
    timer:cancel(TRef),
    NodeDef;
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg(
    {incoming, #{?GetWsName} = Msg},
    #{
        '_store' := Store,
        '_counter' := Counter
    } = NodeDef
) ->
    node_status(WsName, NodeDef, Counter + 1, "blue", "ring"),
    true = ets:insert(Store, {Counter, term_to_binary(Msg)}),
    {handled, NodeDef#{'_counter' => Counter + 1}, dont_send_complete_msg};
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
    send_out_collected_messages(
        NodeDef,
        maps:remove(<<"parts">>, Msg),
        Store,
        Store
    );
send_out_collected_messages(
    #{<<"propertyType">> := <<"msg">>, <<"property">> := PropName} = NodeDef,
    Msg,
    RevStore
) ->
    Store = [binary_to_term(M) || M <- RevStore],
    Lst2 = [retrieve_prop_value(PropName, M) || M <- Store],
    send_out_collected_messages(
        NodeDef,
        maps:remove(<<"parts">>, Msg),
        Store,
        Lst2
    ).

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
