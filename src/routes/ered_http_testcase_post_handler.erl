-module(ered_http_testcase_post_handler).

%%
%% This stores testcases to disk. Triggered by "create test case" button
%% on the export flow dialog.
%%

-behaviour(cowboy_rest).

-export([
    init/2,
    allowed_methods/2,
    content_types_accepted/2,
    handle_json_body/2,
    format_error/2
]).

init(Req, State) ->
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    {ok, CurrMeth} = maps:find(method, Req),
    {[CurrMeth], Req, State}.

content_types_accepted(Req, State) ->
    ContentType = cowboy_req:header(<<"content-type">>, Req),
    {[{ContentType, handle_json_body}], Req, State}.

handle_json_body(Req, State) ->
    WorkspaceId = cowboy_req:binding(workspaceid, Req),

    {ok, Body, Req2} = ered_http_utils:read_body(Req, <<"">>),

    %%
    %% The relationship to workspace id and flow id is one-to-one, they
    %% are one and the same.
    %%
    %% Also do this off-process since I want the store to fail and be
    %% recovered and not this handler. Of course, the file might not be
    %% created but the user things differently - but that's not important
    %% just yet (because this codebase will be hosted on a read-only server
    %% and should just be able to execute the tests - for the time being).

    %% Don't store the testcases any longer, testing is done differently
    %% now - using the testcase git repository directly.

    %% ered_flow_store_server ! {store_flow, WorkspaceId, Body},

    %% FileName = io_lib:format("flow.~s.json", [WorkspaceId]),

    %% Resp = cowboy_req:set_resp_body(
    %%     json:encode(#{name => list_to_binary(lists:flatten(FileName))}),
    %%     Req2
    %% ),

    {true, #{<<"status">> => <<"ok">>}, State}.

format_error(Reason, Req) ->
    {
        [
            {<<"error">>, <<"bad_request">>},
            {<<"reason">>, Reason}
        ],
        Req
    }.
