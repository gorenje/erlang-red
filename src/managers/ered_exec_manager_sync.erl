-module(ered_exec_manager_sync).

-behaviour(gen_server).

-export([
    init/1,
    code_change/3,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    stop/0,
    start/5
]).

%%
%% This is the synchronise executor. It is based on the async module and
%% does much the same as the async module only buffering the stdout and stderr
%% data and sending that data out upon the process dying. Either by a timeout
%% or normal stop.
%%

-import(ered_nodes, [
    jstr/2,
    send_msg_on/2
]).

-define(ToPayload(Buffer), list_to_binary(lists:reverse(Buffer))).

% erlfmt:ignore alignment
start(NodePid, Wires, Cmd, Msg, Opts) ->
    exec:start(),
    [StdoutWires, StderrWires, DoneWires] = Wires,
    gen_server:start(
        ?MODULE,
        [
            #{
                nodepid      => NodePid,      %% 1
                stdoutwires  => StdoutWires,  %% 2
                stderrwires  => StderrWires,  %% 3
                donewires    => DoneWires,    %% 4
                command      => Cmd,          %% 5
                message      => Msg,          %% 6
                options      => Opts,         %% 7
                erlangpid    => -1,           %% 8 - Erlang PID
                machinepid   => -1            %% 9 - Machine PID
            }
        ],
        []
    ).

init([State]) ->
    Store = ets:new(
        ered_exec_node_buffers,
        [set, protected, {write_concurrency, true}]
    ),
    ets:insert(Store, {stdout, []}),
    ets:insert(Store, {stderr, []}),
    {ok, State#{buffers => Store}}.

%%
%%
handle_call({kill_command, Signal}, _From, #{machinepid := MachPid} = State) ->
    exec:kill(MachPid, sig_to_num(binary_to_atom(Signal))),
    {reply, ok, State};
handle_call(
    run_command,
    _From,
    #{
        buffers := Buffer,
        command := Cmd,
        options := #{timeout := Timeout}
    } = State
) ->
    {ok, Pid, MachPid} = exec:run(Cmd, [stdout, stderr, monitor]),

    ThisPid = self(),
    Ref =
        Timeout > 0 andalso
            timer:apply_after(
                Timeout * 1000,
                fun() ->
                    %% We send out the messages here because the message queue
                    %% might be flooded by a command similar to "yes no" and any
                    %% messages will not get through. So sending a timeout
                    %% message would just be queued behind many thousands
                    %% of "output" messages.
                    %%
                    %% Hence this time out handler sends the content we have and
                    %% kills and deletes everything else.
                    %%
                    %% But if the process has already completed, then we have
                    %% already sent the messages, so this does not need to
                    %% happen.
                    case exec:pid(MachPid) of
                        undefined ->
                            ignore;
                        {error, _} ->
                            ignore;
                        _ ->
                            exec:kill(MachPid, sig_to_num('SIGTERM')),

                            %% Has the ETS table disappeared because the process
                            %% has already completed? Then don't resend the data.
                            lists:member(Buffer, ets:all()) andalso
                                push_out_stdout_stderr(State),

                            post_off_done(
                                #{<<"pid">> => MachPid, <<"code">> => 15},
                                State
                            )
                    end,

                    erlang:exit(ThisPid, timeout)
                end
            ),

    {reply, MachPid, State#{
        erlangpid => Pid, machinepid => MachPid, timer => Ref
    }};
handle_call(Msg, _From, State) ->
    io:format("Exec Manager Unknown Call: ~p~n", [Msg]),
    {reply, ok, State}.

%%
%%
handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(Msg, State) ->
    io:format("Exec Manager Unknown Cast: ~p~n", [Msg]),
    {noreply, State}.

