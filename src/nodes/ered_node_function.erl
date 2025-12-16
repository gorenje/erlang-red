-module(ered_node_function).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Function node allows for Erlang to be executed on the server. I won't go
%% into what could possibly go wrong, it will fine. Don't worry about it.
%%

%%         "id": "f9fb40d63b894db4",
%%         "type": "function",
%%         "z": "3bba732ae17b01a9",
%%         "name": "function 2",
%%         "func": "\nfun (Msg) ->\n    Msg\nend.\n",
%%         "outputs": 1,
%%         "timeout": 0,
%%         "noerr": 0,
%%         "initialize": "",
%%         "finalize": "",
%%         "libs": [],
%%         "x": 639,
%%         "y": 385,
%%         "wires": [
%%             [
%%                 "295273281dd5b5c5"
%%             ]
%%         ]

%%
%% The function node was fine until I decided to implement the timeout feature.
%% This was done fairly simply by spawning out a new process for the execution
%% of the code and additionaly a second process is spun up that is a timer
%% to kill the process if it takes longer than the timeout to run.
%%
%% This worked wonderfully especially since it is necessary to spin up two
%% processes for *each* message received. If the timer is triggered, this
%% node (there being exactly one process for this node) receives the timeout
%% message with a process id. The process id is of the process executing the
%% function code.
%%
%% This node checks whether the function-code-execution process is still
%% alive (it might have already exited normally). If the process is alive,
%% then this node will kill the process *and* post off an exception indicating
%% that the timeout was triggered. If the process *isn't* alive, then this node
%% does exactly nothing, nada, nichts.
%%
%% Great that works rather well. And is - IMHO - an elegant solution to the
%% problem of implementing the timeout for a function.
%%
%% However what happens when a supervisor comes along and is supervising this
%% node. Again, we have the same issue as with the supervisor-of-supervisor
%% problem: when does a supervisor node fail? One important rule I have is that
%% node processes don't go down. They have to maintain the flow editor frontend
%% with their status. Processes representing nodes DON'T die .... unless they
%% are supervised by the loving grace of a supervisor. Supervisor nodes then
%% are responsible for restarting nodes. But nodes that have sub-processes
%% that they - in turn - manage are a problem.
%%
%% What happens when the subprocess dies? In a normal case what happens is that
%% the node doesn't care. Let the subprocess die. The node will restart it
%% in due course. This changes when the subprocess represents the functionality
%% of the node, i.e., if the subprocess dies, then there is an inconsistency
%% in the functionality if the node so it should indicate that by also dying.
%% But only if its being supervised - so that it can either be restarted or
%% stop working - since "stop working" is part of the functionality of the
%% node, not the process.
%%
%% Now, here is the problem: if the function node is killed by a supervisor
%% because another node went down *and* the supervisor has restart policy
%% of "one for all" or "rest for one", then this node has to be killed even
%% though it might be functioning perfectly well. When this happens, this node
%% has to kill all its subprocesses executing function code (the timeout
%% processes will take care of itself) and then the node has to exit itself.
%%
%% Good sounds straightforward. Problem is that this node has no list of
%% subprocesses and nor does it want to. Since a new process is spun up for
%% each message this node receives, that could become a long list.
%%
%% Using an erlang:link has the problem that its bidirectional. So that if the
%% subprocess goes down, it takes this node with it. I only want the subprocess
%% to go down when this node goes down.
%%
%% The current solution is to move most of the logic to the
%% ered_function_code_manager module and have it deal with it - done. Oh, you
%% say and who is going to code that code?!?! Doh. Life simply cannot be easy.
%%
%% Anyway it was easy. The ered_function_code_manager is monitoring this
%% process and kills its subprocess if this node goes down. The manager only
%% deals with one message, i.e., a manager process is spun up by this node
%% for each message it receives. There are bunch of edge cases, all documented
%% with test flows. This node has slightly different behaviour if supervised
%% by a supervisor node. All sorts of goodies.
%%

-import(ered_function_code_manager, [
    execute_sync/3,
    is_code_parsable/1,
    is_function_code/1
]).

-import(ered_nodes, [
    jstr/1,
    jstr/2
]).

-import(ered_nodered_comm, [
    node_status/5,
    node_status_clear/2,
    node_status_clear_after/3,
    post_exception_or_debug/3
]).

-define(WrapInFunction(Code),
    io_lib:format("fun(NodeDef,Msg) -> ~n ~s ~n end.", [Code])
).

-define(ExecuteCodeInSync,
    execute_sync(
        ?WrapInFunction(Code),
        NodeDef,
        #{'_ws' => WsName}
    )
).

%% The node process should never go down. That is the premise upon which we
%% build the software. However, this is not true if the node is being supervised.
%% In that case, if *any* subprocess goes down, then the node process goes
%% down to indicate to the supervisor that failure has happened.
-define(ExitWhenSupervised(Why),
    case maps:find('_being_supervised', NodeDef) of
        {ok, true} ->
            exit(self(), Why);
        _ ->
            post_exception_or_debug(
                NodeDef,
                Msg#{<<"cause">> => Why},
                "unexpected exit"
            ),
            #{'_ws' := WsName} = Msg,
            node_status(WsName, NodeDef, <<"failed">>, "red", "dot")
    end
).

%%
%%
start(NodeDef, _WsName) ->
    % Ensure timeout value is set to a number and converted to milliseconds
    % or infinity if the value is negative or zero.
    ered_node:start(
        case maps:find(<<"timeout">>, NodeDef) of
            {ok, Val} ->
                try
                    case binary_to_integer(Val) * 1000 of
                        N when N < 0 ->
                            NodeDef#{<<"timeout">> => infinity};
                        N when N =:= 0 ->
                            NodeDef#{<<"timeout">> => infinity};
                        N ->
                            NodeDef#{<<"timeout">> => N}
                    end
                catch
                    _E:_F:_S ->
                        NodeDef#{<<"timeout">> => infinity}
                end;
            _ ->
                NodeDef#{<<"timeout">> => infinity}
        end,
        ?MODULE
    ).

