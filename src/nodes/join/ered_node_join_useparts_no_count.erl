-module(ered_node_join_useparts_no_count).

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
%% The main difference between the two implementations is the handling
%% of a message with complete set to true - this node decides which messages
%% to send based on the messages parts ids. A complete with a parts.id set
%% will only complete the corresponding message with the same parts.id.
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
        ered_node_join_store_useparts_no_count,
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
    #{'_store' := Store} = NodeDef
) ->
    true = ets:insert(Store, {IdStr, term_to_binary(Msg)}),
    NodeDef2 = have_all_parts_arrived(NodeDef, Msg, IdStr, true),
    {handled, NodeDef2, dont_send_complete_msg};
handle_msg(
    {incoming,
        #{
            <<"complete">> := true
        } = Msg},
    #{'_store' := Store} = NodeDef
) ->
    true = ets:insert(Store, {<<>>, term_to_binary(Msg)}),
    NodeDef2 = have_all_parts_arrived(NodeDef, Msg, <<>>, true),
    {handled, NodeDef2, dont_send_complete_msg};
%%
%% --- messages without complete but parts attribute
handle_msg(
    {incoming,
        #{
            <<"parts">> := #{
                <<"id">> := PartsId,
                <<"count">> := PartsCount
            }
        } = Msg},
    #{
        '_store' := Store
    } = NodeDef
) ->
    true = ets:insert(Store, {PartsId, term_to_binary(Msg)}),
    CurrCount = ets:select_count(Store, [{{PartsId, '_'}, [], [true]}]),

    NodeDef2 =
        have_all_parts_arrived(NodeDef, Msg, PartsId, CurrCount =:= PartsCount),

    {handled, NodeDef2, dont_send_complete_msg};
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
    {handled, NodeDef, dont_send_complete_msg};
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
    {handled, NodeDef, dont_send_complete_msg};
%%
%%
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%%
%% --------------- helpers

%%
%%
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
    #{<<"parts">> := #{<<"parts">> := SubParts}} = Msg,
    Store
) ->
    send_out_collected_messages(
        NodeDef,
        Msg#{<<"parts">> => SubParts},
        Store,
        Store
    );
send_out_collected_messages(
    #{<<"propertyType">> := <<"full">>} = NodeDef,
    Msg,
    Store
) ->
    send_out_collected_messages(
        NodeDef,
        maps:remove(<<"parts">>, Msg),
        Store,
        Store
    );
send_out_collected_messages(
    #{<<"propertyType">> := <<"msg">>, <<"property">> := PropName} = NodeDef,
    #{<<"parts">> := #{<<"parts">> := SubParts}} = Msg,
    Store
) ->
    Lst2 = [retrieve_prop_value(PropName, M) || M <- Store],
    send_out_collected_messages(
        NodeDef,
        Msg#{<<"parts">> => SubParts},
        Store,
        Lst2
    );
send_out_collected_messages(
    #{<<"propertyType">> := <<"msg">>, <<"property">> := PropName} = NodeDef,
    Msg,
    Store
) ->
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
    NodeDef.
