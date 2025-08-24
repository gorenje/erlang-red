-module(ered_unittest_engine).

-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2]).
-export([handle_info/2, terminate/2, code_change/3]).
-export([stop/0]).
-export([start/0]).

%%
%% This engine is designed to run unit tests just as eunit does. Therefore
%% it also implements a listener for "should not happen" events. These are
%% passed to the error store service and then retrieved at the end of a test
%% to decided whether a test was successful or not.
%%

%%
%% These aren't exported to be used external, these are "internal" exports.
-export([
    not_happen_loop/2,
    run_test_on_another_planet/4
]).

%%
%%
-import(ered_flows, [
    compute_timeout/2,
    is_test_case_pending/1,
    parse_flow_file/1,
    should_keep_flow_running/1
]).
-import(ered_nodes, [
    tabid_to_error_collector/1,
    trigger_outgoing_messages/3
]).
-import(ered_startup, [
    create_pids_for_nodes/2
]).
-import(ered_nodered_comm, [
    debug/3,
    debug_string/3,
    unittest_result/3
]).
-import(ered_message_exchange, [
    clear_completed_group/2,
    clear_exception_group/2
]).

%%
%%
start() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%
%%
init([]) ->
    {ok, #{}}.

handle_call(_Msg, _From, State) ->
    {reply, State, State}.

%%
%%
handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Msg, Store) ->
    {noreply, Store}.

handle_info({start_test, FlowId, WsName}, State) ->
    spawn(
        ?MODULE,
        run_test_on_another_planet,
        [FlowId, WsName, false, false]
    ),
    {noreply, State};
handle_info({start_test, FlowId, WsName, IgnPendingFlag}, State) ->
    spawn(
        ?MODULE,
        run_test_on_another_planet,
        [FlowId, WsName, IgnPendingFlag, false]
    ),
    {noreply, State};
handle_info(
    {start_test_with_timeout, FlowId, WsName, IgnPendingFlag, Timeout},
    State
) ->
    spawn(
        ?MODULE,
        run_test_on_another_planet,
        [FlowId, WsName, IgnPendingFlag, Timeout]
    ),
    {noreply, State};
handle_info(stop, ErrorStore) ->
    gen_server:cast(?MODULE, stop),
    {noreply, ErrorStore};
handle_info(_Msg, ErrorStore) ->
    {noreply, ErrorStore}.

code_change(_OldVersion, ErrorStore, _Extra) ->
    {ok, ErrorStore}.

stop() ->
    gen_server:cast(?MODULE, stop).

%%
%%
terminate(normal, _State) ->
    ok;
terminate(Event, _State) ->
    io:format("Unittest engine terminated with {{{ ~p }}}~n", [Event]),
    ok.

%%
%% -------------------- helpers
%%
%%
stop_all_pids([], _) ->
    ok;
stop_all_pids([Pid | Pids], WsName) when Pid =:= false ->
    stop_all_pids(Pids, WsName);
stop_all_pids([Pid | Pids], WsName) ->
    (is_process_alive(Pid) =/= false) andalso (Pid ! {stop, WsName}),
    stop_all_pids(Pids, WsName).

not_happen_loop(TestName, ErrorStorePid) ->
    receive
        stop ->
            ok;
        {it_happened, {NodeId, TabId}, Arg} ->
            Str = io_lib:format("~s in ~s\n", [Arg, TestName]),
            ErrorStorePid ! {store_msg, {NodeId, TabId, list_to_binary(Str)}},
            not_happen_loop(TestName, ErrorStorePid);
        _ ->
            not_happen_loop(TestName, ErrorStorePid)
    end.

ensure_error_store_is_started(TabErrColl, TestName) ->
    case ered_error_store:start_link() of
        {error, {already_started, ErrorStorePid}} ->
            Pid = spawn(?MODULE, not_happen_loop, [TestName, ErrorStorePid]),
            register(TabErrColl, Pid),
            TabErrColl;
        {ok, ErrorStorePid} ->
            Pid = spawn(?MODULE, not_happen_loop, [TestName, ErrorStorePid]),
            register(TabErrColl, Pid),
            TabErrColl;
        _ ->
            error
    end.

