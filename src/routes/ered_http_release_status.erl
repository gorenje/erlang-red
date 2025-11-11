-module(ered_http_release_status).

%% This shows a status page with the current release
%% and associated running applications.
%% It also has a link back to the running application

-behaviour(cowboy_rest).

-export([
    init/2,
    allowed_methods/2,
    handle_get_response/2,
    content_types_provided/2,
    format_error/2
]).

init(Req, State) ->
    erlydtl:compile(
        code:priv_dir(erlang_red) ++ "/wrapper_site/templates/status.dtl",
        status_tmpl,
        [
            {out_dir, false}
        ]
    ),
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"text">>, <<"html">>, '*'}, handle_get_response}], Req, State}.

handle_get_response(Req, State) ->
    %% This is pretty inefficient with the constant char list
    %% concatenations.  As a mere status page it doesn't seem
    %% worth complicating.
    Status =
        try
            case release_handler:which_releases() of
                %% This should actually only be one for now
                %% But we'll take the first if we messed up
                [{Name, Vsn, Apps, RelStat} | _] ->
                    [
                        {name, Name},
                        {version, Vsn},
                        {apps, lists:sort(Apps)},
                        {status, RelStat}
                    ];
                _ ->
                    []
            end
        catch
            _E:_F:_S ->
                []
        end,

    case status_tmpl:render(Status) of
        {ok, Res} -> {Res, Req, State};
        {error, Err} -> {format_error(Err, Req), Req, State}
    end.

format_error(Reason, Req) ->
    {
        [
            {<<"error">>, <<"bad_request">>},
            {<<"reason">>, Reason}
        ],
        Req
    }.
