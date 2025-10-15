-module(ered_capture_io_group_leader).

-behaviour(gen_server).

-export([
    init/1,
    code_change/3,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    stop/0,
    start_link/1
]).

%%
%% This little gem is used as the group leader for processes of whom we
%% want to capture the I/O - e.g. io:format(..) calls.
%%
%% This is instantiated once per websocket and is used for all processes to be
%% captured for that websocket. It remains around while other processes come
%% and go.
%%
%% It is managed by the ered_capture_io_exchange service which is responsible
%% for managing all cpature group leaders across all web sockets.
%%
-import(ered_nodes, [
    jstr/2
]).

-import(ered_nodes, [
    send_msg_on/2
]).

-import(ered_messages, [
    any_to_binary/1,
    create_outgoing_msg/1
]).

start_link(WsName) ->
    gen_server:start_link(?MODULE, WsName, []).

init(WsName) ->
    erlang:register(binary_to_atom(jstr("capio_grp_ldr_~s", [WsName])), self()),
    {ok, #{pids => [], wires => #{}, wsname => WsName}}.

%%
%%
%%  ------------------ call
handle_call(
    {capture, NodeId, Wires},
    _From,
    #{wires := NodeWires} = State
) ->
    State2 =
        case maps:find(NodeId, NodeWires) of
            error ->
                State#{wires => NodeWires#{
                      NodeId => lists:flatten([Wires])
                }};
            {ok, ExistingWires} ->
                State#{
                    wires => NodeWires#{
                        NodeId => lists:flatten([Wires | ExistingWires])
                    }
                }
        end,

    %% once the state has been updated, check wether we have a pid for the
    %% nodeId and potentially replaced the group leader with this process
    {reply, ok, can_set_group_leader(NodeId, State2)};
%%
handle_call(
    {pid, Pid, NodeId},
    _From,
    #{pids := Pids} = State
) ->
    {reply, ok,
        can_set_group_leader(NodeId, State#{pids => [{NodeId, Pid} | Pids]})};
%%
handle_call(
    {remove, NodeId},
    _From,
    #{wires := Wires} = State
) ->
    {reply, ok, State#{wires => maps:remove(NodeId, Wires)}};
handle_call(state, _From, State) ->
    {reply, State, State};
handle_call(_, _From, State) ->
    {reply, ok, State}.

%%
%%
%%  ------------------ cast
handle_cast(stop, State) ->
    {stop, State};
handle_cast(_, State) ->
    {noreply, State}.

%%
%%
%%  ------------------ info
handle_info(
    {io_request, From, ReplyAs, Req},
    #{pids := NodeId2Pid, wires := NodeId2Wires, wsname := WsName} = State
) ->
    Buf1 = io_request(From, ReplyAs, Req, []),

    case lists:keyfind(From, 2, NodeId2Pid) of
        {NodeId, From} ->
            case maps:find(NodeId, NodeId2Wires) of
                {ok, Wires} ->
                    {outgoing, Msg} = create_outgoing_msg(WsName),
                    Msg2 = Msg#{
                        <<"payload">> => any_to_binary(Buf1),
                        <<"captureio">> => #{
                            <<"source">> => #{
                                <<"id">> => NodeId,
                                <<"pid">> => From
                            }
                        }
                    },
                    send_msg_on(Wires, Msg2);
                _ ->
                    ignore
            end;
        _ ->
            ignore
    end,

    {noreply, State};
%
handle_info(
    {'DOWN', _From, process, Pid, _Style},
    #{pids := NodeId2Pid} = State
) ->
    {noreply, State#{pids => lists:keydelete(Pid, 2, NodeId2Pid)}};
%
%
%
handle_info(M, State) ->
    io:format("Group Leader handled: ~p~n", [M]),
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
%% ------------------ helpers
%%
can_set_group_leader(
    NodeId,
    #{pids := NodeId2Pid, wires := NodeId2Wires} = State
) ->
    %% Need to do three things:
    %%   1. are their wires defined for the NodeId?
    %%   2. is there a Pid for the NodeId defined?
    %%   3. if there is a Pid for the NodeId, has it already got this PID as
    %%      group leader?
    %% If 1 & 2 are true and 3 is false, the we set this PID as group leader.
    MyPid = self(),
    case
        {lists:keyfind(NodeId, 1, NodeId2Pid), maps:find(NodeId, NodeId2Wires)}
    of
        {{NodeId, Pid}, {ok, _Wires}} ->
            case process_info(Pid, group_leader) of
                {group_leader, MyPid} ->
                    %% we are group leader already!
                    ignore;
                {group_leader, _SomeOtherLeader} ->
                    monitor(process, Pid),
                    group_leader(self(), Pid);
                _ ->
                    %% process_info returns undefined for dead processes
                    ignore
            end;
        _ ->
            %% don't have either wires or process id for NodeId
            %% This happens because there is no order in how nodes are
            %% initialised, so we have to deal with that.
            ignore
    end,

    State.

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
