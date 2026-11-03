-module(ered_http_user_settings).

%%
%% Manage the user settings
%%

-behaviour(cowboy_rest).

-export([
    init/2,
    allowed_methods/2,
    handle_get_response/2,
    handle_post_response/2,
    content_types_provided/2,
    content_types_accepted/2,
    format_error/2
]).

-import(ered_user_settings_store, [
    store/1,
    retrieve/0
]).

init(Req, State) ->
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, handle_get_response}], Req, State}.

content_types_accepted(Req, State) ->
    {
        [{{<<"application">>, <<"json">>, '*'}, handle_post_response}],
        Req,
        State
    }.

handle_get_response(Req, State) ->
    {json:encode(retrieve()), Req, State}.

handle_post_response(Req, State) ->
    {ok, Body, Req2} = ered_http_utils:read_body(Req, <<"">>),

    store(json:decode(Body)),

    Resp = cowboy_req:set_resp_body(<<"{\"rev\":\"feed\"}">>, Req2),
    {true, Resp, State}.

format_error(Reason, Req) ->
    {
        [
            {<<"error">>, <<"bad_request">>},
            {<<"reason">>, Reason}
        ],
        Req
    }.
