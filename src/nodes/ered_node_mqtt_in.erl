-module(ered_node_mqtt_in).

-behaviour(ered_node).

-include("ered_nodes.hrl").
-include("ered_mqtt.hrl").

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% MQTT In node, a node that connects to a MQTT broker and streams all messags
%% into the flow it is embedded in.
%%
%%        "id": "4d0ffeae2a76b8b0",
%%        "type": "mqtt in",
%%        "z": "dc897f402c53697f",
%%        "name": "MQTT In",
%%        "topic": "",
%%        "qos": "2",
%%        "datatype": "auto-detect",  <<----- json and auto-detect is supported
%%        "broker": "da2f91c287ad12f7",
%%        "nl": false,
%%        "rap": true,
%%        "rh": 0,
%%        "inputs": 1, <<------ 1 means dynamic subscriptions, no fixed topic.
%%        "x": 467,
%%        "y": 585,
%%        "wires": [
%%            [
%%                "9048a940e9c269d8",
%%                "eb63f1261f783d43"
%%            ]
%%        ]
%%
%% An MQTT node is configured by a Config Node with the following properties:
%%
%% id => <<"97960d98b2837fa0">>,
%% name => <<"asdasdasd">>,
%% port => 1883,
%% type => <<"mqtt-broker">>,
%% keepalive => 60,
%% credentials => #{user => <<>>,password => <<>>},
%% broker => <<"renderbox">>,
%% userProps => <<>>,
%% clientid => <<>>,
%% autoConnect => true,
%% usetls => false,
%% protocolVersion => 4,
%% cleansession => true,
%% autoUnsubscribe => true,
%% birthTopic => <<>>,
%% birthQos => <<"0">>,
%% birthRetain => <<"false">>,
%% birthPayload => <<>>,
%% birthMsg => #{},
%% closeTopic => <<>>,
%% closeQos => <<"0">>,
%% closeRetain => <<"false">>,
%% closePayload => <<>>,
%% closeMsg => #{},
%% willTopic => <<>>,
%% willQos => <<"0">>,
%% willRetain => <<"false">>,
%% willPayload => <<>>,
%% willMsg => #{},
%% sessionExpiry => <<>>

%%
%% Reconnect strategy is to have the MQTT Manager take the hit - when the
%% eqmtt goes down because there isn't a broker available, it takes the manager
%% with it but leaves this node to recover everything. It does this by
%% capturing the DOWN message from the MQTT Manager and restarting it.
%%
%% Connecting to a broker is done via a timer that is constantly being
%% renewed and cycling through the Erlang processes. When the emqtt goes down
%% because an MQTT broker isn't available, it's recreated by this timer
%% or a DOWN event. Endlessly looping around until finally a connection
%% to the broker is made.
%%

-import(ered_config_store, [
    retrieve_config_node/2
]).
-import(ered_nodered_comm, [
    node_status/5
]).
-import(ered_messages, [
    create_outgoing_msg/1,
    convert_to_num/1,
    to_bool/1
]).
-import(ered_nodes, [
    send_msg_to_connected_nodes/2
]).

