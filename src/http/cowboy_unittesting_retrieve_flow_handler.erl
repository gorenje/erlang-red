-module(cowboy_unittesting_retrieve_flow_handler).

-behaviour(cowboy_rest).

-export([init/2,
         allowed_methods/2,
         handle_response/2,
         content_types_provided/2,
         format_error/2]).

init(Req, State) ->
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    {ok,CurrMeth} = maps:find(method,Req),
    {[CurrMeth], Req, State}.

content_types_provided(Req,State) ->
    { [{{ <<"application">>, <<"json">>, '*'}, handle_response}], Req, State }.

handle_response(Req, State) ->
    case cowboy_req:binding(flowid, Req) of
        undefined ->
            {<<"[]">>, Req, State };

        FlowId ->
            FileName = flow_store_server:get_filename(FlowId),
            {ok, FileData} = file:read_file(FileName),
            {jiffy:encode(#{ flowdata => jiffy:decode(FileData) }), Req, State }

    end.

format_error(Reason, Req) ->
    {[
        {<<"error">>, <<"bad_request">>},
        {<<"reason">>, Reason}
    ], Req}.
