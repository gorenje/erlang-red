-module(ered_node_http_request).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Node is responsible for making external http requests and feeding the
%% results into the flow.
%%
-import(ered_nodes, [
    jstr/1,
    jstr/2,
    send_msg_to_connected_nodes/2
]).

-import(ered_nodered_comm, [
    send_out_debug_msg/4,
    post_exception_or_debug/3,
    unsupported/3
]).

%%
%%
start(
    #{
        <<"headers">> := [],
        <<"method">> := <<"use">>
    } = NodeDef,
    _WsName
) ->
    ered_node:start(NodeDef, ?MODULE);
start(
    #{
        <<"headers">> := [],
        <<"method">> := <<"GET">>,
        <<"paytoqs">> := <<"ignore">>
    } = NodeDef,
    _WsName
) ->
    ered_node:start(NodeDef, ?MODULE);
start(
    #{
        <<"headers">> := [],
        <<"method">> := <<"POST">>
    } = NodeDef,
    _WsName
) ->
    ered_node:start(NodeDef, ?MODULE);
start(NodeDef, WsName) ->
    unsupported(
        NodeDef,
        {websocket, WsName},
        "header definitions, payload as querystring not " ++
            "supported. Only POST and GET supported."
    ),
    ered_node:start(NodeDef, ered_node_ignore).

%%
%%
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg({incoming, Msg}, #{<<"method">> := NodeMeth} = NodeDef) ->
    unsupported_headers_warnings(NodeDef, Msg),

    Url = get_url(NodeDef, Msg),
    Method =
        case NodeMeth of
            <<"use">> ->
                maps:get(<<"method">>, Msg, []);
            _ ->
                NodeMeth
        end,

    case {Method, Url} of
        {[], []} ->
            post_exception_or_debug(NodeDef, Msg, <<"url and method not set">>),
            {handled, NodeDef, Msg};
        {[], _} ->
            post_exception_or_debug(NodeDef, Msg, <<"method not set">>),
            {handled, NodeDef, Msg};
        {_, []} ->
            post_exception_or_debug(NodeDef, Msg, <<"url not set">>),
            {handled, NodeDef, Msg};
        _ ->
            case perform_request(Method, Url, NodeDef, Msg) of
                {ok, {{_Protocol, StatusCode, _ReasonPhrase}, Headers, Body}} ->
                    Msg2 = Msg#{
                        ?AddPayload(jstr(Body)),
                        <<"statusCode">> => StatusCode,
                        <<"headers">> => headers_to_map(Headers)
                    },
                    send_msg_to_connected_nodes(NodeDef, Msg2),
                    {handled, NodeDef, Msg2};
                {error, Reason} ->
                    ErrMsg = jstr("Http request failed: ~p", [Reason]),
                    post_exception_or_debug(NodeDef, Msg, ErrMsg),
                    {handled, NodeDef, Msg}
            end
    end;
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% -------------- helpers
%%
get_url(#{<<"url">> := Url}, _) when Url =/= <<>>, Url =/= "" ->
    Url;
get_url(NodeDef, Msg) ->
    get_url(Msg, ignored);
get_url(_, _) ->
    [].

headers_to_map(Headers) ->
    %% convert keys to binary and then the header list to a map
    maps:from_list([
        {list_to_binary(K), list_to_binary(V)}
     || {K, V} <- Headers
    ]).

unsupported_headers_warnings(NodeDef, Msg) ->
    case
        {
            maps:find(<<"headers">>, NodeDef),
            maps:find(<<"headers">>, Msg)
        }
    of
        {{ok, []}, {ok, []}} ->
            ok;
        {{ok, []}, error} ->
            ok;
        {{ok, []}, {ok, _T}} ->
            unsupported(NodeDef, Msg, "message: headers unsupported");
        {{ok, _S}, {ok, []}} ->
            unsupported(NodeDef, Msg, "node definition: headers unsupported");
        {{ok, _S}, error} ->
            unsupported(NodeDef, Msg, "node definition: headers unsupported");
        {{ok, _S}, {ok, _T}} ->
            unsupported(NodeDef, Msg, "node definition: headers unsupported"),
            unsupported(NodeDef, Msg, "message: headers unsupported")
    end.

mth_to_atom(Method) when is_binary(Method) ->
    binary_to_atom(string:lowercase(Method)).

perform_request(<<"POST">> = Method, Url, _NodeDef, #{?GetWsName} = Msg) ->
    case maps:find(<<"payload">>, Msg) of
        {ok, Payload} ->
            httpc:request(
                mth_to_atom(Method),
                {Url,
                    [
                        {"Cookie", io_lib:format("wsname=~s", [WsName])}
                    ],
                    "application/json", Payload},
                [],
                []
            );
        _ ->
            httpc:request(
                mth_to_atom(Method),
                {Url,
                    [
                        {"Cookie", io_lib:format("wsname=~s", [WsName])}
                    ],
                    "application/json", ""},
                [],
                []
            )
    end;
perform_request(<<"GET">> = Method, Url, _NodeDef, #{?GetWsName} = _Msg) ->
    httpc:request(
        mth_to_atom(Method),
        {Url, [
            {"Cookie", io_lib:format("wsname=~s", [WsName])}
        ]},
        [],
        []
    );
perform_request(_Method, _Url, NodeDef, Msg) ->
    unsupported(NodeDef, Msg, "unsupported method"),
    {error, unsupported_method}.
