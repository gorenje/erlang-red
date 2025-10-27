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
    start_link/0
]).

%% actually functionality
-export([
    store_config_node/2,
    retrieve_config_node/2
]).

%%
%% This maintains a lookup between WebSocket and config store.
%%

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%
%%
init([]) ->
    {ok, #{storage => []}}.

%%
%% store implementaion
-spec store_config_node(NodeDef :: map(), WsName :: atom()) -> ok.
store_config_node(NodeDef, WsName) ->
    gen_server:call(?MODULE, {store_config, NodeDef, WsName}).

-spec retrieve_config_node(NodeId :: binary(), WsName :: atom()) ->
    {ok, Config :: map()} | unavailable.
retrieve_config_node(NodeId, WsName) ->
    gen_server:call(?MODULE, {get_config, NodeId, WsName}).

%%
handle_call(
    {store_config, #{<<"id">> := NodeId, <<"type">> := NodeType} = NodeDef,
        WsName},
    _From,
    State
) ->
    {Storage, State2} = get_storage(State, WsName),
    R = gen_server:call(Storage, {store_config, NodeId, NodeType, NodeDef}),
    {reply, R, State2};
%%
handle_call({get_config, NodeId, WsName}, _From, State) ->
    {Storage, State2} = get_storage(State, WsName),
    R = gen_server:call(Storage, {get_config, NodeId}),
    {reply, R, State2};
%%
handle_call(state, _From, Store) ->
    {reply, Store, Store};
%%
handle_call(_Msg, _From, Store) ->
    {reply, ok, Store}.

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

%%
%% --------------------- helpers
%%
get_storage(#{storage := Storers} = State, WsName) ->
    case lists:keyfind(WsName, 1, Storers) of
        false ->
            {ok, Str} = ered_cfg_storage:start_link(WsName),
            {Str, State#{storage => [{WsName, Str} | Storers]}};
        {WsName, Str} ->
            {Str, State}
    end.
