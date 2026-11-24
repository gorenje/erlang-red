-module(ered_http_unittesting_status_update_handler).

-behaviour(cowboy_rest).

-export([
    init/2,
    allowed_methods/2,
    content_types_provided/2,
    content_types_accepted/2,
    handle_post_request/2,
    format_error/2
]).

-import(ered_nodered_comm, [
    websocket_name_from_request/1
]).

-import(ered_nodered_comm, [
    node_status_clear/2,
    node_status/5
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
    WsName = websocket_name_from_request(Req),

    {ok, Body, Req2} = ered_http_utils:read_body(Req, <<"">>),

    case cowboy_req:binding(nodeid, Req2, not_set) of
        not_set ->
            ignore;
        NodeId ->
            case Body of
                <<"">> ->
                    node_status_clear(WsName, #{<<"id">> => NodeId});
                <<"{}">> ->
                    node_status_clear(WsName, #{<<"id">> => NodeId});
                _ ->
                    Details = json:decode(Body),
                    node_status(
                        WsName,
                        #{<<"id">> => NodeId},
                        text(Details),
                        colour(Details),
                        shape(Details)
                    )
            end
    end,

    Resp = cowboy_req:set_resp_body(<<"{ \"status\": \"ok\" }">>, Req2),

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
text(#{<<"text">> := T}) -> T;
text(_) -> <<"">>.
colour(#{<<"fill">> := C}) -> C;
colour(_) -> <<"">>.
shape(#{<<"shape">> := S}) -> S;
shape(_) -> <<"">>.
