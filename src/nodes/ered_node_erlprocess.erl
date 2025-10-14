-module(ered_node_erlprocess).

-behaviour(ered_node).

-include("ered_nodes.hrl").

-export([
    start/2,
    handle_msg/2,
    handle_event/2
]).

%%
%% Interact with existing process of an Erlang machine.
%%
%% "type": "erlprocess",
%% "pid": "<0.0.0>",
%%

-import(ered_nodered_comm, [
    node_status/5,
    post_exception_or_debug/3,
    send_out_debug_msg/4,
    unsupported/3,
    ws_from/1
]).
-import(ered_nodes, [
    jstr/1,
    jstr/2,
    send_msg_to_connected_nodes/2
]).
-import(ered_messages, [
    convert_to_num/1,
    convert_units_to_milliseconds/2
]).

-import(ered_message_exchange, [
    post_exception/3
]).

-define(RegExpPid, "[<][[:digit:]]+[.][[:digit:]]+[.][[:digit:]]+[>]").

%%
%%
start(#{<<"pid">> := TgtPid} = NodeDef, WsName) when
    TgtPid =/= <<>>
->
    try
        PidOrAtom =
            case re:run(TgtPid, ?RegExpPid) of
                {match, _} ->
                    list_to_pid(binary_to_list(TgtPid));
                _ ->
                    binary_to_atom(TgtPid)
            end,
        ered_node:start(NodeDef#{erlpid => PidOrAtom}, ?MODULE)
    catch
        E:F:S ->
            node_status(WsName, NodeDef, "error", "red", "ring"),
            post_exception_or_debug(NodeDef, #{'_ws' => WsName}, {E, F, S}),
            ered_node:start(NodeDef, ered_node_ignore)
    end;
start(NodeDef, WsName) ->
    unsupported(NodeDef, {websocket, WsName}, "no process id set"),
    ered_node:start(NodeDef, ered_node_ignore).

%%
%% handle_event/2
%%
handle_event(
    {registered, WsName, _Pid},
    #{erlpid := ErlPid} = NodeDef
) when is_pid(ErlPid) ->
    check_pid(ErlPid, NodeDef, WsName);
handle_event(
    {registered, WsName, _Pid},
    #{erlpid := ErlPid} = NodeDef
) when is_atom(ErlPid) ->
    case whereis(ErlPid) of
        undefined ->
            node_status(WsName, NodeDef, "dead", "red", "dot"),
            maps:remove(erlpid, NodeDef);
        PidPid ->
            check_pid(PidPid, NodeDef, WsName)
    end;
handle_event(
    {'DOWN', _Ref, process, ErlPid, Status},
    #{erlpid := ErlPid, ?GetWsName} = NodeDef
) ->
    node_status(WsName, NodeDef, jstr("dead: ~p", [Status]), "red", "dot"),
    NodeDef;
handle_event({stop, _WsName}, NodeDef) ->
    NodeDef;
handle_event(M, NodeDef) ->
    %% what magic shall happen when monitoring existing processes?
    io:format("ErlProcess handled: ~p~n", [M]),
    NodeDef.

%%
%% handle_msg/2
%%

handle_msg(
    {incoming, #{?GetPayload, ?GetWsName} = Msg},
    #{erlpid := TgtPid} = NodeDef
) ->
    case is_process_alive(TgtPid) of
        true ->
            send_payload_to_process(
                NodeDef,
                Msg,
                TgtPid,
                Payload,
                maps:find(<<"msgtype">>, Msg)
            );
        false ->
            node_status(WsName, NodeDef, "dead", "red", "dot"),
            {handled, maps:remove(erlpid, NodeDef), Msg}
    end;
%%
%% process is not available
handle_msg(
    {incoming, #{?PayloadIsSet, ?GetWsName} = Msg},
    NodeDef
) ->
    ErrMsg = jstr("process is dead"),
    node_status(WsName, NodeDef, "dead", "red", "dot"),
    post_exception_or_debug(NodeDef, Msg, ErrMsg),
    {handled, NodeDef, dont_send_complete_msg};
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% ---------------- helpers
%%

send_payload_to_process(NodeDef, Msg, Pid, Payload, {ok, <<"call">>}) ->
    Msg2 = Msg#{<<"payload">> => gen_server:call(Pid, Payload)},
    send_msg_to_connected_nodes(NodeDef, Msg2),
    {handled, NodeDef, Msg};
send_payload_to_process(NodeDef, Msg, Pid, Payload, {ok, <<"cast">>}) ->
    gen_server:call(Pid, Payload),
    {handled, NodeDef, Msg};
send_payload_to_process(NodeDef, Msg, Pid, Payload, _) ->
    Pid ! Payload,
    %% info messages are passed through, for a cascading affect!
    send_msg_to_connected_nodes(NodeDef, Msg),
    {handled, NodeDef, Msg}.

%%
%%
check_pid(ErlPid, #{<<"id">> := NodeId} = NodeDef, WsName) ->
    case is_process_alive(ErlPid) of
        true ->
            % If subprocess does exit(..) propagate to us.
            process_flag(trap_exit, true),
            ered_capture_io_exchange:pid_for(NodeId, ErlPid, WsName),

            erlang:monitor(process, ErlPid),
            node_status(WsName, NodeDef, "alive", "green", "dot"),

            NodeDef#{erlpid => ErlPid, ?SetWsName};
        _ ->
            node_status(WsName, NodeDef, "dead", "red", "dot"),
            maps:remove(erlpid, NodeDef)
    end.
