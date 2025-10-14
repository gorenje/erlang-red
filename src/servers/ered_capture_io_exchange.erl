-module(ered_capture_io_exchange).

-behaviour(gen_server).

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
    capture/3,
    capture_remove/2,
    pid_for/3
]).

%%
%% There is one capture exchange per Erlang-Red instance, this instance
%% spins up a group leader process for each websocket created. Each group
%% leader process is shared across all processes that are being captured
%% for that websocket.
%%
%% Also need to check the list of what process is being started for
%% which node id and what node id should be captured, there is no order
%% in initialisation and therefore need to check each time something
%% happens.
%%
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, #{}, []).

init(Args) ->
    {ok, Args#{leaders => []}}.

capture(NodeId, Wires, WsName) ->
    gen_server:call(?MODULE, {capture, NodeId, Wires, WsName}).
capture_remove(NodeId, WsName) ->
    gen_server:call(?MODULE, {remove, NodeId, WsName}).

pid_for(NodeId, Pid, WsName) ->
    gen_server:call(?MODULE, {pid, Pid, NodeId, WsName}).

%%
%%
%%  ------------------ call

handle_call({capture, NodeId, Wires, WsName}, _From, State) ->
    {Ldr, State2} = get_leader(State, WsName),
    R = gen_server:call(Ldr, {capture, NodeId, Wires}),
    {reply, R, State2};
handle_call({pid, Pid, NodeId, WsName}, _From, State) ->
    {Ldr, State2} = get_leader(State, WsName),
    R = gen_server:call(Ldr, {pid, Pid, NodeId}),
    {reply, R, State2};
handle_call({remove, NodeId, WsName}, _From, State) ->
    {Ldr, State2} = get_leader(State, WsName),
    R = gen_server:call(Ldr, {remove, NodeId}),
    {reply, R, State2};
%%
handle_call(state, _From, State) ->
    {reply, State, State};
handle_call(deep_state, _From, #{leaders := Leaders} = State) ->
    {reply,
        maps:from_list([
            {Pid, gen_server:call(Ldr, state)}
         || {Pid, Ldr} <- Leaders
        ]), State};
handle_call({print, What}, _From, State) ->
    io:format("~p", [What]),
    {reply, ok, State};
%% fall through
handle_call(M, _From, State) ->
    io:format("~p~n", [M]),
    {reply, ok, State}.

%%
%%
%%  ------------------ cast

handle_cast(stop, State) ->
    {stop, State};
handle_cast(_, State) ->
    {noreply, State}.

%%
%%
%%  ------------------ info
handle_info(_, State) ->
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
get_leader(#{leaders := Leaders} = State, WsName) ->
    case lists:keyfind(WsName, 1, Leaders) of
        false ->
            {ok, Ldr} = ered_capture_io_group_leader:start_link(WsName),
            {Ldr, State#{leaders => [{WsName, Ldr} | Leaders]}};
        {WsName, Ldr} ->
            {Ldr, State}
    end.
