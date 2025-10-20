-module(ered_mqtt_manager).

-behaviour(gen_server).

-export([
    init/1,
    code_change/3,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    stop/0,
    start/2
]).

%%
%% The MQTT manager is used by the mqtt in and mqtt out nodes as a shield
%% from unexpected behaviour. Such as a MQTT broker not being there when
%% wanting to connect.
%%
%% The emqtt library assumes the owner is also a gen_server of some kind
%% and will propagate a shutdown all the way up the linked ladder.
%%
%% So this gen_server is started as an unlinked gen_server so that the
%% emqtt gen_server can link itself to this manager. If the emqtt
%% does transmit a shutdown exit message, it stops here and doesn't
%% teardown either the node process nor the rest of the servers.
%%
%% In addition, what this does is map the messages sent from the emqtt
%% library to ErlangRED messages, e.g publish becomes mqtt_incoming and
%% is converted to a cast, instead of info.
%%
%% TODO there should really only be one of these for a collection of MQTT
%% TODO nodes. In fact, there should be one per config node. This would
%% TODO require more work so LIFL - leave it for later!
%%
start(NodePid, MqttOptions) ->
    {ok, _} = application:ensure_all_started(emqtt),
    gen_server:start(?MODULE, [NodePid, MqttOptions], []).

init([NodePid, MqttOptions]) ->
    {ok, #{opts => MqttOptions, nodepid => NodePid}}.

%%
%%
handle_call(start_mqtt, _From, State) ->
    %% Client from the config node should be represented and only a single
    %% instance per clientid should be created, i.e., one instance per config
    %% node.
    ClientId = list_to_binary(
        io_lib:format(
            "erlang_erd_~s", [ered_nodes:generate_id()]
        )
    ),
    Opts = [{owner, self()}, {clientid, ClientId}] ++ maps:get(opts, State),

    case emqtt:start_link(Opts) of
        {ok, EmqttClientId} ->
            {reply, ok, maps:put(emqtt_client_id, EmqttClientId, State)};
        Error ->
            {reply, Error, State}
    end;
handle_call(connect, _From, State) ->
    ConnPid = maps:get(emqtt_client_id, State),
    case emqtt:connect(ConnPid) of
        {ok, Props} ->
            {reply, {ok, Props}, State};
        Reason ->
            {reply, Reason, State}
    end;
handle_call(disconnect, _From, State) ->
    ConnPid = maps:get(emqtt_client_id, State),
    case emqtt:disconnect(ConnPid) of
        ok ->
            {reply, ok, State};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call(
    {subscribe, Opts, Topics},
    _From,
    #{emqtt_client_id := ConnPid} = State
) ->
    {reply, emqtt:subscribe(ConnPid, Opts, Topics), State};
handle_call(
    {unsubscribe, Opts, Topics},
    _From,
    #{emqtt_client_id := ConnPid} = State
) ->
    {reply, emqtt:unsubscribe(ConnPid, Opts, Topics), State};
handle_call(Msg, _From, State) ->
    io:format("MQTT Manager Call: ~p~n", [Msg]),
    {reply, ok, State}.

%%
%%
handle_cast(Msg = {publish_payload, Payload, Topic, QoS, Retain}, State) ->
    %% this is an MQTT out node sending out a message to MQTT broker.
    %% publish is perhaps a misnomer here since there is already a
    %% publish event
    case maps:find(emqtt_client_id, State) of
        {ok, EmqttClientId} ->
            emqtt:publish(
                EmqttClientId,
                Topic,
                #{},
                Payload,
                [{qos, QoS}, {retain, Retain}]
            ),
            {noreply, State};
        _ ->
            %% Return to sender - message could not be sent.
            NodePid = maps:get(nodepid, State),
            gen_server:cast(NodePid, {mqtt_not_sent, #{orig => Msg}}),
            {noreply, State}
    end;
handle_cast(stop, State) ->
    io:format("MQTT Manager stop casted~n", []),
    {stop, normal, State};
handle_cast(Msg, State) ->
    io:format("MQTT Manager Cast: ~p~n", [Msg]),
    {noreply, State}.

%%
%%
handle_info({disconnected, ReasonCode, Properties}, State) ->
    maps:get(nodepid, State) ! {mqtt_disconnected, ReasonCode, Properties},
    {noreply, State};
handle_info({publish, MqttDataPacket}, State) ->
    %% this is a message the came into MQTT broker and is being sent
    %% to a subscriber
    RecPid = maps:get(nodepid, State),
    gen_server:cast(RecPid, {mqtt_incoming, MqttDataPacket}),
    {noreply, State};
handle_info(Msg, State) ->
    io:format("MQTT Manager Info: ~p~n", [Msg]),
    {noreply, State}.

%%
%%
code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

stop() ->
    gen_server:cast(?MODULE, stop).

terminate(normal, _State) ->
    ok;
terminate(Event, _State) ->
    io:format("MQTT manager terminated with {{{ ~p }}}~n", [Event]),
    ok.
