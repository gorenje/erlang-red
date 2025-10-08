-module(ered_node_exec).

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Exec node for executing external commands and piping the output
%% into the flows.
%%
%% [
%%     {
%%         "id": "4bff73814f9b5a17",
%%         "type": "exec",
%%         "z": "b98d0b05a760ad79",
%%         "command": "sleep 1000",
%%         "addpay": "",
%%         "append": "",
%%         "useSpawn": "true",
%%         "timer": "",  <--- timeout in seconds, kill process after this many seconds
%%         "winHide": false,
%%         "oldrc": false,
%%         "name": "",
%%         "x": 531,
%%         "y": 313.5,
%%         "wires": [
%%             [],
%%             [],
%%             []
%%         ]
%%     }
%% ]
%%

%%
%% TODO investigate how thsi interacts with a supervisor node supervising
%% TODO this node. I don't think it is supported at the moment.
%%

-import(ered_nodered_comm, [
    node_status/5,
    node_status_clear/2,
    post_exception_or_debug/3,
    unsupported/3,
    ws_from/1
]).
-import(ered_nodes, [
    jstr/2,
    send_msg_to_connected_nodes/2
]).
-import(ered_messages, [
    convert_to_num/1,
    convert_units_to_milliseconds/2,
    any_to_list/1,
    retrieve_prop_value/2,
    to_bool/1
]).

-define(PostPidAsStatus(PID),
    node_status(
        ws_from(Msg),
        NodeDef,
        jstr("pid:~s", [PID]),
        "blue",
        "dot"
    )
).

-define(StatusBecomesKilled,
    node_status(ws_from(Msg), NodeDef, "Killed", "red", "dot")
).

start(NodeDef, _WsName) ->
    ered_node:start(NodeDef#{'_process_list' => []}, ?MODULE).

%%
%%

handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg(
    {exec_process_died,
        #{
            <<"payload">> := #{<<"pid">> := MachPid, <<"code">> := StatusCode}
        } = Msg},
    #{
        '_process_list' := ProcessList
    } = NodeDef
) ->
    node_status_clear(ws_from(Msg), NodeDef),

    StatusCode > 0 andalso ?StatusBecomesKilled,

    %% trigger a post completed message
    {handled,
        NodeDef#{'_process_list' => lists:keydelete(MachPid, 1, ProcessList)},
        Msg};
handle_msg({incoming, Msg}, NodeDef) ->
    case maps:find(<<"kill">>, Msg) of
        {ok, Signal} ->
            %% kill a command
            %% Signal is something like SIGINT, SIGTERM, ...
            #{'_process_list' := ProcessList} = NodeDef,
            Tuple =
                case maps:find(<<"pid">>, Msg) of
                    {ok, MachPid} ->
                        %% this returns false if key is not found.
                        lists:keyfind(convert_to_num(MachPid), 1, ProcessList);
                    _ ->
                        %% If Pid is not specified and there is more than
                        %% one process running, then ignore the kill request.
                        case ProcessList of
                            [H | []] ->
                                H;
                            _ ->
                                false
                        end
                end,

            case Tuple of
                false ->
                    {handled, NodeDef, Msg};
                {_MachPid, ExecPid} ->
                    gen_server:call(ExecPid, {kill_command, Signal}),
                    {handled, NodeDef, Msg}
            end;
        _ ->
            %% execute a command
            {handled, start_command_running(Msg, NodeDef),
                dont_send_complete_msg}
    end;
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%%
start_command_running(Msg, #{<<"command">> := CmdStr} = NodeDef) ->
    start_command_running(CmdStr, Msg, NodeDef).

%%
%% Check the command value
start_command_running(
    <<>>,
    Msg,
    #{
        <<"addpay">> := <<>>,
        <<"append">> := <<>>
    } = NodeDef
) ->
    ErrMsg = jstr(
        "TypeError: The argument 'command' cannot be empty. Received ''", []
    ),
    post_exception_or_debug(NodeDef, Msg, ErrMsg),
    NodeDef;
start_command_running(
    Cmd, Msg, #{<<"timer">> := Timer} = NodeDef
) when Timer =/= <<>>, Timer =/= "" ->
    start_command_running(Cmd, Msg, NodeDef, Timer);
start_command_running(Cmd, Msg, NodeDef) ->
    start_command_running(Cmd, Msg, NodeDef, <<"-1">>).

%%
%% Start command running with a defined timer value
start_command_running(
    Cmd,
    Msg,
    #{
        <<"wires">> := Wires,
        <<"useSpawn">> := UseSpawn,
        <<"append">> := Append,
        <<"addpay">> := AddPayload,
        '_process_list' := ProcessList
    } = NodeDef,
    Timer
) ->
    Opts = #{
        append => Append,
        timeout => convert_to_num(Timer),
        addpayload => AddPayload
    },

    AppendStr =
        case Append of
            <<"">> ->
                "";
            _ ->
                " " ++ binary_to_list(Append)
        end,

    AddPayloadStr =
        case AddPayload of
            <<"">> ->
                "";
            PropName ->
                " " ++ any_to_list(retrieve_prop_value(PropName, Msg))
        end,

    {ok, ExecPid} =
        case UseSpawn of
            <<"true">> ->
                ered_exec_manager_async:start(
                    self(),
                    Wires,
                    any_to_list(Cmd) ++ AddPayloadStr ++ AppendStr,
                    Msg,
                    Opts
                );
            <<"false">> ->
                ered_exec_manager_sync:start(
                    self(),
                    Wires,
                    any_to_list(Cmd) ++ AddPayloadStr ++ AppendStr,
                    Msg,
                    Opts
                )
        end,

    MachPid = gen_server:call(ExecPid, run_command),

    ?PostPidAsStatus(integer_to_binary(MachPid)),

    NodeDef#{'_process_list' => [{MachPid, ExecPid}] ++ ProcessList}.
