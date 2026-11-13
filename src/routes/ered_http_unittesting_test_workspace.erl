-module(ered_http_unittesting_test_workspace).

-behaviour(cowboy_rest).

-export([
    init/2,
    allowed_methods/2,
    content_types_provided/2,
    content_types_accepted/2,
    handle_post_request/2,
    format_error/2
]).

-import(ered_nodered_comm, [
    websocket_name_from_request/1
]).

-import(ered_flowhub_async, [
    push_flow/2
]).

init(Req, State) ->
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    {[<<"POST">>], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, handle_post_request}], Req, State}.

content_types_accepted(Req, State) ->
    {
        [{{<<"application">>, <<"json">>, '*'}, handle_post_request}],
        Req,
        State
    }.

handle_post_request(Req, State) ->
    WsName = websocket_name_from_request(Req),

    {ok, Body, Req2} = ered_http_utils:read_body(Req, <<"">>),

    #{<<"flowdata">> := FlowData} = json:decode(Body),

    case cowboy_req:binding(flowid, Req2, not_set) of
        not_set ->
            ignore;
        FlowId ->
            ered_unittest_engine !
                {start_workspace_test, FlowId, WsName, FlowData}
    end,

    Resp = cowboy_req:set_resp_body(<<"{ \"status\": \"ok\" }">>, Req2),

    {true, Resp, State}.

format_error(Reason, Req) ->
    {
        [
            {<<"error">>, <<"bad_request">>},
            {<<"reason">>, Reason}
        ],
        Req
    }.
