-module(ered_nodered_comm).

-include("ered_nodes.hrl").

%%
%% Module for sending various websocket messages to Node-RED frontend
%%
%% Its the module that represents the encapsulates the communication between
%% nodes in Erlang and their representation in the flow editor.
%%
-export([
    assert_failure/3,
    debug/3,
    debug_string/2,
    debug_string/3,
    get_websocket_name/0,
    node_status_after/6,
    node_status_clear_after/3,
    node_status_clear/2,
    node_status/5,
    post_exception_or_debug/3,
    send_on_if_ws/2,
    send_out_debug_msg/4,
    send_out_debug_error/2,
    send_out_debug_warning/2,
    send_to_debug_sidebar/2,
    unittest_result/3,
    unsupported/3,
    websocket_name_from_request/1,
    ws_from/1
]).

-import(ered_messages, [
    jsonata_eval_or_error_msg/2,
    retrieve_prop_value/2
]).

-import(ered_nodes, [
    generate_id/0,
    generate_id/1,
    jstr/1,
    jstr/2,
    this_should_not_happen/2
]).

-import(ered_message_exchange, [
    post_exception/3
]).

send_on_if_ws(none, Msg) ->
    io:format("WARNING[nodered](none): not sending ~p~n", [Msg]);
send_on_if_ws(WsName, Msg) ->
    case whereis(WsName) of
        undefined ->
            io:format("WARNING[nodered](Wsname): not sending ~p ~p~n", [
                WsName, Msg
            ]);
        _ ->
            WsName ! Msg
    end.

%%
%% clear a previous node status value.
node_status_clear(WsName, #{<<"id">> := NodeId}) ->
    send_on_if_ws(WsName, {status, NodeId, clear}).

node_status(WsName, NodeDef, Txt, Clr, Shp) when is_integer(Txt) ->
    TxtStr = io_lib:format("~p", [Txt]),
    node_status(WsName, NodeDef, TxtStr, Clr, Shp);
node_status(WsName, #{<<"id">> := NodeId}, Txt, Clr, Shp) ->
    send_on_if_ws(WsName, {status, NodeId, Txt, Clr, Shp}).

node_status_after(TimeMillSec, WsName, NodeDef, Txt, Clr, Shp) ->
    timer:apply_after(
        TimeMillSec,
        fun() -> node_status(WsName, NodeDef, Txt, Clr, Shp) end
    ).

node_status_clear_after(TimeMillSec, WsName, #{<<"id">> := NodeId}) ->
    timer:apply_after(
        TimeMillSec,
        fun() -> send_on_if_ws(WsName, {status, NodeId, clear}) end
    ).

debug(WsName, Data, error) ->
    send_on_if_ws(WsName, {debug, Data, error});
debug(WsName, Data, warning) ->
    send_on_if_ws(WsName, {debug, Data, warning});
debug(WsName, Data, notice) ->
    send_on_if_ws(WsName, {debug, Data, notice});
debug(WsName, Data, normal) ->
    send_on_if_ws(WsName, {debug, Data, normal}).

unittest_result(WsName, FlowId, failed) ->
    send_on_if_ws(WsName, {unittest_results, FlowId, <<"failed">>});
unittest_result(WsName, FlowId, pending) ->
    send_on_if_ws(WsName, {unittest_results, FlowId, <<"pending">>});
unittest_result(WsName, FlowId, unknown_testcase) ->
    send_on_if_ws(WsName, {unittest_results, FlowId, <<"unknown_testcase">>});
unittest_result(WsName, FlowId, success) ->
    send_on_if_ws(WsName, {unittest_results, FlowId, <<"success">>}).

%%
%% Unsupported features are highlighted in the flow editor frontend. It makes
%% no sense to fail a unit test if this is hit. It's a gentle reminder that
%% Erlang-RED isn't feature complete.
%%
%% erlfmt:ignore lined up and to attention
unsupported(NodeDef, {websocket, WsName}, ErrMsg) ->
    unsupported(NodeDef, #{'_ws' => WsName}, ErrMsg);
unsupported(NodeDef, Msg, ErrMsg) ->
    Data = ?ObtainFrom(NodeDef)#{
      <<"msg">> => list_to_binary(
                     io_lib:format(
                       "Unsupported Feature:~n~n~s~n~nNodeDef: ~p ~n~nMsg: ~p",
                       [ErrMsg, NodeDef, Msg])
                    ),
      <<"format">> => <<"string">>
     },

    debug(ws_from(Msg), Data, notice).

%% erlfmt:ignore lined up and to attention
send_out_debug_msg(NodeDef, Msg, ErrMsg, DebugType) ->
    Data = ?ObtainFrom(NodeDef)#{
      <<"msg">>    => ErrMsg,
      <<"format">> => <<"string">>
     },

    debug(ws_from(Msg), Data, DebugType).

%% erlfmt:ignore lined up and to attention
send_out_debug_error(NodeDef, Msg) ->
    Data = ?ObtainFrom(NodeDef)#{
      <<"msg">>    => Msg,
      <<"format">> => <<"object">>
     },

    debug(ws_from(Msg), Data, error).

send_out_debug_warning(NodeDef, Msg) ->
    Data = ?ObtainFrom(NodeDef)#{
        <<"msg">> => Msg,
        <<"format">> => <<"object">>
    },

    debug(ws_from(Msg), Data, warning).

