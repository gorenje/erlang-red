-module(ered_http_flowhub_diff_frame).

%%
%% Backend for the processes sidebar
%%

-behaviour(cowboy_rest).

-export([
    init/2,
    allowed_methods/2,
    handle_get_response/2,
    content_types_provided/2,
    format_error/2
]).

-import(ered_messages, [
    encode_json/1
]).

init(Req, State) ->
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"text">>, <<"html">>, '*'}, handle_get_response}], Req, State}.

handle_get_response(Req, State) ->
    FlowId = cowboy_req:binding(flowid, Req),

    {HostName, Token} =
        case lists:keyfind(<<"t">>, 1, cowboy_req:parse_qs(Req)) of
            {_, Tkn} ->
                ered_http_utils:flowhub_hostname_from_token(Tkn);
            _ ->
                {<<"https://api.flowhub.org">>, <<"">>}
        end,

    Response =
        case
            httpc:request(
                get,
                {
                    list_to_binary(
                        io_lib:format(
                            "~s/s/~s?format=json&t=~s",
                            [
                                HostName,
                                FlowId,
                                uri_string:quote(Token)
                            ]
                        )
                    ),
                    [
                        {"X-FHB-TOKEN", Token}
                    ]
                },
                [{timeout, 25000}, {ssl, [{verify, verify_none}]}],
                []
            )
        of
            {ok, {_StatusLine, _Headers, RespBody}} ->
                RespBody;
            Res ->
                io:format("Error catalogue: ~p~n", [Res]),
                <<"{ \"status\": \"error\", \"msg\": \"nope\" }">>
        end,

    {Response, Req, State}.

format_error(Reason, Req) ->
    {
        [
            {<<"error">>, <<"bad_request">>},
            {<<"reason">>, Reason}
        ],
        Req
    }.
