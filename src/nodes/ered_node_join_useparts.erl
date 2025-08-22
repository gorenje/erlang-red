-module(ered_node_join_useparts).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% If the join node is configured to use existing parts attribute of messages,
%% then this module is used. This is decided in the start/2 function of the
%% ered_join.erl module.
%%
%% Because this is a node configuration that can not be altered by a message,
%% it is safe to switch modules on flow start time.
%%
%% This is the basic the same as the ered_node_join_useparts_no_count but with
%% a non-negative count value that overrides the parts attribute on a message.
%%

-import(ered_nodes, [
    jstr/2,
    send_msg_to_connected_nodes/2
]).
-import(ered_nodered_comm, [
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
        ered_node_join_store_useparts,
        [duplicate_bag, private, {write_concurrency, false}]
    ),
    NodeDef#{'_store' => Store};
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
%% --- complete = true messages
handle_msg(
    {incoming,
        #{
            <<"complete">> := true,
            <<"parts">> := #{
                <<"id">> := IdStr
            }
        } = Msg},
    #{
        '_store' := Store
    } = NodeDef
) ->
    true = ets:insert(Store, {IdStr, term_to_binary(Msg)}),
    NodeDef2 = have_all_parts_arrived(NodeDef, Msg, IdStr, true),
    check_store_size_against_count(NodeDef2, Msg);
handle_msg(
    {incoming,
        #{
            <<"complete">> := true
        } = Msg},
    #{'_store' := Store} = NodeDef
) ->
    true = ets:insert(Store, {<<>>, term_to_binary(Msg)}),
    NodeDef2 = have_all_parts_arrived(NodeDef, Msg, all, true),
    check_store_size_against_count(NodeDef2, Msg);
%%
%% --- messages without complete but parts attribute
handle_msg(
    {incoming,
        #{
            <<"parts">> := #{
                <<"id">> := PartsId
            }
        } = Msg},
    #{
        '_store' := Store
    } = NodeDef
) ->
    true = ets:insert(Store, {PartsId, term_to_binary(Msg)}),
    check_store_size_against_count(NodeDef, Msg);
%%
%% If we make it here, then just store the message and move on. There
%% is no parts and no complete on the message.
handle_msg(
    {incoming, Msg},
    #{
        '_store' := Store
    } = NodeDef
) ->
    true = ets:insert(Store, {<<>>, term_to_binary(Msg)}),
    check_store_size_against_count(NodeDef, Msg);
%%
%%
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%%
%% --------------- helpers

%%
%%
check_store_size_against_count(
    #{
        '_store' := Store,
        '_count' := Count
    } = NodeDef,
    Msg
) ->
    {size, Size} = lists:keyfind(size, 1, ets:info(Store)),
    check_store_size_against_count(Size, Count, Store, NodeDef, Msg).

check_store_size_against_count(Count, Count, Store, NodeDef, Msg) ->
    %% There are now Count messages in the Store, pop them off and
    %% send them out!
    Batch = ets:foldl(
        fun({_, M}, Acc) -> [binary_to_term(M) | Acc] end,
        [],
        Store
    ),
    ets:delete_all_objects(Store),
    NodeDef2 = send_out_collected_messages(NodeDef, Msg, Batch),
    {handled, NodeDef2, dont_send_complete_msg};
check_store_size_against_count(_Size, _Count, _Store, NodeDef, _Msg) ->
    {handled, NodeDef, dont_send_complete_msg}.

%%
%%
have_all_parts_arrived(
    #{'_store' := Store} = NodeDef, Msg, all, true
) ->
    %% Send out all buffered messages, regardless of parts id or message id
    {handled, NodeDef2, _} =
        check_store_size_against_count(1, 1, Store, NodeDef, Msg),
    NodeDef2;
have_all_parts_arrived(
    #{'_store' := Store} = NodeDef, Msg, PartsId, true
) ->
    AllMsgs = lists:foldl(
        fun({_, M}, Acc) -> [binary_to_term(M) | Acc] end,
        [],
        ets:select(Store, [{{PartsId, '_'}, [], ['$_']}])
    ),

    ets:select_delete(Store, [{{PartsId, '_'}, [], [true]}]),

    send_out_collected_messages(NodeDef, Msg, lists:reverse(AllMsgs));
have_all_parts_arrived(NodeDef, _, _, _) ->
    NodeDef.

%%
%%
send_out_collected_messages(
    #{<<"propertyType">> := <<"full">>} = NodeDef,
    Msg,
    Store
) ->
    send_out_collected_messages(NodeDef, Msg, Store, Store);
send_out_collected_messages(
    #{<<"propertyType">> := <<"msg">>, <<"property">> := PropName} = NodeDef,
    Msg,
    Store
) ->
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
    NodeDef.