%%
%%
send_to_debug_sidebar(
    #{
        <<"targetType">> := <<"jsonata">>,
        <<"complete">> := Jsonata
    } = NodeDef,
    Msg
) ->
    %% format is important here.
    %% Triggery for large files and I don't know what. Using format
    %% of "object" as opposed to "Object" (capital-o) causes less
    %% breakage. Definitely something to investigate.
    %% See info for test id: c4690c0a085d6ef5 for more details.
    Result = jsonata_eval_or_error_msg(Jsonata, Msg),

    Data = ?ObtainFrom(NodeDef)#{
        <<"topic">> => ?TopicFrom(Msg),
        <<"msg">> => Result,
        <<"format">> => type_to_node_red_debug_type(Result)
    },

    debug(ws_from(Msg), Data, normal);
send_to_debug_sidebar(
    #{
        <<"targetType">> := <<"msg">>,
        <<"complete">> := PropName
    } = NodeDef,
    Msg
) ->
    PropValue = retrieve_prop_value(PropName, Msg),
    Data = ?ObtainFrom(NodeDef)#{
        <<"topic">> => ?TopicFrom(Msg),
        <<"msg">> => PropValue,
        <<"format">> => type_to_node_red_debug_type(PropValue),
        <<"property">> => PropName
    },

    debug(ws_from(Msg), Data, normal);
send_to_debug_sidebar(NodeDef, Msg) ->
    %% format is important here.
    %% Triggery for large files and I don't know what. Using format
    %% of "object" as opposed to "Object" (capital-o) causes less
    %% breakage. Definitely something to investigate.
    %% See info for test id: c4690c0a085d6ef5 for more details.
    Data = ?ObtainFrom(NodeDef)#{
        <<"topic">> => ?TopicFrom(Msg),
        <<"msg">> => Msg,
        <<"format">> => <<"object">>
    },

    debug(ws_from(Msg), Data, normal).

%%
%%
get_websocket_name() ->
    binary_to_atom(
        list_to_binary(io_lib:format("ws~s", [generate_id(6)]))
    ).

%%
%% Obtain the WsName from the HTTP Req or empty atom
websocket_name_from_request(Req) ->
    Cookies = cowboy_req:parse_cookies(Req),

    case lists:keyfind(<<"wsname">>, 1, Cookies) of
        {<<"wsname">>, WsName} ->
            binary_to_atom(WsName);
        _ ->
            none
    end.

%%
%% Retrieve the websocket name from the Msg map.
ws_from(Msg) ->
    case maps:find('_ws', Msg) of
        {ok, Val} ->
            Val;
        _ ->
            none
    end.

%%
%% helpers
debug_string(#{<<"id">> := IdStr, <<"z">> := ZStr} = _NodeDef, Msg) ->
    debug_string(IdStr, ZStr, Msg).

%% erlfmt:ignore the stars are lined up
debug_string(NodeId,TabId,Msg) ->
    #{
      <<"id">>     => NodeId,
      <<"z">>      => TabId,
      <<"path">>   => TabId,
      <<"name">>   => <<"Unit Test Notice">>,
      <<"topic">>  => <<"">>,
      <<"msg">>    => Msg,
      <<"format">> => <<"string">>
    }.

assert_failure(NodeDef, WsName, ErrMsg) ->
    this_should_not_happen(NodeDef, ErrMsg),

    Data = ?ObtainFrom(NodeDef)#{
        <<"msg">> => jstr(ErrMsg),
        <<"format">> => <<"string">>
    },

    debug(WsName, Data, error),
    node_status(WsName, NodeDef, "assert failed", "red", "dot").

%%
%% Since exceptions are either handled by a catch node or posted in the
%% debug panel if they don't get caught.
post_exception_or_debug(NodeDef, Msg, {Type, Exception, Stack} = Eee) ->
    case post_exception(NodeDef, Msg, Eee) of
        dealt_with ->
            ok;
        _ ->
            send_out_debug_error(
                NodeDef, Msg#{
                    <<"error_type">> => jstr(Type),
                    <<"error">> => #{
                        <<"exception">> => Exception,
                        <<"stack">> => Stack
                    }
                }
            )
    end;
post_exception_or_debug(NodeDef, Msg, ErrMsg) ->
    case post_exception(NodeDef, Msg, jstr(ErrMsg)) of
        dealt_with ->
            ok;
        _ ->
            send_out_debug_error(
                NodeDef, Msg#{<<"error_msg">> => jstr(ErrMsg)}
            )
    end.

%%
%% Helper to convert Erlang types to Node-RED debug types.
%%
type_to_node_red_debug_type(V) when is_map(V) ->
    <<"Object">>;
type_to_node_red_debug_type(V) when is_list(V) ->
    <<"array">>;
type_to_node_red_debug_type(V) when is_number(V) ->
    <<"number">>;
type_to_node_red_debug_type(V) when is_binary(V) ->
    <<"string">>;
type_to_node_red_debug_type(_) ->
    <<"Object">>.
