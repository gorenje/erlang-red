-module(ered_capture_io_exchange).

-behaviour(gen_server).

-export([
    init/1,
    code_change/3,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    stop/0,
    start_link/0
]).

-export([
    capture/2,
    capture_remove/1,
    pid_for/3,
    group_leader_process/4
]).

-import(ered_nodes, [
    send_msg_on/2
]).

-import(ered_messages, [
    any_to_binary/1,
    create_outgoing_msg/1
]).

%%
%%
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, #{}, []).

init(Args) ->
    {ok, Args#{captures => []}}.

capture(NodeId, Wires) ->
    gen_server:call(?MODULE, {capture, NodeId, Wires}).
capture_remove(NodeId) ->
    gen_server:call(?MODULE, {remove, NodeId}).

pid_for(NodeId, Pid, WsName) ->
    gen_server:call(?MODULE, {pid, Pid, NodeId, WsName}).

%%
%%
%%  ------------------ call

handle_call(
    {capture, NodeId, Wires},
    _From,
    #{captures := Capts} = State
) ->
    {reply, ok, State#{captures => [{NodeId, Wires} | Capts]}};
handle_call(
    {pid, Pid, NodeId, WsName},
    _From,
    #{captures := Capts} = State
) ->
    case lists:keyfind(NodeId, 1, Capts) of
        false ->
            {reply, ok, State};
        {NodeId, Wires} ->
            setup_capturer(Pid, Wires, WsName),
            {reply, ok, State}
    end;
handle_call(
    {remove, NodeId},
    _From,
    #{captures := Capts} = State
) ->
    {reply, ok, State#{captures => lists:keydelete(NodeId, 1, Capts)}};
handle_call(state, _From, State) ->
    {reply, State, State};
handle_call({print, What}, _From, State) ->
    io:format("~p", [What]),
    {reply, ok, State};
handle_call(M, _From, State) ->
    io:format("~p~n", [M]),
    {reply, ok, State}.

%%
%%
%%  ------------------ cast

handle_cast(_, State) ->
    {noreply, State}.

%%
%%
%%  ------------------ info
handle_info(_, State) ->
    {noreply, State}.

%%
%%
code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

stop() ->
    gen_server:cast(?MODULE, stop).

%%
%%
terminate(normal, _State) ->
    ok;
terminate(_, _State) ->
    ok.

%%
%% --------------------- helpers
%%

setup_capturer(Pid, Wires, WsName) ->
    G1 = new_group_leader(self(), Wires, WsName, Pid),
    io:format("~p~n", [G1]),
    group_leader(G1, Pid).

new_group_leader(Runner, Wires, WsName, Pid) ->
    %% We must use spawn/3 here (with explicit module and function
    %% name), because the 'current function' status of the group leader
    %% is used by the UNDER_EUNIT macro (in eunit.hrl). If we spawn
    %% using a fun, the current function will be 'erlang:apply/2' during
    %% early process startup, which will fool the macro.
    spawn_link(?MODULE, group_leader_process, [Runner, Wires, WsName, Pid]).

group_leader_process(Runner, Wires, WsName, Pid) ->
    monitor(process, Pid),
    group_leader_loop(Runner, infinity, [], Wires, WsName).

group_leader_loop(Runner, Wait, Buf, Wires, WsName) ->
    receive
        {io_request, From, ReplyAs, Req} ->
            P = process_flag(priority, normal),
            %% run this part under normal priority always
            Buf1 = io_request(From, ReplyAs, Req, Buf),

            {outgoing, Msg} = create_outgoing_msg(WsName),
            send_msg_on(Wires, Msg#{<<"payload">> => any_to_binary(Buf1)}),

            process_flag(priority, P),
            group_leader_loop(Runner, Wait, [], Wires, WsName);
        stop ->
            %% quitting time: make a minimal pause, go low on priority,
            %% set receive-timeout to zero and schedule out again
            receive
            after 2 -> ok
            end,
            process_flag(priority, low),
            group_leader_loop(Runner, 0, Buf, Wires, WsName);
        {'DOWN', _Ref, process, _P, _S} ->
            %% discard any other messages
            self() ! stop;
        _ ->
            %% discard any other messages
            group_leader_loop(Runner, Wait, Buf, Wires, WsName)
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
    io:format("Donw here~n", []),
    {{error, request}, Buf}.

io_requests([R | Rs], {ok, Buf}) ->
    io_requests(Rs, io_request(R, Buf));
io_requests(_, Result) ->
    Result.