%%
%% Execute the "On Start" code once this node has been regisgtered
handle_event(
    {registered, WsName, _Pid},
    #{<<"initialize">> := <<>>} = NodeDef
) ->
    validate_erlang_code(NodeDef, WsName),
    NodeDef;
handle_event(
    {registered, WsName, _Pid},
    #{<<"initialize">> := Code} = NodeDef
) ->
    %% check the validity of the code before it gets executed.
    validate_erlang_code(NodeDef, WsName),
    %% Start up code is **expected** to return a NodeDef map, return that
    %% as the return value of this function.
    ?ExecuteCodeInSync;
%%
%% Execute the "On Stop" code when the node is stopped. Which is the same
%% as when this node is killed....
%% TODO: ensure that folks don't put anything important in the "On Stop" tab
%% TODO: because the code gets rarely executed (it would have to be executed
%% TODO: each time this node is killed by a supervisor - for example - I don't
%% TODO: think that happens at the moment).
handle_event({stop, _WsName}, #{<<"finalize">> := <<>>} = NodeDef) ->
    NodeDef;
handle_event({stop, WsName}, #{<<"finalize">> := Code} = NodeDef) ->
    %% Finalise code is **expected** to return a NodeDef map, return that
    %% as the return value of this function.
    ?ExecuteCodeInSync;
%%
%% The down event is generated when the spawned process that is executing the
%% code goes down.
handle_event({'DOWN', func_code_mgr, msg, _Msg, normal}, NodeDef) ->
    % ignore only "normal" exits because I read this:
    % https://stackoverflow.com/questions/42123376/how-stop-terminate-shutdown-and-exit-are-related/42124862#42124862
    %
    % """
    %   Ordinary messages are really a special kind of signal that always go
    %   to the mailbox; exit signals (except for normal) cause receivers to also
    %   die unless they trap exits, so that groups of linked processes can be
    %   brought down together.
    % """
    %
    % So this means that the function process also goes down when it receives
    % a non-normal exit, any for that matter.
    NodeDef;
handle_event({'DOWN', func_code_mgr, msg, Msg, timeout_killing}, NodeDef) ->
    % The process running our code was killed by the timeout monitoring
    % what does this mean for our supervisor? Is this is a fatal exit for
    % us or do we handle it? Answer: if something takes too long, then it's
    % a reason to exit but only if we're being supervised by the loving grace
    % of something great than ourselves.
    ?ExitWhenSupervised(timeout),
    NodeDef;
handle_event({'DOWN', func_code_mgr, msg, Msg, Reason}, NodeDef) ->
    % exit but only exit if there is a supervisor watching over us, this
    % implements the idea that nodes don't die - they just grow old.
    % The node is responsible for updating the frontend, so the process should
    % only go down if there is a coordinated restart, i.e., a supervisor
    % watching over us with loving grace.
    ?ExitWhenSupervised(Reason),
    NodeDef;
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg({incoming, Msg}, NodeDef) ->
    {ok, Pid} = ered_function_code_manager:start(NodeDef, Msg),
    Pid ! perform_func_code,
    {handled, NodeDef, dont_send_complete_msg};
handle_msg({func_completed_with, Msg}, NodeDef) ->
    {handled, NodeDef, Msg};
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% ----------------- helpers
%%
validate_erlang_code(#{<<"func">> := <<>>} = NodeDef, WsName) ->
    node_status(WsName, NodeDef, "empty code not possible", "red", "dot");
validate_erlang_code(#{<<"func">> := Code} = NodeDef, WsName) ->
    case check_code_for_function(Code) of
        is_function ->
            node_status(WsName, NodeDef, "parsed", "green", "dot"),
            node_status_clear_after(1000, WsName, NodeDef);
        wrap_in_function ->
            case is_code_parsable(?WrapInFunction(Code)) of
                {ok, _ParsedCode} ->
                    node_status(WsName, NodeDef, "parsed", "green", "dot"),
                    node_status_clear_after(1000, WsName, NodeDef);
                {error, {error, ErrorList}} ->
                    Msg = ?AddWsName(#{
                          error => compiler_list_to_json_list(ErrorList)
                    }),
                    post_exception_or_debug(NodeDef, Msg, <<"compile failed">>),
                    node_status(WsName, NodeDef,
                                "invalid Erlang code", "red", "dot");
                Error ->
                    io:format("ERROR : [~p] ~p ~n ", [Code, Error]),
                    node_status(WsName, NodeDef, "unknown error", "red", "dot")
            end
    end.

check_code_for_function(Code) ->
    case is_function_code(Code) of
        {ok, _} ->
            is_function;
        _ ->
            wrap_in_function
    end.

%%
%% ErrorLists and WarnLists aren't JSON compatible therefore they need to be
%% massaged into form.
%% See https://www.erlang.org/doc/apps/compiler/compile.html for details.
compiler_list_to_json_list({_Line, _Module, _Desc} = Eroro) ->
    errorinfo_tuple_to_list(Eroro).
errorinfo_tuple_to_list({Line, Module, Desc}) ->
    [
        % subtract 2 because there is a wrapper function around the code.
        list_to_binary(io_lib:format("Line: ~~~p", [Line - 2])),
        Module,
        list_to_binary(io_lib:format("~p", [Desc]))
    ].
