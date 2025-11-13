-module(ered_node_kafka_consumer).

-include("ered_nodes.hrl").
-include_lib("brod/include/brod.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Kafka producer node based on brod.
%%
%% "broker": "bba11b3e54ed911d",
%% "groupid": "",
%% "topic": "node-red",
%% "keytype": "buffer",
%% "valuetype": "buffer",
%% "advancedoptions": true,
%% "autocommitinterval": 5000,
%% "autocommitthreshold": 100,
%% "sessiontimeout": 30000,
%% "rebalancetimeout": 60000,
%% "heartbeatinterval": 3000,
%% "metadatamaxage": 300000,
%% "maxbytesperpartition": 1048576,
%% "minbytes": 1,
%% "maxbytes": 10485760,
%% "maxwaittimeinms": 5000,
%% "frombeginning": true,
%% "x": 566,
%% "y": 486.5,
%% "wires": [

-import(ered_nodes, [
    jstr/2,
    this_should_not_happen/2,
    send_msg_on/2
]).
-import(ered_nodered_comm, [
    debug/3,
    node_status/5
]).
-import(ered_messages, [
    create_outgoing_msg/1
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
start(
    #{<<"broker">> := CfgNodeId, <<"id">> := MyNodeId} = NodeDef,
    WsName
) ->
    KafkaClientId =
        ered_kafka_client_manager:start_client(CfgNodeId, MyNodeId, WsName),
    node_status(WsName, NodeDef, "connecting", "blue", "ring"),
    ered_node:start(NodeDef#{client_id => KafkaClientId, ?SetWsName}, ?MODULE);
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
    case brod:start_consumer(KafkaClientId, KafkaTopic, []) of
        {error, client_down, _Ignore} ->
            node_status(WsName, NodeDef, "client down", "red", "ring"),
            MyPid = self(),
            ?CheckForClient(563);
        {error, client_down} ->
            node_status(WsName, NodeDef, "client down", "red", "ring"),
            MyPid = self(),
            ?CheckForClient(563);
        ok ->
            %% TODO: this is hardcoded on partition 0 - is there a way to
            %% TODO: connect to all partitions or specify a series of partitions.
            case
                brod:subscribe(
                    KafkaClientId,
                    self(),
                    KafkaTopic,
                    0,
                    []
                )
            of
                {ok, _Pid} ->
                    node_status(WsName, NodeDef, "connected", "green", "dot");
                _ ->
                    node_status(WsName, NodeDef, "error", "red", "dot")
            end
    end,
    NodeDef;
handle_event(
    {kafka_message_set, _Topic, _Partition, _Offset, MsgLst} = KMsg,
    NodeDef
) ->
    [dispatch_kafka_message(KafkaMsg, KMsg, NodeDef) || KafkaMsg <- MsgLst],
    NodeDef;
handle_event(R, NodeDef) ->
    io:format("Kafka Unknown Event ~p~n", [R]),
    NodeDef.

%%
%% Node type has no input ports, so expect no handle_msg calls.
%%
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% --------------- helpers
%%
dispatch_kafka_message(
    #kafka_message{
        offset = Offset,
        key = Key,
        value = Value,
        ts_type = _Ignore,
        ts = Ts,
        headers = Headers
    },
    {kafka_message_set, Topic, Partition, _CurrentOffset, _},
    #{?GetWsName, <<"wires">> := [MsgPort, _InfoPort]} = NodeDef
) ->
    {outgoing, Msg} = create_outgoing_msg(WsName),
    Msg2 = Msg#{
        <<"topic">> => Topic,
        <<"partition">> => Partition,
        <<"payload">> => #{
            <<"offset">> => Offset,
            <<"key">> => Key,
            <<"value">> => Value,
            <<"headers">> => Headers,
            <<"ts">> => Ts
        }
    },

    %% the ered_node behaviour covers incoming and outgoing messages but
    %% not node specific messages as in this case.
    ered_msgtracer_manager:node_received_msg(NodeDef, self(), Msg2),

    send_msg_on(MsgPort, Msg2).