%%
%%
%% Dynamic subscriptions, no subscribe after initial connect.
start(#{<<"inputs">> := 1} = NodeDef, _WsName) ->
    F = fun(_Pid, _NodeDef) ->
        ok
    end,
    ered_node:start(NodeDef#{'_after_connect' => F}, ?MODULE);
%% Static topic, subscribe after connect.
start(#{<<"inputs">> := 0} = NodeDef, _WsName) ->
    F = fun(Pid, #{<<"topic">> := Topic, <<"qos">> := Qos}) ->
        gen_server:call(
            Pid, {subscribe, #{}, [{Topic, [{qos, convert_to_num(Qos)}]}]}
        )
    end,
    ered_node:start(NodeDef#{'_after_connect' => F}, ?MODULE).

%%
%%
handle_event({registered, WsName, _NodePid}, NodeDef) ->
    setup_mqtt_manager(NodeDef, WsName);
handle_event(
    {'DOWN', _MonitorRef, _Type, _Object, _Info},
    #{?GetWsName} = NodeDef
) ->
    setup_mqtt_manager(NodeDef, WsName);
%%
%% mqtt_disconnected event, with and without a running mqtt process
handle_event(
    {mqtt_disconnected, _Reason, _Properties},
    #{?MQTT_MGR_PID, ?GetWsName} = NodeDef
) ->
    case is_process_alive(MqttMgrPid) of
        true ->
            TRef = erlang:start_timer(
                750,
                self(),
                {connect_to_broker, MqttMgrPid}
            ),
            NodeDef#{'_timer' => TRef};
        _ ->
            setup_mqtt_manager(NodeDef, WsName)
    end;
%% no mqtt manager is running
handle_event(
    {mqtt_disconnected, _Reason, _Properties},
    #{?GetWsName} = NodeDef
) ->
    setup_mqtt_manager(NodeDef, WsName);
%%
handle_event(
    {connect_to_broker, MqttMgrPid},
    #{?GetWsName, ?AFTER_CONNECT} = NodeDef
) ->
    case is_process_alive(MqttMgrPid) of
        true ->
            case gen_server:call(MqttMgrPid, start_mqtt) of
                ok ->
                    try
                        case gen_server:call(MqttMgrPid, connect) of
                            {ok, _Props} ->
                                AfterConnect(MqttMgrPid, NodeDef),
                                ?NodeStatus("connected", "green", "dot"),
                                maps:remove('_timer', NodeDef);
                            _ ->
                                TRef = erlang:start_timer(
                                    750,
                                    self(),
                                    {connect_to_broker, MqttMgrPid}
                                ),
                                NodeDef#{'_timer' => TRef}
                        end
                    catch
                        exit:_ ->
                            %% this exit comes from the eqmtt library and its
                            %% taken our mqtt manager with it :( But this
                            %% exception represents a missing broker - so what!
                            %% We want to keep trying so we have to recreate
                            %% the manager.
                            %% What we do is capture the DOWN event of the
                            %% manager, restart it and then add a another timer.
                            ?NodeStatus("connecting", "yellow", "dot"),
                            NodeDef
                    end;
                _ ->
                    TRef = erlang:start_timer(
                        750,
                        self(),
                        {connect_to_broker, MqttMgrPid}
                    ),
                    ?NodeStatus("connecting", "yellow", "dot"),
                    NodeDef#{'_timer' => TRef}
            end;
        _ ->
            NodeDef
    end;
%%
%% stop event - with timer or without, with mqtt mgr process or not.
handle_event(?StopEvent, #{?TIMER, ?MQTT_MGR_PID} = NodeDef) ->
    erlang:cancel_timer(TRef),
    gen_server:cast(MqttMgrPid, stop),
    NodeDef;
handle_event(?StopEvent, #{?TIMER} = NodeDef) ->
    erlang:cancel_timer(TRef),
    NodeDef;
handle_event(?StopEvent, #{?MQTT_MGR_PID} = NodeDef) ->
    gen_server:cast(MqttMgrPid, stop),
    NodeDef;
%% fall through
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%

handle_msg(
    {mqtt_incoming, MqttDataPacket},
    #{?GetWsName, <<"datatype">> := <<"json">>} = NodeDef
) ->
    {outgoing, Msg} = create_outgoing_msg(WsName),
    Msg2 = copy_attributes([payload, topic, retain, qos], Msg, MqttDataPacket),
    #{?GetPayload} = Msg2,
    Msg3 = Msg2#{?AddPayload(json:decode(Payload))},
    send_msg_to_connected_nodes(NodeDef, Msg3),
    %% the ered_node behaviour covers incoming and outgoing messages but
    %% not node specific messages as in this case.
    ered_msgtracer_manager:node_received_msg(NodeDef, self(), Msg3),
    {handled, NodeDef, Msg3};
handle_msg(
    {mqtt_incoming, MqttDataPacket},
    #{?GetWsName} = NodeDef
) ->
    {outgoing, Msg} = create_outgoing_msg(WsName),
    Msg2 = copy_attributes([payload, topic, retain, qos], Msg, MqttDataPacket),
    send_msg_to_connected_nodes(NodeDef, Msg2),
    %% the ered_node behaviour covers incoming and outgoing messages but
    %% not node specific messages as in this case.
    ered_msgtracer_manager:node_received_msg(NodeDef, self(), Msg2),
    {handled, NodeDef, Msg2};
handle_msg(
    {incoming, #{<<"action">> := <<"connect">>} = Msg},
    #{?MQTT_MGR_PID} = NodeDef
) ->
    R = gen_server:call(MqttMgrPid, connect),
    send_msg_to_connected_nodes(NodeDef, Msg#{?AddPayload(R)}),
    {handled, NodeDef, dont_send_complete_msg};
handle_msg(
    {incoming, #{<<"action">> := <<"subscribe">>, ?GetTopic} = Msg},
    #{?MQTT_MGR_PID} = NodeDef
) when is_binary(Topic) ->
    %% TODO topic can be an array of objects or just a single object with
    %% TODO topic and qos properties.
    R = gen_server:call(
        MqttMgrPid,
        {subscribe, #{}, [{Topic, [{qos, 0}]}]}
    ),

    case R of
        {ok, _, _} ->
            send_msg_to_connected_nodes(NodeDef, Msg#{?AddPayload(<<"ok">>)});
        R ->
            send_msg_to_connected_nodes(NodeDef, Msg#{?AddPayload(R)})
    end,
    {handled, NodeDef, dont_send_complete_msg};
handle_msg(
    {incoming, #{<<"action">> := <<"unsubscribe">>, ?GetTopic} = Msg},
    #{?MQTT_MGR_PID} = NodeDef
) ->
    R = gen_server:call(
        MqttMgrPid,
        {unsubscribe, #{}, [Topic]}
    ),

    case R of
        {ok, _, _} ->
            send_msg_to_connected_nodes(NodeDef, Msg#{?AddPayload(<<"ok">>)});
        R ->
            send_msg_to_connected_nodes(NodeDef, Msg#{?AddPayload(R)})
    end,
    {handled, NodeDef, dont_send_complete_msg};
handle_msg(
    {incoming, #{<<"action">> := <<"disconnect">>} = Msg},
    #{?MQTT_MGR_PID} = NodeDef
) ->
    R = gen_server:call(MqttMgrPid, disconnect),
    send_msg_to_connected_nodes(NodeDef, Msg#{?AddPayload(R)}),
    {handled, NodeDef, dont_send_complete_msg};
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% -------------- Helpers
%%

copy_attributes([], Msg, _MqttDataPacket) ->
    Msg;
copy_attributes([Attr | Attrs], Msg, MqttDataPacket) ->
    copy_attributes(
        Attrs,
        maps:put(atom_to_binary(Attr), maps:get(Attr, MqttDataPacket), Msg),
        MqttDataPacket
    ).

%% erlfmt:ignore alignment
create_mqtt_manager(#{
        <<"broker">>          := Host,
        <<"port">>            := Port,
        <<"usetls">>          := UseTls,
        <<"cleansession">>    := CleanStart,
        <<"keepalive">>       := KeepAlive,
        <<"willTopic">>       := WillTopic,
        <<"willQos">>         := WillQoS,
        <<"willRetain">>      := WillRetain,
        <<"willMsg">>         := WillMsg,
        <<"protocolVersion">> := ProtoVer
} = Cfg, WsName) ->
    Options = [
        {host,        Host},
        {port,        convert_to_num(Port)},
        {ssl,         to_bool(UseTls)},
        {clean_start, CleanStart},
        {proto_ver,   to_ver_atom(ProtoVer)},
        {keepalive,   convert_to_num(KeepAlive)},
        {will_topic,  WillTopic},
        {will_qos,    convert_to_num(WillQoS)},
        {will_retain, to_bool(WillRetain)},
        {will_props,  WillMsg},
        {force_ping,  true}
        %% TODO respect the client id but we don't
        %% {clientid, maps:get(<<"clientid">>, Cfg)},
        %% {will_payload, maps:get(<<"willPayload">>, Cfg)},
        %% {properties, maps:get(<<"userProps">>, Cfg)}
    ],

    %% Credentials set?
    Opts2 =
        case maps:find(<<"credentials">>, Cfg) of
            {ok, Creds} ->
                Options ++ add_user_and_pass(Creds);
            _ ->
                Options
        end,

    %% verify ssl certificates?
    Opts3 =
        case {to_bool(UseTls), maps:find(<<"tls">>, Cfg)} of
            {true, {ok, TlsCfgId}} ->
                case retrieve_config_node(TlsCfgId, WsName) of
                    {ok, #{<<"verifyservercert">> := false} = _TlsCfg} ->
                        Opts2 ++ [{ssl_opts, [{verify, verify_none}]}];
                    _ ->
                        Opts2
                end;
            _ ->
                Opts2
        end,

    {ok, MqttMgrPid} = ered_mqtt_manager:start(self(), Opts3),

    MqttMgrPid.

setup_mqtt_manager(NodeDef, WsName) ->
    case maps:find(<<"broker">>, NodeDef) of
        {ok, CfgNodeId} ->
            case retrieve_config_node(CfgNodeId, WsName) of
                {ok, Cfg} ->
                    ?NodeStatus("connecting", "yellow", "dot"),

                    MqttMgrPid = create_mqtt_manager(Cfg, WsName),

                    erlang:monitor(process, MqttMgrPid),

                    TRef = erlang:start_timer(
                        750,
                        self(),
                        {connect_to_broker, MqttMgrPid}
                    ),

                    ?AddWsName(NodeDef#{
                        '_timer' => TRef,
                        '_mqtt_mgr_id' => MqttMgrPid
                    });
                _ ->
                    ?NodeStatus("connecting (no cfg)", "yellow", "dot"),
                    NodeDef
            end;
        _ ->
            ?NodeStatus("connecting (no broker)", "yellow", "dot"),
            NodeDef
    end.

%%
%% ----------------- helpers
%%
to_ver_atom(V) when is_list(V) ->
    list_to_atom("v" ++ V);
to_ver_atom(V) when is_binary(V) ->
    to_ver_atom(binary_to_list(V));
to_ver_atom(V) when is_integer(V) ->
    to_ver_atom(integer_to_list(V)).

%%
%%
add_user_and_pass(#{<<"user">> := <<>>, <<"password">> := <<>>}) ->
    [];
add_user_and_pass(#{<<"user">> := <<>>, <<"password">> := Pword}) ->
    [{password, Pword}];
add_user_and_pass(#{<<"user">> := User, <<"password">> := <<>>}) ->
    [{username, User}];
add_user_and_pass(#{<<"user">> := User, <<"password">> := Pword}) ->
    [{username, User}, {password, Pword}];
add_user_and_pass(#{<<"user">> := User}) ->
    [{username, User}];
add_user_and_pass(#{<<"password">> := Pword}) ->
    [{password, Pword}];
add_user_and_pass(_) ->
    [].
