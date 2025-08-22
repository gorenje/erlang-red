-module(ered_node_batch).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Mark messages and belonging to batches of a specific size.
%%
%% "id": "eb702158cef45052",
%% "type": "batch",
%% "z": "866410b56fa42447",
%% "g": "5e6c5aa86609cf42",
%% "name": "",
%% "mode": "count",  <<<--- batch by absolute number per batch
%% "count": 10, <<<-----/
%% "overlap": 0,   <<---- how many messages are duplicated in batches
%% "interval": 10,   <<---- timeout for time-based batching
%% "allowEmptySequence": false,
%% "honourParts": false,  <<<---- allow complete or parts to affect this node
%% "topics": [],
%%
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
    convert_to_integer/1,
    retrieve_prop_value/2
]).

start(
    #{
        <<"mode">> := <<"count">>,
        <<"count">> := Count,
        <<"overlap">> := 0,
        <<"honourParts">> := false
    } = NodeDef,
    WsName
) ->
    CountInt = convert_to_integer(Count),
    case CountInt > 0 of
        true ->
            ered_node:start(
                NodeDef#{
                    '_current_batch' => undefined,
                    '_count' => CountInt,
                    '_togo' => CountInt
                },
                ?MODULE
            );
        _ ->
            ErrMsg = jstr("Count is not positive ~p", [NodeDef]),
            unsupported(NodeDef, {websocket, WsName}, ErrMsg),
            ered_node:start(NodeDef, ered_node_ignore)
    end;
start(NodeDef, WsName) ->
    ErrMsg = jstr("Node Config ~p", [NodeDef]),
    unsupported(NodeDef, {websocket, WsName}, ErrMsg),
    ered_node:start(NodeDef, ered_node_ignore).

%%
%%
handle_event({registered, _WsName, _MyPid}, NodeDef) ->
    Tab = ets:new(
        ered_batch_node_message_store,
        [ordered_set, private, {write_concurrency, true}]
    ),
    NodeDef#{'_current_batch' => Tab};
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg(
    {incoming,
        #{
            '_msgid' := MsgId
        } = Msg},
    #{
        '_current_batch' := Store,
        '_count' := Count,
        '_togo' := Togo
    } = NodeDef
) when Togo =:= Count ->
    %% First message of a new batch, use the message ID to identify
    %% the entire batch.
    Msg2 = Msg#{
        <<"parts">> => #{
            <<"id">> => MsgId,
            <<"index">> => 0,
            <<"count">> => Count
        }
    },

    true = ets:insert(Store, {Togo, term_to_binary(Msg2)}),

    %% Check whether we have completed the batch. This has to be done here
    %% because if there are no more messages and this message just complete
    %% the batch, then we need to send it out now. This happens if Count == 1.
    NodeDef2 = send_out_completed_batch(NodeDef#{
        '_current_batch_id' => MsgId,
        '_togo' => Togo - 1
    }),

    {handled, NodeDef2, dont_send_complete_msg};
handle_msg(
    {incoming, Msg},
    #{
        '_current_batch_id' := BatchId,
        '_current_batch' := Store,
        '_count' := Count,
        '_togo' := Togo
    } = NodeDef
) ->
    Msg2 = Msg#{
        <<"parts">> => #{
            <<"id">> => BatchId,
            <<"index">> => (Count - Togo),
            <<"count">> => Count
        }
    },

    true = ets:insert(Store, {Togo, term_to_binary(Msg2)}),

    NodeDef2 = send_out_completed_batch(NodeDef#{
        '_togo' => Togo - 1
    }),

    {handled, NodeDef2, dont_send_complete_msg};
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% --------------------- Helpers
%%

send_out_completed_batch(
    #{
        '_count' := Count,
        '_current_batch' := Store,
        '_togo' := 0
    } = NodeDef
) ->
    SendAndPostCompleted = fun(Msg) ->
        send_msg_to_connected_nodes(NodeDef, Msg),
        post_completed(NodeDef, Msg)
    end,

    Batch = ets:foldl(
        fun({_, M}, Acc) -> [binary_to_term(M) | Acc] end, [], Store
    ),
    ets:delete_all_objects(Store),

    [SendAndPostCompleted(Msg) || Msg <- Batch],

    NodeDef#{'_togo' => Count};
send_out_completed_batch(NodeDef) ->
    NodeDef.