start_this_should_not_happen_service(TabId, TestName) ->
    TabErrColl = tabid_to_error_collector(TabId),

    case whereis(TabErrColl) of
        undefined ->
            error;
        _ ->
            TabErrColl ! stop,
            unregister(TabErrColl)
    end,
    ensure_error_store_is_started(TabErrColl, TestName).

send_off_test_result(WsName, FlowId, []) ->
    unittest_result(WsName, FlowId, success);
send_off_test_result(WsName, FlowId, Ary) ->
    unittest_result(WsName, FlowId, failed),
    dump_errors_onto_nodered(Ary, FlowId, WsName).

dump_errors_onto_nodered([], _FlowId, _WsName) ->
    ok;
dump_errors_onto_nodered([{NodeId, Msg} | T], FlowId, WsName) ->
    debug(WsName, debug_string(NodeId, FlowId, Msg), notice),
    dump_errors_onto_nodered(T, FlowId, WsName).

%%
%% respect the pending flag on a flow test
run_test_on_another_planet(FlowId, WsName, false, DefaultTimeout) ->
    ered_error_store:reset_errors(FlowId),

    case ered_flow_store_server:get_filename(FlowId) of
        error ->
            unittest_result(WsName, FlowId, unknown_testcase);
        FileName ->
            Ary = parse_flow_file(FileName),

            case is_test_case_pending(Ary) of
                true ->
                    unittest_result(WsName, FlowId, pending);
                false ->
                    run_the_test(FlowId, WsName, Ary, DefaultTimeout)
            end
    end;
%%
%% ignore the pending flag of a flow tests
run_test_on_another_planet(FlowId, WsName, true, DefaultTimeout) ->
    ered_error_store:reset_errors(FlowId),

    case ered_flow_store_server:get_filename(FlowId) of
        error ->
            unittest_result(WsName, FlowId, unknown_testcase);
        FileName ->
            Ary = parse_flow_file(FileName),

            run_the_test(FlowId, WsName, Ary, DefaultTimeout)
    end.

%%
%% Run the test disregarding the pending flag of the test flow.
run_the_test(FlowId, WsName, Ary, DefaultTimeout) ->
    case should_keep_flow_running(Ary) of
        true ->
            create_pids_for_nodes(Ary, WsName);
        false ->
            ErrColl = start_this_should_not_happen_service(
                FlowId,
                <<"UnitTestEngine TestRun">>
            ),

            %% Clear the message exchange so that the complete and catch
            %% nodes have a clean start.
            clear_completed_group(FlowId, WsName),
            clear_exception_group(FlowId, WsName),

            %% there are exception groups for nodes aswell, remove those
            %% too.
            Cleaner = fun(NodeDef) ->
                {ok, NodeId} = maps:find(<<"id">>, NodeDef),
                clear_exception_group(NodeId, WsName)
            end,
            [Cleaner(NodeDef) || NodeDef <- Ary],

            Pids = create_pids_for_nodes(Ary, WsName),

            [
                trigger_outgoing_messages(
                    maps:get(<<"type">>, ND),
                    maps:get(<<"id">>, ND),
                    WsName
                )
             || ND <- Ary
            ],

            %% give the messages time to propagate through the
            %% test flow
            timer:sleep(compute_timeout(Ary, DefaultTimeout)),

            %% stop all nodes. Probably better would be to checking
            %% the message queues of the nodes and if all are empty
            %% it's probably safe to end the test case.
            stop_all_pids(Pids, WsName),

            %% some asserts work on the stop notification, give'em
            %% time to generate their results.
            timer:sleep(543),
            case whereis(ErrColl) of
                undefined ->
                    ignore;
                _ ->
                    ErrColl ! stop
            end,

            send_off_test_result(
                WsName,
                FlowId,
                ered_error_store:get_errors(FlowId)
            )
    end.
