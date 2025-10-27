-module(ered_kafka_client_manager).

-behaviour(gen_server).

-export([
    init/1,
    code_change/3,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    handle_continue/2,
    terminate/2,
    stop/0,
    start_link/0
]).

-export([
    start_client/3
]).

%%
%%
start_link() ->
    {ok, _} = application:ensure_all_started(brod),
    gen_server:start_link({local, ?MODULE}, ?MODULE, #{}, []).

init(Args) ->
    {ok, Args#{clients => [], nodeids => []}}.

-spec start_client(
    CfgNodeId :: binary(),
    KafkaNodeId :: binary(),
    WsName :: atom()
) ->
    ClientId :: atom().
start_client(CfgNodeId, KafkaNodeId, WsName) ->
    gen_server:call(?MODULE, {start_client, CfgNodeId, KafkaNodeId, WsName}).

%%
%%
%%  ------------------ call

handle_call(
    {start_client, CfgNodeId, KafkaNodeId, WsName},
    _From,
    #{nodeids := NodeClients} = State
) ->
    Lst = ["kfkcln", binary_to_list(CfgNodeId), atom_to_list(WsName)],

    ClientId = list_to_atom(string:join(Lst, "_")),

    {reply, ClientId,
        State#{nodeids => [{ClientId, KafkaNodeId, WsName} | NodeClients]},
        {continue, {start_client, ClientId, CfgNodeId, WsName}}};
%%
handle_call(state, _From, State) ->
    {reply, State, State};
%% fall through
handle_call(C, _From, State) ->
    io:format("GOT CAL : ~p~n", [C]),
    {reply, ok, State}.

%%
%%
%% ------------------- continue
handle_continue(
    {start_client, ClientId, CfgNodeId, WsName},
    #{clients := Clients} = State
) ->
    case lists:keyfind(ClientId, 1, Clients) of
        false ->
            {ok, #{
                <<"auth">> := Auth,
                <<"brokers">> := Brokers,
                <<"connectiontimeout">> := ConnTimeout,
                <<"id">> := CfgNodeId,
                <<"requesttimeout">> := ReqTimeout,
                <<"saslssl">> := _SaslSsl,
                <<"type">> := <<"ered-kafka-broker">>
            }} = ered_config_store:retrieve_config_node(CfgNodeId, WsName),

            ClientConfig = [
                {reconnect_cool_down_seconds, 10},
                {connect_timeout, ConnTimeout},
                {request_timeout, ReqTimeout},
                {ssl, Auth =:= <<"tls">>}
            ],

            brod:start_client(
                brokers_to_tuple_list(Brokers),
                ClientId,
                ClientConfig
            ),

            %% TODO add polling here or something to know when the client
            %% TODO is connected, disconnecting, reconnecting ... so that
            %% TODO node status information can be updated accordingly.
            {noreply, State#{clients => [ClientId | Clients]}};
        _ ->
            {noreply, State}
    end;
handle_continue(_, State) ->
    {noreply, State}.

%%
%%
%%  ------------------ cast

handle_cast(stop, State) ->
    {stop, State};
handle_cast(C, State) ->
    io:format("GOT CAST : ~p~n", [C]),
    {noreply, State}.

%%
%%
%%  ------------------ info
handle_info(C, State) ->
    io:format("GOT INFO : ~p~n", [C]),
    {noreply, State}.

%%
%%
code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

stop() ->
    gen_server:cast(?MODULE, stop).

%%
%%
terminate(normal, _State) ->
    ok;
terminate(_, _State) ->
    ok.

%%
%% --------------------- helpers
%%
%% convert <<"renderbox:9092,dd:222">> to [{"renderbox",9092},{"dd",222}]
brokers_to_tuple_list(Brokers) when is_binary(Brokers) ->
    brokers_to_tuple_list(string:split(Brokers, ",", all));
brokers_to_tuple_list([Broker | MoreBrokers]) when is_binary(Broker) ->
    brokers_to_tuple_list([string:split(Broker, ":") | MoreBrokers]);
brokers_to_tuple_list(
    [[Host, Port] | MoreBrokers]
) when is_binary(Host), is_binary(Port) ->
    [
        {binary_to_list(Host), binary_to_integer(Port)}
        | brokers_to_tuple_list(MoreBrokers)
    ];
brokers_to_tuple_list(_) ->
    [].
