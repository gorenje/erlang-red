-module(ered_http_nodered_empty_json).

%%
%% This returns an empty hash. This is used for returning the
%% credentials for a flow tab. Double click on a flow tab and
%% this request is set.
%%
%% Also used for the contexts - that are forever empty.
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
    case maps:find(path, Req) of
        {ok, <<"/library/examples/flows/">>} ->
            {<<"[]">>, Req, State};
        {ok, <<"/library/local/flows/">>} ->
            {<<"[]">>, Req, State};
        _ ->
            {<<"{}">>, Req, State}
    end.

handle_post_response(Req, State) ->
    Resp = cowboy_req:set_resp_body(<<"{\"rev\":\"feed\"}">>, Req),
    {true, Resp, State}.

format_error(Reason, Req) ->
    {
        [
            {<<"error">>, <<"bad_request">>},
            {<<"reason">>, Reason}
        ],
        Req
    }.
