-module(ered_http_binary_node).

-behaviour(cowboy_rest).

-export([
    init/2,
    allowed_methods/2,
    content_types_accepted/2,
    content_types_provided/2,
    handle_binary_request/2,
    format_error/2
]).

-import(ered_messages, [
    any_to_list/1,
    encode_json/1
]).

init(Req, State) ->
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    {[<<"POST">>], Req, State}.

%erlfmt:ignore - alignment
content_types_accepted(Req, State) ->
    {
        [
            {<<"application/json">>,                handle_binary_request},
            {<<"application/json; charset=utf-8">>, handle_binary_request},
            {<<"application/x-json-restart">>,      handle_binary_request}
        ],
        Req,
        State
    }.

content_types_provided(Req, State) ->
    {
        [
            {{<<"application">>, <<"json">>, '*'}, handle_binary_request}
        ],
        Req,
        State
    }.

handle_binary_request(Req, State) ->
    {ok, Body, _Req2} = ered_http_utils:read_body(Req, <<"">>),

    #{<<"pattern">> := Pattern} = json:decode(Body),

    FuncCode =
        case erl_packetparser:packetdef_to_erlang(any_to_list(Pattern)) of
            {ok, ErlangCode} ->
                ErlangCode;
            {error, ErrMsg} ->
                ErrMsg
        end,

    Content = #{<<"binary">> => FuncCode},
    Resp = cowboy_req:set_resp_body(encode_json(Content), Req),
    {true, Resp, State}.

format_error(Reason, Req) ->
    {
        [
            {<<"error">>, <<"bad_request">>},
            {<<"reason">>, Reason}
        ],
        Req
    }.
