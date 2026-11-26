-module(ered_http_flowhub_token_update).

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
    retrieve_all/0,
    store/2
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
    {ok, Body, Req2} = ered_http_utils:read_body(Req),

    case json_decode(Body) of
        #{<<"token">> := ApiToken} ->
            [
                store_new_token(C, ApiToken)
             || C <- maps:to_list(ered_credentials_store:retrieve_all())
            ];
        _ ->
            ignore
    end,

    Resp = cowboy_req:set_resp_body("{\"status\":\"ok\"}", Req2),
    {true, Resp, State}.

format_error(Reason, Req) ->
    {
        [
            {<<"error">>, <<"bad_request">>},
            {<<"reason">>, Reason}
        ],
        Req
    }.

%%
%% Helpers
%%
store_new_token({NodeId, #{<<"apiToken">> := _OldToken} = Creds}, NewToken) ->
    store(NodeId, Creds#{<<"apiToken">> => NewToken});
store_new_token(_, _) ->
    ignore.

%%
json_decode(<<"">>) ->
    #{};
json_decode(Body) ->
    json:decode(Body).
