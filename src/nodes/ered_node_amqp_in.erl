-module(ered_node_amqp_in).

-include("ered_nodes.hrl").

%% -include("amqp_client.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% AMPQ aka RabbitMQ support.
%%
%% "type": "amqp-in",
%% "z": "1d6755909679f160",
%% "name": "",
%% "broker": "4efefc0a8cd23f1c",
%% "prefetch": 0,
%% "noAck": true,
%% "exchangeName": "mhs_hash_events",
%% "exchangeType": "x-consistent-hash",
%% "exchangeRoutingKey": "1",
%% "exchangeDurable": false,
%% "queueName": "",
%% "queueExclusive": false,
%% "queueDurable": false,
%% "queueAutoDelete": false,
%% "headers": "{}",
%%

-import(ered_nodered_comm, [
    node_status/5
]).

-import(ered_messages, [
    create_outgoing_msg/1,
    to_bool/1
]).

-import(ered_nodes, [
    send_msg_to_connected_nodes/2
]).

%%
%%
start(#{<<"broker">> := CfgNodeId} = NodeDef, WsName) ->
    application:ensure_all_started(amqp_client),

    case ered_config_store:retrieve_config_node(CfgNodeId, WsName) of
        {ok, Cfg} ->
            case amqp_connection:start(set_conn_opts(Cfg)) of
                {ok, Connection} ->
                    node_status(WsName, NodeDef, "connected", "green", "ring"),
                    ered_node:start(NodeDef#{conn => Connection}, ?MODULE);
                {error, {auth_failure, ErrMsg}} ->
                    io:format("AMQP: ERROR ~p~n", [ErrMsg]),
                    node_status(WsName, NodeDef, "login failed", "red", "ring"),
                    ered_node:start(NodeDef, ered_node_ignore);
                {error, ErrMsg} ->
                    node_status(WsName, NodeDef, "unknown error", "red", "dot"),
                    io:format("AMQP: ERROR ~p~n", [ErrMsg]),
                    ered_node:start(NodeDef, ered_node_ignore)
            end;
        unavailable ->
            node_status(WsName, NodeDef, "no config", "red", "dot"),
            ered_node:start(NodeDef, ered_node_ignore)
    end;
start(NodeDef, _WsName) ->
    ered_node:start(NodeDef, ered_node_ignore).

%%
%%
handle_event(
    {registered, WsName, _NodePid},
    #{
        conn := Connection,
        <<"exchangeName">> := ExchName,
        <<"exchangeType">> := ExchType,
        <<"exchangeRoutingKey">> := RoutingKey,
        <<"queueName">> := QueueName,
        <<"queueExclusive">> := QueueExclusive,
        <<"queueDurable">> := QueueDurable,
        <<"queueAutoDelete">> := QueueAutoDelete
    } = NodeDef
) ->
    process_flag(trap_exit, true),

    {ok, Channel} = amqp_connection:open_channel(Connection),

    ChannelMonitor = erlang:monitor(process, Channel),

    Declare = #'exchange.declare'{
        exchange = ExchName,
        type = ExchType
    },

    #'exchange.declare_ok'{} =
        amqp_channel:call(Channel, Declare),

    #'queue.declare_ok'{queue = Q} =
        amqp_channel:call(Channel, #'queue.declare'{
            queue = QueueName,
            exclusive = to_bool(QueueExclusive),
            durable = to_bool(QueueDurable),
            auto_delete = to_bool(QueueAutoDelete)
        }),

    Binding = #'queue.bind'{
        queue = Q,
        exchange = ExchName,
        routing_key = RoutingKey
    },

    try
        case amqp_channel:call(Channel, Binding) of
            #'queue.bind_ok'{} ->
                timer:apply_after(
                    0,
                    fun() ->
                        loop_get_content(Q, Channel, NodeDef#{?SetWsName})
                    end
                ),

                node_status(
                    WsName,
                    NodeDef,
                    "channel connected",
                    "green",
                    "dot"
                );
            Err ->
                io:format("AMQP Error creating channel: ~p~n", [Err]),
                node_status(
                    WsName,
                    NodeDef,
                    "error creating channel",
                    "red",
                    "dot"
                )
        end
    catch
        E:S:F ->
            io:format("E ~p F ~p S ~p ~n", [E, F, S]),
            node_status(WsName, NodeDef, "fatal error", "red", "dot")
    end,

    NodeDef#{chanmtr => ChannelMonitor};
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% --------------- helpers
%%
set_conn_opts(
    #{
        <<"host">> := Host,
        <<"port">> := Port,
        <<"vhost">> := _Vhost,
        <<"credentials">> := #{
            <<"username">> := User,
            <<"password">> := Pass
        }
    } = _Cfg
) ->
    #amqp_params_network{
        username = User,
        password = Pass,
        port = Port,
        host = binary_to_list(Host)
    };
set_conn_opts(
    #{
        <<"host">> := Host,
        <<"port">> := Port,
        <<"vhost">> := _Vhost
    } = _Cfg
) ->
    #amqp_params_network{
        port = Port,
        host = binary_to_list(Host)
    }.

get_content(Queue, Channel, NoAck) ->
    Get = #'basic.get'{queue = Queue, no_ack = NoAck},

    case amqp_channel:call(Channel, Get) of
        {#'basic.get_ok'{delivery_tag = Tag}, Content} ->
            {Tag, Content};
        {'basic.get_empty', <<>>} ->
            empty
    end.

loop_get_content(
    Queue,
    Channel,
    #{<<"noAck">> := MsgNoAck, ?GetWsName} = NodeDef
) ->
    case get_content(Queue, Channel, to_bool(MsgNoAck)) of
        {Tag, Content} ->
            {outgoing, Msg} = create_outgoing_msg(WsName),
            Msg2 = Msg#{<<"tag">> => Tag, <<"payload">> => Content},
            send_msg_to_connected_nodes(NodeDef, Msg2),
            %% the ered_node behaviour covers incoming and outgoing messages but
            %% not node specific messages as in this case.
            ered_msgtracer_manager:node_received_msg(NodeDef, self(), Msg2);
        empty ->
            ignore
    end,

    timer:apply_after(
      0,
      fun() -> loop_get_content(Queue, Channel, NodeDef) end
    ).
