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
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg(
    {incoming, #{<<"complete">> := true} = Msg},
    NodeDef
) ->
    handle_complete_msg(Msg, NodeDef);
%%
handle_msg(
    {incoming,
        #{
            <<"parts">> := #{<<"count">> := PartsCount}
        } = Msg},
    #{
        '_store' := Store,
        '_count' := Count
    } = NodeDef
) when Count =< 0 ->
    %% No count set, but using parts - so we have to check whether all parts
    %% have arrived, if so then send out the parts/messages. If not, it's
    %% back to the daily grind.
    NodeDef2 = have_all_parts_arrived(
        NodeDef,
        Store ++ [Msg],
        convert_to_int(PartsCount)
    ),
    {handled, NodeDef2, dont_send_complete_msg};
handle_msg(
    {incoming, Msg},
    #{
        '_store' := Store,
        '_count' := Count
    } = NodeDef
) when Count > 0, length(Store) =:= (Count - 1) ->
    %% This message completes the store.
    NodeDef2 = send_out_collected_messages(NodeDef, Store ++ [Msg]),
    {handled, NodeDef2, dont_send_complete_msg};
%%
%% If we make it here, then just store the message and move on.
handle_msg(
    {incoming, Msg},
    #{
        '_store' := Store
    } = NodeDef
) ->
    {handled, NodeDef#{'_store' => Store ++ [Msg]}, dont_send_complete_msg};
%%
%%
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%%
%% --------------- helpers

%%
%%
handle_complete_msg(
    #{
        <<"parts">> := #{<<"id">> := IdStr}
    } = Msg,
    #{
        '_store' := Store
    } = NodeDef
) ->
    {WithId, WithoutId} = divide_and_conquer(IdStr, Store ++ [Msg]),

    send_out_collected_messages(NodeDef, WithId),

    {handled, NodeDef#{'_store' => WithoutId}, dont_send_complete_msg};
handle_complete_msg(
    Msg,
    #{
        '_store' := Store,
        '_count' := Count
    } = NodeDef
) when Count =< 0 ->
    {WithId, WithoutId} = divide_and_conquer_no_idstr(Store ++ [Msg]),

    send_out_collected_messages(NodeDef, WithoutId),

    {handled, NodeDef#{'_store' => WithId}, dont_send_complete_msg};
handle_complete_msg(
    Msg,
    #{
        '_store' := Store,
        '_count' := Count
    } = NodeDef
) when Count > 0 ->
    NodeDef2 = send_out_collected_messages(NodeDef, Store ++ [Msg]),
    {handled, NodeDef2, dont_send_complete_msg}.

%%
%%
have_all_parts_arrived(
    NodeDef, AllMsgs, Count
) when length(AllMsgs) =:= Count ->
    send_out_collected_messages(NodeDef, AllMsgs);
have_all_parts_arrived(NodeDef, AllMsgs, _Count) ->
    NodeDef#{'_store' => AllMsgs}.

%%
%%
send_out_collected_messages(
    #{<<"propertyType">> := <<"full">>} = NodeDef,
    Store
) ->
    send_out_collected_messages(NodeDef, Store, Store);
send_out_collected_messages(
    #{<<"propertyType">> := <<"msg">>, <<"property">> := PropName} = NodeDef,
    Store
) ->
    Lst2 = [retrieve_prop_value(PropName, Msg) || Msg <- Store],
    send_out_collected_messages(NodeDef, Store, Lst2).

%%
send_out_collected_messages(NodeDef, AllMsgs, PayloadForNodes) ->
    %% retrieve the latest message and use that as a basis for sending out
    %% these messages - TODO perhaps this is wrong but will do for now.
    [Msg | _] = AllMsgs,
    send_msg_to_connected_nodes(NodeDef, Msg#{?AddPayload(PayloadForNodes)}),

    %% now that we are ready to send out our message, we are completed
    %% with the message that make up that message (!!) so those
    %% messages should be sent to a complete node - if there is one
    %% See this post for details:
    %%   https://discourse.nodered.org/t/complete-node-msg-before-or-after-computation/96648/5
    [post_completed(NodeDef, M) || M <- AllMsgs],

    %% reset the store, ready to receive more messages
    NodeDef#{'_store' => []}.

%%
%%
convert_to_int(Val) when is_integer(Val) ->
    Val;
convert_to_int(Val) when is_float(Val) ->
    erlang:element(1, string:to_integer(io_lib:format("~p", [Val])));
convert_to_int(Val) ->
    case string:to_float(Val) of
        {error, _} ->
            case string:to_integer(Val) of
                {error, _} ->
                    -1;
                {V, _} ->
                    V
            end;
        {V, _} ->
            %% V is now a float and the guard 'is_float' will catch it now
            convert_to_int(V)
    end.

%%
%%
divide_and_conquer(IdStr, Store) ->
    divide_and_conquer(IdStr, Store, [], []).

divide_and_conquer(_IdStr, [], AccWithId, AccNotId) ->
    {AccWithId, AccNotId};
divide_and_conquer(
    IdStr,
    [#{<<"parts">> := #{<<"id">> := IdStr}} = Msg | Rest],
    AccWithId,
    AccNotId
) ->
    divide_and_conquer(IdStr, Rest, AccWithId ++ [Msg], AccNotId);
divide_and_conquer(IdStr, [Msg | Rest], AccWithId, AccNotId) ->
    divide_and_conquer(IdStr, Rest, AccWithId, AccNotId ++ [Msg]).

%%
%%
divide_and_conquer_no_idstr(Store) ->
    divide_and_conquer_no_idstr(Store, [], []).

divide_and_conquer_no_idstr([], AccWithId, AccWithoutId) ->
    {AccWithId, AccWithoutId};
divide_and_conquer_no_idstr(
    [#{<<"parts">> := #{<<"id">> := _IdStr}} = Msg | Rest],
    AccWithId,
    AccWithoutId
) ->
    divide_and_conquer_no_idstr(Rest, AccWithId ++ [Msg], AccWithoutId);
divide_and_conquer_no_idstr(
    [Msg | Rest],
    AccWithId,
    AccWithoutId
) ->
    divide_and_conquer_no_idstr(Rest, AccWithId, AccWithoutId ++ [Msg]).