%%
%% Process exits here.
handle_info({timeout, _, 'TIMEOUT'}, #{machinepid := MachPid} = State) ->
    exec:kill(MachPid, sig_to_num('SIGTERM')),
    %% give the process 1 second to die else kill it.
    erlang:start_timer(1000, self(), 'TIMEOUT-KILL'),
    {noreply, State};
handle_info({timeout, _, 'TIMEOUT-KILL'}, #{machinepid := MachPid} = State) ->
    exec:kill(MachPid, sig_to_num('SIGKILL')),
    {noreply, State};
%%
%%
handle_info(
    {'DOWN', MachPid, process, _ErlangPid, Status},
    #{buffers := Buffer, timer := TimerRef} = State
) ->
    case TimerRef of
        {ok, {_, Ref}} ->
            timer:cancel(Ref);
        _ ->
            ok
    end,

    lists:member(Buffer, ets:all()) andalso push_out_stdout_stderr(State),

    Status2 =
        case Status of
            normal ->
                #{<<"code">> => 0};
            {exit_status, Num} ->
                #{<<"code">> => Num};
            _ ->
                #{<<"code">> => jstr("Unknown: ~p", [Status])}
        end#{
            <<"pid">> => MachPid
        },

    post_off_done(Status2, State),

    {stop, normal, State};
%%
%% Output being generated by command.
handle_info({stdout, _Pid, Payload}, #{buffers := Buffer} = State) ->
    [{stdout, Data}] = ets:lookup(Buffer, stdout),
    ets:insert(Buffer, {stdout, [Payload | Data]}),
    {noreply, State};
handle_info({stderr, _Pid, Payload}, #{buffers := Buffer} = State) ->
    [{stderr, Data}] = ets:lookup(Buffer, stderr),
    ets:insert(Buffer, {stderr, [Payload | Data]}),
    {noreply, State};
%%
%%
handle_info(Msg, State) ->
    io:format("Exec Manager Unknown Info: ~p~n", [Msg]),
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
terminate(Event, _State) ->
    io:format("Exec manager terminated with {{{ ~p }}}~n", [Event]),
    ok.

%%
%% ------------------ helpers
%%
push_out_stdout_stderr(
    #{
        message := Msg,
        buffers := Buffer,
        stdoutwires := StdoutWires,
        stderrwires := StderrWires
    } = _State
) ->
    [{stdout, StdoutBuffer}] = ets:lookup(Buffer, stdout),
    send_msg_on(StdoutWires, Msg#{<<"payload">> => ?ToPayload(StdoutBuffer)}),

    [{stderr, StderrBuffer}] = ets:lookup(Buffer, stderr),
    send_msg_on(StderrWires, Msg#{<<"payload">> => ?ToPayload(StderrBuffer)}).

post_off_done(
    PidAndErrorCode,
    #{
        message := Msg,
        nodepid := NodePid,
        donewires := DoneWires
    } = _State
) ->
    gen_server:cast(
        NodePid,
        {exec_process_died, Msg#{<<"payload">> => PidAndErrorCode}}
    ),
    send_msg_on(DoneWires, Msg#{<<"payload">> => PidAndErrorCode}).

%%
%%
% erlfmt:ignore alignment
sig_to_num('SIGHUP')      -> 1;
sig_to_num('SIGINT')      -> 2;
sig_to_num('SIGQUIT')     -> 3;
sig_to_num('SIGILL')      -> 4;
sig_to_num('SIGTRAP')     -> 5;
sig_to_num('SIGABRT')     -> 6;
sig_to_num('SIGBUS')      -> 7;
sig_to_num('SIGFPE')      -> 8;
sig_to_num('SIGKILL')     -> 9;
sig_to_num('SIGUSR1')     -> 10;
sig_to_num('SIGSEGV')     -> 11;
sig_to_num('SIGUSR2')     -> 12;
sig_to_num('SIGPIPE')     -> 13;
sig_to_num('SIGALRM')     -> 14;
sig_to_num('SIGTERM')     -> 15;
sig_to_num('SIGSTKFLT')   -> 16;
sig_to_num('SIGCHLD')     -> 17;
sig_to_num('SIGCONT')     -> 18;
sig_to_num('SIGSTOP')     -> 19;
sig_to_num('SIGTSTP')     -> 20;
sig_to_num('SIGTTIN')     -> 21;
sig_to_num('SIGTTOU')     -> 22;
sig_to_num('SIGURG')      -> 23;
sig_to_num('SIGXCPU')     -> 24;
sig_to_num('SIGXFSZ')     -> 25;
sig_to_num('SIGVTALRM')   -> 26;
sig_to_num('SIGPROF')     -> 27;
sig_to_num('SIGWINCH')    -> 28;
sig_to_num('SIGIO')       -> 29;
sig_to_num('SIGPWR')      -> 30;
sig_to_num('SIGSYS')      -> 31;
sig_to_num('SIGRTMIN')    -> 34;
sig_to_num('SIGRTMIN+1')  -> 35;
sig_to_num('SIGRTMIN+2')  -> 36;
sig_to_num('SIGRTMIN+3')  -> 37;
sig_to_num('SIGRTMIN+4')  -> 38;
sig_to_num('SIGRTMIN+5')  -> 39;
sig_to_num('SIGRTMIN+6')  -> 40;
sig_to_num('SIGRTMIN+7')  -> 41;
sig_to_num('SIGRTMIN+8')  -> 42;
sig_to_num('SIGRTMIN+9')  -> 43;
sig_to_num('SIGRTMIN+10') -> 44;
sig_to_num('SIGRTMIN+11') -> 45;
sig_to_num('SIGRTMIN+12') -> 46;
sig_to_num('SIGRTMIN+13') -> 47;
sig_to_num('SIGRTMIN+14') -> 48;
sig_to_num('SIGRTMIN+15') -> 49;
sig_to_num('SIGRTMAX-14') -> 50;
sig_to_num('SIGRTMAX-13') -> 51;
sig_to_num('SIGRTMAX-12') -> 52;
sig_to_num('SIGRTMAX-11') -> 53;
sig_to_num('SIGRTMAX-10') -> 54;
sig_to_num('SIGRTMAX-9')  -> 55;
sig_to_num('SIGRTMAX-8')  -> 56;
sig_to_num('SIGRTMAX-7')  -> 57;
sig_to_num('SIGRTMAX-6')  -> 58;
sig_to_num('SIGRTMAX-5')  -> 59;
sig_to_num('SIGRTMAX-4')  -> 60;
sig_to_num('SIGRTMAX-3')  -> 61;
sig_to_num('SIGRTMAX-2')  -> 62;
sig_to_num('SIGRTMAX-1')  -> 63;
sig_to_num('SIGRTMAX')    -> 64;
%% Default is SIGTERM
sig_to_num(_) -> sig_to_num('SIGTERM').
