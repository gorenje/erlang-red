-module(ered_config_store).
-behaviour(gen_server).

%% gen_server interface
-export([
    init/1,
    code_change/3,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    stop/0,
    start/0
]).

%% actually functionality
-export([
    store_config_node/2,
    retrieve_config_node/1
]).

%%
%% Store for maintaining a collection of config nodes. These can be referenced
%% by those nodes that need them.
%%
%% Config nodes are used in Node-RED to share configuration of services
%% amongst many nodes. For example external network protocols (e.g. MQTT,
%% websocket) have a single configuration node and many nodes that use that
%% configuration.
%%
%% This store only has a store and retrieve API, there is no update and a
%% store call will overwrite any existing config node.
%%
%% TODO: scope this on the websocket, probably best just to spin up a
%% TODO: new store per websocket connection. Have a supervisor instance
%% TODO: take care of that. This is what the captureIO server does - it spins
%% TODO: up a gen_server per websocket connection. This should definitely do
%% TODO: the same.
%%

start() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%
%%
init([]) ->
    {ok, #{}}.

%%
%% store implementaion
-spec store_config_node(NodeId :: binary(), NodeDef :: map()) -> ok.
store_config_node(NodeId, NodeDef) ->
    gen_server:call(?MODULE, {store_config, NodeId, NodeDef}).

-spec retrieve_config_node(NodeId :: binary()) ->
    {ok, Config :: map()} | unavailable.
retrieve_config_node(NodeId) ->
    gen_server:call(?MODULE, {get_config, NodeId}).

%%
handle_call({store_config, NodeId, NodeDef}, _From, ConfigStore) ->
    ConfigStoreNew = maps:put(NodeId, NodeDef, ConfigStore),
    {reply, ok, ConfigStoreNew};
handle_call({get_config, NodeId}, _From, ConfigStore) ->
    Reply =
        case maps:find(NodeId, ConfigStore) of
            {ok, Cfg} ->
                {ok, Cfg};
            _ ->
                unavailble
        end,
    {reply, Reply, ConfigStore};
handle_call(_Msg, _From, Store) ->
    {reply, Store, Store}.

stop() ->
    gen_server:cast(?MODULE, stop).

%%
%%
terminate(normal, _State) ->
    ok;
terminate(Event, _State) ->
    io:format("Config Store Terminated with {{{ ~p }}}~n", [Event]),
    ok.

handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Msg, Store) ->
    {noreply, Store}.

%%
handle_info(stop, Store) ->
    gen_server:cast(?MODULE, stop),
    {noreply, Store}.

code_change(_OldVersion, Store, _Extra) ->
    {ok, Store}.
