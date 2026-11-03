-module(ered_http_flowhub_pull).

-behaviour(cowboy_rest).

-export([
    init/2,
    allowed_methods/2,
    content_types_provided/2,
    content_types_accepted/2,
    handle_post_request/2,
    format_error/2
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
    {ok, Body, Req2} = ered_http_utils:read_body(Req, <<"">>),

    TokenData = json:decode(Body),

    {HostName, Token} =
        case TokenData of
            #{<<"token">> := T} ->
                ered_http_utils:flowhub_hostname_from_token(T)
        end,

    {FlowId, Revision} =
        case TokenData of
            #{<<"flowid">> := F, <<"revision">> := R} ->
                {F, R};
            #{<<"flowid">> := F} ->
                {F, ""};
            _ ->
                io:format(
                    "Cannot find flowid & revision in: ~p~n",
                    [TokenData]
                ),
                {unknown, unknown}
        end,

    ResponseBody =
        case
            httpc:request(
                get,
                {
                    list_to_binary(
                        io_lib:format(
                            "~s/v3/flows/~s?v=~s",
                            [
                                HostName,
                                FlowId,
                                uri_string:quote(Revision)
                            ]
                        )
                    ),
                    [
                        {"FlowHub-API-Version", "Redeel"},
                        {"X-FHB-TOKEN", Token}
                    ]
                },
                [{timeout, 25000}, {ssl, [{verify, verify_none}]}],
                []
            )
        of
            {ok, {_StatusLine, _Hdrs, RespBody}} ->
                RespBody;
            Res ->
                io:format("Error catalogue: ~p~n", [Res]),
                <<"{ \"status\": \"error\", \"msg\": \"nope\" }">>
        end,

    Resp = cowboy_req:set_resp_body(ResponseBody, Req2),
    {true, Resp, State}.

format_error(Reason, Req) ->
    {
        [
            {<<"error">>, <<"bad_request">>},
            {<<"reason">>, Reason}
        ],
        Req
    }.
