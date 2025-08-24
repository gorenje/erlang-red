-module(flow_file_test).

-include_lib("eunit/include/eunit.hrl").

-export([not_happen_loop/2]).
-export([websocket_faker/1]).

stop_all_pids([]) ->
    ok;
stop_all_pids([Pid | Pids]) when Pid =:= false ->
    stop_all_pids(Pids);
stop_all_pids([Pid | Pids]) ->
    (is_process_alive(Pid) =/= false) andalso (Pid ! {stop, none}),
    stop_all_pids(Pids).

%%
%% Node-RED frontend has a "create test case" that allows exporting of flows
%% to become cases. This test goes through and tests all off them.
%%

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

websocket_faker(WsName) ->
    receive
        stop ->
            ok;
        {debug, Data, normal} ->
            ered_ws_event_exchange:debug_msg({ok, WsName}, normal, Data),
            websocket_faker(WsName);
        {debug, Data, notice} ->
            ered_ws_event_exchange:debug_msg({ok, WsName}, notice, Data),
            websocket_faker(WsName);
        {debug, Data, warning} ->
            ered_ws_event_exchange:debug_msg({ok, WsName}, warning, Data),
            websocket_faker(WsName);
        {debug, Data, error} ->
            ered_ws_event_exchange:debug_msg({ok, WsName}, error, Data),
            websocket_faker(WsName);
        {status, NodeId, T, C, S} ->
            ered_ws_event_exchange:node_status({ok, WsName}, NodeId, T, C, S),
            websocket_faker(WsName);
        {status, _NodeId, clear} ->
            websocket_faker(WsName);
        Unknown ->
            io:format("WS faker got unknown msg: ~p~n", [Unknown]),
            websocket_faker(WsName)
    end.

ensure_websocket_listener_is_running(WsName) ->
    ered_ws_event_exchange:start(),

    case whereis(WsName) of
        undefined ->
            Pid = spawn(?MODULE, websocket_faker, [WsName]),
            register(WsName, Pid);
        _ ->
            is_running_ignore
    end.

%% Define this because the ErrorStorePid cannot be registered under a new
%% name. The point is that each error node in a flow sends its errors
%% to a specific error collector called "error_collector_<tabid>" (see
%% ered_nodes:tabid_to_error_collector/1 for details).
%%
%% This allows tests to be run in parallel and errors are separated out
%% by their flow ids
%%
%% The error store is required because the spawn isn't a gen_server, i.e.,
%% I haven't found a way to get the data back from the error collector
%% service ...
start_this_should_not_happen_service(TabId, TestName) ->
    TabErrColl = ered_nodes:tabid_to_error_collector(TabId),

    case whereis(TabErrColl) of
        undefined ->
            error;
        _ ->
            TabErrColl ! stop,
            unregister(TabErrColl)
    end,
    ensure_error_store_is_started(TabErrColl, TestName).

not_happen_loop(TestName, ErrorStorePid) ->
    receive
        stop ->
            ok;
        {it_happened, {NodeId, TabId}, Arg} ->
            Str = io_lib:format("~s in ~s\n", [Arg, TestName]),
            %% io:format(list_to_binary(Str)),
            ErrorStorePid ! {store_msg, {NodeId, TabId, list_to_binary(Str)}},
            not_happen_loop(TestName, ErrorStorePid);
        _ ->
            not_happen_loop(TestName, ErrorStorePid)
    end.

create_test_for_flow_file([], Acc) ->
    Acc;
create_test_for_flow_file([FileName | MoreFileNames], Acc) ->
    Ary = ered_flows:parse_flow_file(FileName),
    {TabId, TestName} = ered_flows:append_tab_name_to_filename(Ary, FileName),

    TestFunc = fun() ->
        ErCo = start_this_should_not_happen_service(
            TabId,
            TestName
        ),
        ered_error_store:reset_errors(TabId),

        %% Websocket name becomes 'eunit_test'. This is picked
        %% up by the nodered module and directs it to send
        %% websocket data to the websocket exchange service
        %% instead. This males assert status and assert debug
        %% nodes work.
        WsName = eunit_test,
        ensure_websocket_listener_is_running(WsName),

        Pids = ered_startup:create_pids_for_nodes(Ary, WsName),

        [
            ered_nodes:trigger_outgoing_messages(
                maps:get(<<"type">>, ND), maps:get(<<"id">>, ND), WsName
            )
         || ND <- Ary
        ],

        %% give the messages time to propagate through the
        %% test flow
        timer:sleep(ered_flows:compute_timeout(Ary)),

        %% stop all nodes. Probably better would be to check
        %% the message queues of the nodes and if all are empty
        %% it's probably safe to end the test case.
        stop_all_pids(Pids),

        %% some asserts work on the stop notification, give'em
        %% time to generate their results.
        timer:sleep(543),
        ErCo ! stop,

        ?assertEqual([], ered_error_store:get_errors(TabId))
    end,

    %% So the timeout value here is 30 seconds. This is the upper limit
    %% that eunit will wait, if the test exits early, then eunit does not
    %% wait for thirty seconds in total. So this could also be a day and
    %% half, it makes no difference.

    %% TODO should really move away from Eunit, it does not support
    %% TODO pending or skipping test cases, so this hack solution.
    case ered_flows:is_test_case_pending(Ary) of
        true ->
            TestCase = {
                list_to_binary(color:yellow(TestName)),
                {timeout, 5, fun() ->
                    ?debugMsg(
                        color:yellow(io_lib:format("PENDING ~s", [TestName]))
                    )
                end}
            };
        false ->
            case ered_flows:ignore_as_eunit_test(Ary) of
                true ->
                    TestCase = {
                        list_to_binary(color:cyan(TestName)),
                        {timeout, 5, fun() ->
                            ?debugMsg(
                                color:cyan(
                                    io_lib:format("IGNORED ~s", [TestName])
                                )
                            )
                        end}
                    };
                false ->
                    TestCase = {
                        list_to_binary(color:yellow(TestName)),
                        {timeout, 30, fun() -> TestFunc() end}
                    }
            end
    end,

    create_test_for_flow_file(
        MoreFileNames,
        [
            TestCase | Acc
        ]
    ).

foreach_testflow_test_() ->
    %% pg is required for the catch nodes
    pg:start_link(),
    ered_config_store:start(),
    ered_csv_parser_store:start(),
    ered_msgtracer_manager:start_link(),
    ered_erlmodule_exchange:start_link(),
    ered_tcp_manager:start_link(),

    {_Cnt, FileNames} = filelib:fold_files(
        io_lib:format("~s/testflows", [code:priv_dir(erlang_red)]),
        "flows.json",
        true,
        fun(Fname, Acc) ->
            {element(1, Acc) + 1, [Fname | element(2, Acc)]}
        end,

        {0, []}
    ),

    TestList = create_test_for_flow_file(FileNames, []),

    %% Tests start failing when all are run in parallel.
    %% No more than 100 tests in parallel - memory saving measure.
    {inparallel, 100, TestList}.
