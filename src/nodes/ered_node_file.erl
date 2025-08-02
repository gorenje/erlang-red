-module(ered_node_file).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% file is the counterpart to the "file in" node - this writes file data to
%% disk.
%%
%% {
%%     "id": "38743bd0c91a72e2",
%%     "type": "file",
%%     "z": "ba3d72801a820b0f",
%%     "g": "abfe9a27010ac650",
%%     "name": "",
%%     "filename": "filename",
%%     "filenameType": "msg",
%%     "appendNewline": true,
%%     "createDir": false,
%%     "overwriteFile": "delete", <<<----- just delete the file, nothing else
%%     "encoding": "none",
%%     "x": 601.4444580078125,
%%     "y": 616.3332824707031,
%%     "wires": [
%%         [
%%             "fc05c81222164d70"
%%         ]
%%     ]
%% }

-import(ered_nodes, [
    check_node_config/3,
    jstr/2,
    send_msg_to_connected_nodes/2
]).

-import(ered_nodered_comm, [
    node_status/5,
    post_exception_or_debug/3,
    send_out_debug_msg/4,
    unsupported/3
]).

-import(ered_messages, [
    convert_to_num/1,
    create_outgoing_msg/1,
    get_prop/2
]).

%%
%%
start(#{<<"filenameType">> := <<"env">>} = NodeDef, WsName) ->
    unsupported(NodeDef, {websocket, WsName}, "filename from env variable"),
    ered_node:start(NodeDef, ered_node_ignore);
start(#{<<"overwriteFile">> := <<"delete">>} = NodeDef, _WsName) ->
    ered_node:start(NodeDef, ?MODULE);
start(
    #{
        <<"overwriteFile">> := <<"true">>,
        <<"encoding">> := <<"none">>
    } = NodeDef,
    _WsName
) ->
    %% overwrite ==> true ==> overwrite file.
    ered_node:start(NodeDef, ?MODULE);
start(NodeDef, WsName) ->
    unsupported(NodeDef, {websocket, WsName}, "configuration"),
    ered_node:start(NodeDef, ered_node_ignore).

%%
%%
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg(
    {incoming, Msg},
    #{<<"overwriteFile">> := <<"delete">>} = NodeDef
) ->
    case get_filename(NodeDef, Msg) of
        {ok, Filename} ->
            file:delete(Filename);
        _ ->
            %% error has already been posted.
            ignore
    end,
    send_msg_to_connected_nodes(NodeDef, Msg),
    {handled, NodeDef, Msg};
handle_msg(
    {incoming, #{?GetPayload} = Msg},
    #{<<"overwriteFile">> := <<"true">>, <<"createDir">> := false} = NodeDef
) ->
    case get_filename(NodeDef, Msg) of
        {ok, Filename} ->
            {ok, Fd} = file:open(Filename, [raw, write]),
            file:write(Fd, Payload),
            file:close(Fd),
            send_msg_to_connected_nodes(NodeDef, Msg);
        _ ->
            %% error has already been posted.
            ignore
    end,
    {handled, NodeDef, Msg};
handle_msg(
    {incoming, #{?GetPayload} = Msg},
    #{<<"overwriteFile">> := <<"true">>, <<"createDir">> := true} = NodeDef
) ->
    case get_filename(NodeDef, Msg) of
        {ok, Filename} ->
            filelib:ensure_dir(Filename),
            {ok, Fd} = file:open(Filename, [raw, write]),
            file:write(Fd, Payload),
            file:close(Fd),
            send_msg_to_connected_nodes(NodeDef, Msg);
        _ ->
            %% error has already been posted.
            ignore
    end,
    {handled, NodeDef, Msg};
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% ----------------- Helpers
%%
get_filename(
    #{
        <<"filenameType">> := <<"msg">>,
        <<"filename">> := Prop
    } = NodeDef,
    Msg
) ->
    case get_prop(Prop, Msg) of
        {ok, V, _} ->
            {ok, V};
        R ->
            ErrMsg = jstr("property not found ~p", [Prop]),
            post_exception_or_debug(NodeDef, Msg, ErrMsg),
            R
    end;
get_filename(
    #{
        <<"filenameType">> := <<"jsonata">>,
        <<"filename">> := Value
    } = NodeDef,
    Msg
) ->
    case erlang_red_jsonata:execute(Value, Msg) of
        {ok, Result} ->
            {ok, Result};
        {error, Error} ->
            unsupported(NodeDef, Msg, jstr("jsonata term: ~p", [Error])),
            {error, Error};
        {unsupported, Error} ->
            unsupported(NodeDef, Msg, jstr("jsonata unsupported: ~p", [Error])),
            {error, Error};
        {exception, {_E, M, _S}} ->
            post_exception_or_debug(NodeDef, Msg, M),
            {error, M}
    end;
get_filename(
    #{
        <<"filenameType">> := <<"str">>,
        <<"filename">> := Value
    } = _NodeDef,
    _Msg
) ->
    {ok, Value}.
