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

start(#{
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
            ered_node:start(NodeDef#{
                '_count' => CountInt,
                '_current_batch' => []
            }, ?MODULE);
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
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg(
  {incoming,
   #{
     '_msgid' := MsgId
    } = Msg
  },
  #{
     '_current_batch' := Batch,
     '_count' := Count
   } = NodeDef
) when length(Batch) =:= 0 ->
    %% First message of a new batch, use the message ID to identify
    %% the entire batch.
    Msg2 = Msg#{
        <<"parts">> => #{
          <<"id">> => MsgId,
          <<"index">> => 0,
          <<"count">> => Count
        }
    },

    %% Check whether we have completed the batch. This has to be done here
    %% because if there are no more messages and this message just complete
    %% the batch, then we need to send it out now. This happens if Count == 1.
    NodeDef2 = send_out_completed_batch(NodeDef#{
        '_current_batch_id' => MsgId,
        '_current_batch' => [Msg2]
    }),

    {handled, NodeDef2, dont_send_complete_msg};

handle_msg(
  {incoming, Msg},
  #{
     '_current_batch_id' := BatchId,
     '_current_batch' := Batch,
     '_count' := Count
  } = NodeDef
) ->
    Msg2 = Msg#{
        <<"parts">> => #{
          <<"id">> => BatchId,
          <<"index">> => length(Batch),
          <<"count">> => Count
        }
    },

    NodeDef2 = send_out_completed_batch(NodeDef#{
        '_current_batch' => [Msg2 | Batch]
    }),

    {handled, NodeDef2, dont_send_complete_msg};

handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.


%%
%% --------------------- Helpers
%%

send_out_completed_batch(
  #{ '_count' := Count,
     '_current_batch' := Batch
   } = NodeDef
 ) when Count =:= length(Batch) ->
    Fun = fun(Msg) ->
                  send_msg_to_connected_nodes(NodeDef, Msg),
                  post_completed(NodeDef, Msg)
          end,
    [Fun(M) || M <- lists:reverse(Batch)],

    NodeDef#{'_current_batch' => []};
send_out_completed_batch(NodeDef) ->
    NodeDef.
