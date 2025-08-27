-module(ered_compute_engine).

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
    deploy/2,
    reload/1,
    stop/1
]).

%%
%% Compute engine for executing flows on this server.
%%
%% Compute engine creates the pids for each node and lets those processes
%% run. The unitest engine runs flows and then brings down the processes
%% after the test.
%%

-import(ered_startup, [
    create_pids_for_nodes/2
]).
-import(ered_nodes, [
    get_node_name/2
]).
-import(ered_messages, [
    decode_json/1
]).
-import(ered_flows, [
    parse_flow_file/1
]).

start_link() ->
    %% trigger the loading of an initial flow file. This can be used in
    %% conjunction with DISABLE_FLOWEDITOR to have just a single flow running
    %% on the ErlangRED compute engine, i.e. a headless deployment.
    case os:getenv("COMPUTEFLOW") of
        false ->
            ignore;
        FlowIdsCommaSeparated ->
            [
                erlang:start_timer(
                    750,
                    ered_compute_engine,
                    {load_flowid, FlowId}
                )
             || FlowId <- string:split(FlowIdsCommaSeparated, ",", all),
                FlowId =/= []
            ]
    end,
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%
%% External API
deploy(JsonStr, WsName) ->
    gen_server:call(?MODULE, {deploy, JsonStr, WsName}).

reload(WsName) ->
    gen_server:call(?MODULE, {reload, WsName}).

stop(WsName) ->
    %% stop is equivalent to deploying an empty JSON file.
    gen_server:call(?MODULE, {deploy, <<"{\"flows\": []}">>, WsName}).

%%
%%
init([]) ->
    {ok, #{}}.

%%
%%
handle_call({reload, WsName}, _From, State) ->
    %%
    %% this is a restart so go through all nodes that have a prefix
    %% node_pid_ws<....> in the pg groups and reset their state, ie.
    %% send them an event to reset their state, i.e., the reload event.
    %%
    Prefix = get_node_name(WsName, <<"">>),
    Nodes = lists:filter(
        fun(AA) -> binary:match(AA, Prefix) =/= nomatch end,
        pg:which_groups()
    ),
    [[M ! {reload} || M <- pg:get_members(GrpName)] || GrpName <- Nodes],
    {reply, <<"{\"rev\":\"dead060d\"}">>, State};
handle_call({deploy, JsonStr, WsName}, _From, State) ->
    %% here we want to do a deploy which means using the prefix
    %% node_pid_ws<....> and either stopping those processes that no
    %% no longer exist or reseting their state if they do. or simply
    %% remove all nodes with the prefix and restart create them all

    Prefix = get_node_name(WsName, <<"">>),

    %% TODO this list has to be sorted by type: the supervisors MUST be stopped
    %% TODO first else they restart process that have been stopped, i.e., a node
    %% TODO is sent a stop and then the supervisor node restarts it and then
    %% TODO the node is restarted again during the create pid phase.
    Nodes = lists:filter(
        fun(AA) -> binary:match(AA, Prefix) =/= nomatch end,
        pg:which_groups()
    ),

    ProcessKill = fun(Pid) ->
        (is_process_alive(Pid) =/= false) andalso
            (Pid =/= false) andalso
            (Pid ! {stop, WsName})
    end,

    [[ProcessKill(M) || M <- pg:get_members(GrpName)] || GrpName <- Nodes],

    %% This is a sympton of the ordering of node types -- i.e. supervisor should
    %% be stopped first before other nodes - see comment above.
    [timer:sleep(length(pg:get_members(GrpName)) * 550) || GrpName <- Nodes],

    FlowMap = decode_json(JsonStr),
    {ok, NodeAry} = maps:find(<<"flows">>, FlowMap),

    create_pids_for_nodes(NodeAry, WsName),

    {reply, <<"{\"rev\":\"fed00d06\"}">>, State};
handle_call(_Msg, _From, State) ->
    {reply, State, State}.

%%
%%
handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%
%% This should only be called once at the beginning of the app load
%% it is used in conjunection with a headless deployment to have a Erlang
%% setup running based on a single flow file.
handle_info({timeout, _From, {load_flowid, FlowId}}, State) ->
    io:format("Loading initial flow id ~p~n", [FlowId]),
    case ered_flow_store_server:get_filename(FlowId) of
        error ->
            io:format(
                "WARNING: FlowId '~s' not found, doing nothing.~n",
                [FlowId]
            ),
            ignore;
        FileName ->
            Ary = parse_flow_file(FileName),
            %% Websockets are scopes that identify a client using the
            %% floweditor to execute flows. If there is no floweditor
            %% frontend and a flow is loaded what then? Well it's a none
            %% websocket. Important is that a websocket name is supplied.
            create_pids_for_nodes(Ary, none)
    end,
    {noreply, State};
handle_info(Msg, State) ->
    io:format("Compute engine, unknown info: {{ ~p }}~n", [Msg]),
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
    io:format("Compute Engine Terminated with {{{ ~p }}}~n", [Event]),
    ok.
