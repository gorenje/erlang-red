-module(ered_http_nodered_credentials).

-export([
    init/2,
    allowed_methods/2,
    handle_get_response/2,
    content_types_provided/2,
    format_error/2
]).

%%
%% This endpoint is used by Node-RED to retrieve the "sensitive" crendentials
%% and ensure that these are defined. Things such as passwords or pass keys.
%%
%% This api removes passwords and instead just informs the frontend that a
%% password has been sent. The password is stored in the config store
%% and the credentials store and will be persisted in the credentials store
%% while being removed from the flows.json file if that gets stored.
%%

-import(ered_messages, [
    encode_json/1
]).

-import(ered_nodered_comm, [
    websocket_name_from_request/1
]).

-import(ered_config_store, [
    retrieve_config_node/2
]).

-define(RemovePassword(Cfg, St), begin
    maps:remove(<<"password">>, Cfg)
end#{
    <<"has_password">> => St
}).

init(Req, State) ->
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

content_types_provided(Req, State) ->
    {
        [
            {<<"application/json">>, handle_get_response}
        ],
        Req,
        State
    }.

handle_get_response(Req, State) ->
    Resp =
        case
            {
                websocket_name_from_request(Req),
                cowboy_req:binding(nodetype, Req),
                cowboy_req:binding(nodeid, Req)
            }
        of
            {_WsName, undefined, _} ->
                #{};
            {_WsName, _, undefined} ->
                #{};
            {WsName, _NodeType, NodeId} ->
                case ered_credentials_store:retrieve(NodeId, WsName) of
                    #{<<"password">> := <<>>} = Cfg ->
                        ?RemovePassword(Cfg, false);
                    #{<<"password">> := _P} = Cfg ->
                        ?RemovePassword(Cfg, true);
                    Cfg when is_map(Cfg) ->
                        ?RemovePassword(Cfg, false);
                    _ ->
                        #{}
                end
        end,

    {encode_json(Resp), Req, State}.

format_error(Reason, Req) ->
    {
        [
            {<<"error">>, <<"bad_request">>},
            {<<"reason">>, Reason}
        ],
        Req
    }.
