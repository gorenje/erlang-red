-module(ered_node_erlprocess).

-behaviour(ered_node).

-include("ered_nodes.hrl").

-export([
    start/2,
    handle_msg/2,
    handle_event/2,
    group_leader_process/3
]).

%%
%% Delay pauses the travels of a message by XX units of time.
%%
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

%%
%%
start(#{<<"pid">> := TgtPid} = NodeDef, WsName) when
    TgtPid =/= <<>>
->
    try
        PidOrAtom =
            case string:split(TgtPid, <<".">>, all) of
                [_A, _B, _C] ->
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
    node_status(WsName, NodeDef, jstr("dead: ~p",[Status]), "red", "dot");

handle_event(M, NodeDef) ->
    io:format("ErlProcess Received: ~p~n", [M]),
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
              maps:find(<<"msgtype">>, Msg));
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
    {handled, NodeDef, Msg}.

%%
%%
check_pid(ErlPid, #{<<"capture_io">> := CaptureIo} = NodeDef, WsName) ->
    case is_process_alive(ErlPid) of
        true ->
            erlang:monitor(process, ErlPid),

            {group_leader, OrigGroupLeader} = process_info(ErlPid, group_leader),

            case CaptureIo of
                V when V =:= true; V =:= <<"true">> ->
                    io:format( "GRABBIGN I/O~n",[]),
                    G1 = new_group_leader(self(), NodeDef, WsName),
                    group_leader(G1, ErlPid);
                _ ->
                    do_no_th_in_g
            end,

            node_status(WsName, NodeDef, "alive", "green", "dot"),

            NodeDef#{
                     erlpid => ErlPid,
                     grpldr => OrigGroupLeader,
                     ?SetWsName
                    };
        _ ->
            node_status(WsName, NodeDef, "dead", "red", "dot"),
            maps:remove(erlpid, NodeDef)
    end.

new_group_leader(Runner, NodeDef, WsName) ->
    %% We must use spawn/3 here (with explicit module and function
    %% name), because the 'current function' status of the group leader
    %% is used by the UNDER_EUNIT macro (in eunit.hrl). If we spawn
    %% using a fun, the current function will be 'erlang:apply/2' during
    %% early process startup, which will fool the macro.
    spawn_link(?MODULE, group_leader_process, [Runner, NodeDef, WsName]).

group_leader_process(Runner, NodeDef, WsName) ->
    group_leader_loop(Runner, infinity, [], NodeDef, WsName).

group_leader_loop(Runner, Wait, Buf, NodeDef, WsName) ->
    receive
        {io_request, From, ReplyAs, Req} ->
            P = process_flag(priority, normal),
            %% run this part under normal priority always
            Buf1 = io_request(From, ReplyAs, Req, Buf),

            send_out_debug_msg(NodeDef, #{'_ws' => WsName}, jstr(Buf1), normal),
            process_flag(priority, P),
            group_leader_loop(Runner, Wait, [], NodeDef, WsName);
        stop ->
            %% quitting time: make a minimal pause, go low on priority,
            %% set receive-timeout to zero and schedule out again
            receive
            after 2 -> ok
            end,
            process_flag(priority, low),
            group_leader_loop(Runner, 0, Buf, NodeDef, WsName);
        _ ->
            %% discard any other messages
            group_leader_loop(Runner, Wait, Buf, NodeDef, WsName)
    after Wait ->
        %% no more messages and nothing to wait for; we ought to
        %% have collected all immediately pending output now
        process_flag(priority, normal),
        Runner ! {self(), done}
    end.

io_request(From, ReplyAs, Req, Buf) ->
    {Reply, Buf1} = io_request(Req, Buf),
    io_reply(From, ReplyAs, [Reply]),
    Buf1.

io_reply(From, ReplyAs, Reply) ->
    From ! {io_reply, ReplyAs, Reply}.

io_request({put_chars, Chars}, Buf) ->
    {ok, [Chars | Buf]};
io_request({put_chars, M, F, As}, Buf) ->
    try apply(M, F, As) of
        Chars -> {ok, [Chars | Buf]}
    catch
        C:T:S -> {{error, {C, T, S}}, Buf}
    end;
io_request({put_chars, _Enc, Chars}, Buf) ->
    io_request({put_chars, Chars}, Buf);
io_request({put_chars, _Enc, Mod, Func, Args}, Buf) ->
    io_request({put_chars, Mod, Func, Args}, Buf);
io_request({get_chars, _Enc, _Prompt, _N}, Buf) ->
    {eof, Buf};
io_request({get_chars, _Prompt, _N}, Buf) ->
    {eof, Buf};
io_request({get_line, _Prompt}, Buf) ->
    {eof, Buf};
io_request({get_line, _Enc, _Prompt}, Buf) ->
    {eof, Buf};
io_request({get_until, _Prompt, _M, _F, _As}, Buf) ->
    {eof, Buf};
io_request({get_until, _Enc, _Prompt, _M, _F, _As}, Buf) ->
    {eof, Buf};
io_request({setopts, _Opts}, Buf) ->
    {ok, Buf};
io_request(getopts, Buf) ->
    {{error, enotsup}, Buf};
io_request({get_geometry, columns}, Buf) ->
    {{error, enotsup}, Buf};
io_request({get_geometry, rows}, Buf) ->
    {{error, enotsup}, Buf};
io_request({requests, Reqs}, Buf) ->
    io_requests(Reqs, {ok, Buf});
io_request(_, Buf) ->
    io:format("Donw here~n",[]),
    {{error, request}, Buf}.

io_requests([R | Rs], {ok, Buf}) ->
    io_requests(Rs, io_request(R, Buf));
io_requests(_, Result) ->
    Result.
