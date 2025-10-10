-module(ered_http_msgtracer_plugin).

%%
%% Backend for the message tracer plugin. The plugin shows the flow of
%% messages through a flow in live, no need to deploy or reboot the server
%% to get live tracing of messages.
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
    Task = cowboy_req:binding(task, Req),
    TaskState = cowboy_req:binding(state, Req),

    {ok, Body, Req2} = ered_http_utils:read_body(Req, <<"">>),

    %%
    %% Message tracing has two types: debug pr msgtracing - these can both
    %% be active at the same time.
    %%
    %% - `debug` sends the message contents to the debug panel regardless of the
    %%    node type (normally only a debug node goes to the debug panel).
    %%
    %% - `msgtracing` has a list of nodes that received messages and each
    %%    node that has received a message, has its status updated so that it
    %%    beecomes clear in the flow which nodes got messages.
    %%
    %% Both then have the options of either all nodes or a selected list of
    %% nodes for which debug or msgtracing should be applied.
    %%

    TaskData = json:decode(Body),

    {WsName, AllIsOn, Nodes} =
        case TaskData of
            #{
                <<"wsname">> := A,
                <<"allIsOn">> := B,
                <<"nodesSelected">> := C
            } ->
                {A, B, C};
            #{<<"wsname">> := A, <<"nodesSelected">> := C} ->
                {A, false, C};
            #{<<"wsname">> := A, <<"allIsOn">> := B} ->
                {A, B, []};
            #{<<"wsname">> := A} ->
                {A, false, []}
        end,

    %% if this is 'on' then we readd these, of this is 'off' and then
    %% we do nothing else but either way, we remove the handlers first.
    case Task of
        <<"msgtracing">> ->
            ered_msgtracer_manager:remove_handler({
                ered_msgtracer_handler_msgtracing,
                WsName
            }),
            ered_msgtracer_manager:remove_handler({
                ered_msgtracer_handler_msgtracing_all,
                WsName
            });
        <<"debug">> ->
            ered_msgtracer_manager:remove_handler({
                ered_msgtracer_handler_debug_all,
                WsName
            }),
            ered_msgtracer_manager:remove_handler({
                ered_msgtracer_handler_debug,
                WsName
            })
    end,

    case {Task, TaskState, AllIsOn} of
        {<<"debug">>, <<"on">>, true} ->
            ered_msgtracer_manager:add_handler(
                {
                    ered_msgtracer_handler_debug_all,
                    WsName
                },
                #{'_ws' => binary_to_atom(WsName)}
            );
        {<<"debug">>, <<"on">>, false} ->
            ered_msgtracer_manager:add_handler(
                {
                    ered_msgtracer_handler_debug,
                    WsName
                },
                #{
                    <<"nodeids">> => Nodes,
                    '_ws' => binary_to_atom(WsName)
                }
            );
        %%
        %%
        {<<"msgtracing">>, <<"on">>, true} ->
            ered_msgtracer_manager:add_handler(
                {
                    ered_msgtracer_handler_msgtracing_all,
                    WsName
                },
                #{'_ws' => binary_to_atom(WsName)}
            );
        {<<"msgtracing">>, <<"on">>, false} ->
            ered_msgtracer_manager:add_handler(
                {
                    ered_msgtracer_handler_msgtracing,
                    WsName
                },
                #{
                    <<"nodeids">> => Nodes,
                    '_ws' => binary_to_atom(WsName)
                }
            );
        _ ->
            ignore
    end,

    Resp = cowboy_req:set_resp_body(<<"OK">>, Req2),
    {true, Resp, State}.

format_error(Reason, Req) ->
    {
        [
            {<<"error">>, <<"bad_request">>},
            {<<"reason">>, Reason}
        ],
        Req
    }.
