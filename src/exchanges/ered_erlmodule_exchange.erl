-module(ered_erlmodule_exchange).

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

-export([
    add_module/2,
    find_module/1,
    remove_module_for_nodeid/1
]).

%%
%% NodeId - Module name lookup for the Event handler.
%%

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #{}}.

%%
%%
-spec add_module(NodeId :: binary(), ModuleName :: atom()) -> ok.
add_module(NodeId, ModuleName) ->
    gen_server:call(?MODULE, {add_module, NodeId, ModuleName}).

-spec find_module(NodeId :: binary()) ->
    {ok, ModuleName :: atom()}
    | {not_found, NodeId :: binary()}.
find_module(NodeId) ->
    gen_server:call(?MODULE, {find_module, NodeId}).

-spec remove_module_for_nodeid(NodeId :: binary()) -> ok.
remove_module_for_nodeid(NodeId) ->
    gen_server:call(?MODULE, {remove_module, NodeId}).

%%
%%
handle_call({add_module, NodeId, ModuleName}, _From, Store) ->
    {reply, ok, Store#{NodeId => ModuleName}};
handle_call({find_module, NodeId}, _From, Store) ->
    {reply,
        case maps:find(NodeId, Store) of
            {ok, ModuleName} ->
                {ok, ModuleName};
            _ ->
                {not_found, NodeId}
        end,
        Store};
handle_call({remove_module, NodeId}, _From, Store) ->
    {reply, ok, maps:remove(NodeId, Store)};
handle_call(_Msg, _From, Store) ->
    {reply, ok, Store}.

%%
%%
terminate(normal, _State) ->
    ok;
terminate(Event, _State) ->
    io:format("Erlmodule Exchange Terminated with {{{ ~p }}}~n", [Event]),
    ok.

%%
%%
handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Msg, Store) ->
    {noreply, Store}.

%%
handle_info(stop, Store) ->
    {stop, normal, Store};
handle_info(_Msg, Store) ->
    {noreply, Store}.

%%
%%
code_change(_OldVersion, Store, _Extra) ->
    {ok, Store}.

stop() ->
    gen_server:cast(?MODULE, stop).
