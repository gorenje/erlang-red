-module(ered_http_flowhub_token).

-behaviour(cowboy_rest).

-export([
    init/2,
    allowed_methods/2,
    content_types_provided/2,
    content_types_accepted/2,
    handle_post_request/2,
    format_error/2
]).

-import(ered_credentials_store, [
    retrieve/1
]).

-import(ered_messages, [
    encode_json/1
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

    SubmitData = json:decode(Body),

    ApiToken =
        case SubmitData of
            #{<<"cfgnode">> := #{<<"apiToken">> := <<"">>, <<"id">> := NodeId}} ->
                case retrieve(NodeId) of
                    #{<<"apiToken">> := <<"empty">>} ->
                        #{<<"token">> => <<"">>};
                    #{<<"apiToken">> := ApiTkn} ->
                        #{<<"token">> => ApiTkn};
                    _ ->
                        #{<<"token">> => <<"">>}
                end;
            #{<<"cfgnode">> := #{<<"apiToken">> := <<"empty">>}} ->
                #{<<"token">> => <<"">>};
            #{<<"cfgnode">> := #{<<"apiToken">> := ApiTkn}} ->
                #{<<"token">> => ApiTkn};
            _ ->
                #{<<"token">> => <<"">>}
        end,

    Resp = cowboy_req:set_resp_body(encode_json(ApiToken), Req2),
    {true, Resp, State}.

format_error(Reason, Req) ->
    {
        [
            {<<"error">>, <<"bad_request">>},
            {<<"reason">>, Reason}
        ],
        Req
    }.
