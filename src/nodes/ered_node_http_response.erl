-module(ered_node_http_response).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Node to be used in conjunction with the http in node, This nodes sends
%% a response to a http connection.
%%

-import(ered_nodes, [
    jstr/2
]).
-import(ered_nodered_comm, [
    unsupported/3
]).
-import(ered_messages, [
    convert_to_num/1,
    encode_json/1,
    map_keys_to_binary/1
]).

%%
%%
start(NodeDef, _WsName) ->
    ered_node:start(NodeDef, ?MODULE).

%%
%%
handle_event(_, NodeDef) ->
    NodeDef.

%%
%% This sends a message to the ered_http_node_http_in_handler telling it
%% to send the payload to the client.
handle_msg(
    {incoming, #{?GetWsName, ?GetPayload, <<"reqpid">> := ReqPid} = Msg},
    NodeDef
) when is_list(Payload); is_binary(Payload) ->
    StatusCode = retrieve_status_code(NodeDef, Msg),
    Headers = retrieve_headers(NodeDef, Msg),
    ReqPid ! {reply, StatusCode, Headers, WsName, Payload},

    {handled, NodeDef, Msg};
handle_msg(
    {incoming, #{?GetWsName, ?GetPayload, <<"reqpid">> := ReqPid} = Msg},
    NodeDef
) when is_map(Payload) ->
    StatusCode = retrieve_status_code(NodeDef, Msg),
    Headers = retrieve_headers(NodeDef, Msg),
    ReqPid ! {reply, StatusCode, Headers, WsName, encode_json(Payload)},

    {handled, NodeDef, Msg};
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% Retrieve statusCode either from Msg or from NodeDef, NodeDef has preference.
%% erlfmt:ignore alignment
retrieve_status_code(NodeDef, Msg) ->
    case {maps:find(<<"statusCode">>, Msg),
          maps:find(<<"statusCode">>, NodeDef)} of
        {{ok, MsgSC}, {ok, <<>>}} -> convert_to_num(MsgSC);
        {{ok, _},     {ok, NdSC}} -> convert_to_num(NdSC);
        {{ok, MsgSC}, _}          -> convert_to_num(MsgSC);
        {_, {ok, <<>>}}           -> 200;
        {_, {ok, NdSC}}           -> convert_to_num(NdSC);
        {_, _}                    -> 200
    end.

%%
%% Retrieve headers from either the NodeDef or Msg, NodeDef has preference.
%% erlfmt:ignore alignment
retrieve_headers(NodeDef, Msg) ->
    Hdrs =
        case {maps:find(<<"headers">>, Msg),
              maps:find(<<"headers">>, NodeDef)} of
            {{ok, MsgHdrs}, {ok, #{}}}    -> MsgHdrs;
            {{ok, _},       {ok, NdHdrs}} -> NdHdrs;
            {_,             {ok, NdHdrs}} -> NdHdrs;
            {{ok, MsgHdrs}, _}            -> MsgHdrs;
            {_, _}                        -> #{}
        end,
    %% This might well be removed in the future, header shouldn't be set.
    Hdrs2 = Hdrs#{<<"x-resp-url">> => response_url(Msg)},
    map_keys_to_binary(Hdrs2).

%%
%% ResponseUrl is set in Node-RED when the original request followed a
%% redirect. It's the new URL and sent back to the client. This value is
%% needed for a test ahd is here. Normally the httpe response (this node)
%% would not set this header value.
response_url(#{<<"req">> := #{<<"uri">> := Uri}}) ->
    Uri;
response_url(_) ->
    <<"">>.
