-module(ered_node_kafka_producer).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Kafka producer node based on brod.
%%
%% "broker": "bba11b3e54ed911d",
%% "topic": "node-red",
%% "keytype": "buffer",
%% "valuetype": "buffer",
%% "advancedoptions": false,
%% "acknowledge": "all",
%% "partition": "",
%% "headeritems": {},
%% "key": "",
%% "responsetimeout": 30000,
%% "transactiontimeout": 60000,
%% "metadatamaxage": 300000,
%% "x": 654,
%% "y": 305.5,
%% "wires": [

-import(ered_nodes, [
    jstr/2,
    this_should_not_happen/2
]).
-import(ered_nodered_comm, [
    debug/3,
    node_status/5
]).

-define(CheckForClient(Delay), begin
    timer:apply_after(
        Delay,
        fun() ->
            MyPid ! {kafka_client_check, KafkaClientId}
        end
    )
end).

%%
%%
start(#{<<"broker">> := CfgNodeId, ?GetIdStr} = NodeDef, WsName) ->
    KafClnId = ered_kafka_client_manager:start_client(CfgNodeId, IdStr, WsName),
    node_status(WsName, NodeDef, "connecting", "blue", "ring"),
    ered_node:start(NodeDef#{client_id => KafClnId, ?SetWsName}, ?MODULE);
start(NodeDef, _WsName) ->
    ered_node:start(NodeDef, ered_node_noop).

%%
%%
handle_event(
    {registered, _WsName, MyPid},
    #{client_id := KafkaClientId} = NodeDef
) ->
    ?CheckForClient(213),
    NodeDef;
handle_event(
    {kafka_client_check, KafkaClientId},
    #{
        <<"topic">> := KafkaTopic,
        client_id := KafkaClientId,
        ?GetWsName
    } = NodeDef
) ->
    case brod:start_producer(KafkaClientId, KafkaTopic, []) of
        ok ->
            node_status(WsName, NodeDef, "connected", "green", "dot");
        {error, client_down, _Ignore} ->
            node_status(WsName, NodeDef, "client down", "red", "ring"),
            MyPid = self(),
            ?CheckForClient(563);
        {error, client_down} ->
            node_status(WsName, NodeDef, "client down", "red", "ring"),
            MyPid = self(),
            ?CheckForClient(563)
    end,
    NodeDef;
handle_event(
    {kafka_produce_reply, _Offset, brod_produce_req_acked, _OrigEvent},
    NodeDef
) ->
    %% ignore ACK.
    NodeDef;
handle_event(
    {kafka_produce_reply, _Offset, brod_produce_req_buffered, _OrigEvent},
    NodeDef
) ->
    %% ignore this too
    NodeDef;
handle_event(R, NodeDef) ->
    io:format("Prid un ~p~n", [R]),
    NodeDef.

%%
%%
handle_msg(
    {incoming, #{<<"topic">> := Topic, ?GetPayload} = Msg},
    #{client_id := Client} = NodeDef
) ->
    brod:produce(Client, Topic, 0, <<"payload">>, Payload),
    {handled, NodeDef, Msg};
handle_msg(
    {incoming, #{?GetPayload} = Msg},
    #{<<"topic">> := Topic, client_id := Client} = NodeDef
) ->
    brod:produce(Client, Topic, 0, <<"payload">>, Payload),
    {handled, NodeDef, Msg};
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% --------------- helpers
%%
