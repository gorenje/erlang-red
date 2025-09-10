-module(ered_http_unittesting_runtests_get_handler).

-behaviour(cowboy_rest).

-export([
    init/2,
    allowed_methods/2,
    handle_response/2,
    content_types_provided/2,
    format_error/2
]).

-import(ered_nodered_comm, [
    websocket_name_from_request/1
]).

init(Req, State) ->
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    {ok, CurrMeth} = maps:find(method, Req),
    {[CurrMeth], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, handle_response}], Req, State}.

handle_response(Req, State) ->
    WsName = websocket_name_from_request(Req),
    Query = cowboy_req:parse_qs(Req),

    AlsoTestPendingTests =
        case lists:keyfind(<<"testpend">>, 1, Query) of
            {<<"testpend">>, <<"true">>} ->
                true;
            _ ->
                false
        end,

    case cowboy_req:binding(flowid, Req) of
        undefined ->
            {<<"{}">>, Req, State};
        <<"all">> ->
            %% stop any other running processes, these can cause issues
            %% with overlapping services.
            ered_compute_engine:stop(WsName),
            %% close any dangling tcp listeners
            ered_tcp_manager ! stop,

            AllFlowIds = ered_flow_store_server:all_flow_ids(),

            timer:apply_after(500, fun() ->
                trigger_tests_in_groups_of(
                    AllFlowIds,
                    WsName,
                    AlsoTestPendingTests,
                    50
                )
            end),

            {
                json:encode(#{status => ok, todo => length(AllFlowIds)}),
                Req,
                State
            };
        FlowId ->
            ered_unittest_engine !
                {start_test_with_timeout, FlowId, WsName, AlsoTestPendingTests,
                    2222},
            {json:encode(#{status => ok, todo => 1}), Req, State}
    end.

format_error(Reason, Req) ->
    {
        [
            {<<"error">>, <<"bad_request">>},
            {<<"reason">>, Reason}
        ],
        Req
    }.

%%
%% ---------------------- helpers
%%
trigger_tests_in_groups_of(AllFlowIds, WsName, TstPdn, GroupSize) ->
    trigger_tests_in_groups_of(
        AllFlowIds, WsName, TstPdn, GroupSize, GroupSize
    ).

trigger_tests_in_groups_of([], _WsName, _TstPdn, _GroupSize, _Cnt) ->
    done;
trigger_tests_in_groups_of(FlowIds, WsName, TstPdn, GroupSize, 0) ->
    timer:sleep(5000),
    trigger_tests_in_groups_of(FlowIds, WsName, TstPdn, GroupSize, GroupSize);
trigger_tests_in_groups_of(
    [FlowId | Rest], WsName, AlsoTestPendingTests, GroupSize, Cnt
) ->
    ered_unittest_engine ! {start_test, FlowId, WsName, AlsoTestPendingTests},
    trigger_tests_in_groups_of(
        Rest,
        WsName,
        AlsoTestPendingTests,
        GroupSize,
        Cnt - 1
    ).
