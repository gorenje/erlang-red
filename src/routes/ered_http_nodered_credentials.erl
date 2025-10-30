-module(ered_http_nodered_credentials).

-export([
    init/2,
    allowed_methods/2,
    handle_get_response/2,
    content_types_provided/2,
    format_error/2
]).

-import(ered_messages, [
    encode_json/1
]).

-import(ered_nodered_comm, [
    websocket_name_from_request/1
]).

-import(ered_config_store, [
    retrieve_config_node/2
]).

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
            {WsName, NodeType, NodeId} ->
                case retrieve_config_node(NodeId, WsName) of
                    {ok, Cfg} ->
                        response_for_cfgtype(NodeType, Cfg);
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

%%
%% ---------------- helpers
%%
%% Repond with a has_password flag but don't send the password over the wire.
%% This is what this API endpoint does: prevent the sending of passwords over
%% wires - even bard wires.
response_for_cfgtype(
    <<"mqtt-broker">>,
    #{<<"credentials">> := #{<<"user">> := User, <<"password">> := <<>>}}
) ->
    #{<<"user">> => User, <<"has_password">> => false};
response_for_cfgtype(
    <<"mqtt-broker">>,
    #{<<"credentials">> := #{<<"user">> := User, <<"password">> := _P}}
) ->
    #{<<"user">> => User, <<"has_password">> => true};
response_for_cfgtype(
    <<"mqtt-broker">>,
    #{<<"credentials">> := #{<<"user">> := User}}
) ->
    #{<<"user">> => User, <<"has_password">> => false};
%%
%% amqp broker usres "username", mqtt broker uses "user".
response_for_cfgtype(
    <<"amqp-broker">>,
    #{<<"credentials">> := #{<<"username">> := User, <<"password">> := <<>>}}
) ->
    #{<<"username">> => User, <<"has_password">> => false};
response_for_cfgtype(
    <<"amqp-broker">>,
    #{<<"credentials">> := #{<<"username">> := User, <<"password">> := _P}}
) ->
    #{<<"username">> => User, <<"has_password">> => true};
response_for_cfgtype(
    <<"amqp-broker">>,
    #{<<"credentials">> := #{<<"username">> := User}}
) ->
    #{<<"username">> => User, <<"has_password">> => false};
%%
%% Fall through and warn.
response_for_cfgtype(
    CfgType,
    Cfg
) ->
    io:format(
        "Warning: Empty credentials for unknown nodetype: ~p with ~p~n",
        [CfgType, Cfg]
    ),
    #{}.
