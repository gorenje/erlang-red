-module(ered_node_erlstatemachine).

-behaviour(ered_node).

-include("ered_nodes.hrl").

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Implement the gen_statem behaviour.
%%
%% This is a basic implementation likely to change. I did just enough to
%% demonstrate the possibilities of using a state machine inside Erlang-Red.
%%
%%

-import(ered_nodes, [
    send_msg_to_connected_nodes/2
]).

-import(ered_nodered_comm, [
    node_status/5,
    node_status_clear/2,
    post_exception_or_debug/3,
    unsupported/3
]).

-import(ered_messages, [
    any_to_binary/1,
    to_bool/1
]).

-import(ered_nodes, [
    jstr/2
]).

-define(SendOffMsgWithPayload,
    Msg2 = Msg#{
        ?AddPayload(Result),
        <<"_statem">> => #{
            <<"state_prev">> => any_to_binary(PrevS),
            <<"state_curr">> => any_to_binary(CurrS),
            <<"payload">> => OrigPayload,
            <<"action">> => Action
        }
    },
    send_msg_to_connected_nodes(NodeDef, Msg2),
    {handled, NodeDef, Msg2}
).

-define(SendOffMsg,
    Msg2 = Msg#{
        ?AddPayload(Result),
        <<"_statem">> => #{
            <<"state_prev">> => any_to_binary(PrevS),
            <<"state_curr">> => any_to_binary(CurrS),
            <<"action">> => Action
        }
    },
    send_msg_to_connected_nodes(NodeDef, Msg2),
    {handled, NodeDef, Msg2}
).

-define(StatusError(ErrMsg),
    node_status(
        WsName,
        NodeDef,
        jstr("Error: ~p", [ErrMsg]),
        "red",
        "dot"
    )
).

%% start/2

start(
    #{<<"scope">> := Scope} = NodeDef,
    WsName
) when Scope =:= null; Scope =:= [] ->
    ?StatusError("module not found"),
    ered_node:start(NodeDef, ered_node_ignore);
%%
%% Since the emit on state change option is a node config, it can't be
%% changed, so we can set the function to handle message sending as start
%% time, this won't change during runtime.
%%

start(#{<<"emit_on_state_change">> := true} = NodeDef, WsName) ->
    ered_node:start(
        NodeDef#{'_func_send_msg' => fun send_message_on_state_change/6,
                 ?SetWsName},
        ?MODULE
    );
start(NodeDef, WsName) ->
    ered_node:start(
        NodeDef#{'_func_send_msg' => fun always_send_message/6, ?SetWsName},
        ?MODULE
    ).

%%
%% handle_event/2
%%

handle_event({registered, WsName, _MyPid}, #{<<"scope">> := Scope} = NodeDef) ->
    ModuleName = lists:nth(1, [
        case ered_erlmodule_exchange:find_module(N) of
            {ok, ModName} ->
                ModName;
            {not_found, _} ->
                not_found
        end
     || N <- Scope
    ]),

    case ModuleName of
        not_found ->
            ?StatusError("module not found"),
            maps:remove('_statem_pid', NodeDef);
        _ ->
            case module_loaded(ModuleName) of
                false ->
                    ?StatusError("module not found"),
                    maps:remove('_statem_pid', NodeDef);
                _ ->
                    case gen_statem:start_monitor(ModuleName, [], []) of
                        {ok, {Pid, _Ref}} ->
                            node_status(
                                WsName,
                                NodeDef,
                                element(1, sys:get_state(Pid)),
                                "blue",
                                "dot"
                            ),
                            maps:put('_statem_pid', Pid, NodeDef);
                        {error, ErrMsg} ->
                            ?StatusError(ErrMsg),
                            maps:remove('_statem_pid', NodeDef)
                    end
            end
    end;
handle_event({being_supervised, _WsName}, NodeDef) ->
    %% need this to obtain the exits when the supervisor kills this node
    %% this then triggers a killing of the state machine process - see EXIT
    %% event below.
    process_flag(trap_exit, true),
    NodeDef;
handle_event(
    {'EXIT', _From, Reason},
    #{
        ?GetWsName,
        ?IsBeingSupervised,
        '_statem_pid' := Pid
    } = NodeDef
) ->
    node_status(WsName, NodeDef, "killed", "red", "ring"),
    exit(Pid, Reason),
    exit(self(), Reason),
    maps:remove('_statem_pid', NodeDef);
handle_event(
    {stop, _WsName},
    #{
        '_statem_pid' := Pid
    } = NodeDef
) ->
    exit(Pid, normal),
    maps:remove('_statem_pid', NodeDef);
%%
%% state machine shutdown. This generally does not happen since the
%% individual state handlers modules crash but they are isolated from
%% the statemachine process that we're monitoring.
handle_event(
    {'DOWN', _Ref, process, _Pid, Reason},
    #{
        ?GetWsName,
        ?IsBeingSupervised
    } = NodeDef
) ->
    node_status(WsName, NodeDef, "stopped", "red", "dot"),
    exit(self(), Reason),
    maps:remove('_statem_pid', NodeDef);
handle_event(_, NodeDef) ->
    NodeDef.

%%
%% handle_msg/2
%%

%%
%%
%% Incoming message with Payload and Action defined, and the state machine
%% process is up and running.
handle_msg(
    {incoming,
        #{
            ?GetWsName,
            <<"action">> := Action,
            <<"payload">> := Payload
        } = Msg},
    #{
        '_statem_pid' := Pid,
        '_func_send_msg' := SendMsgFunc
    } = NodeDef
) ->
    {PrevState, Result, CurrState} = statem_call(Pid, {Action, Payload}),
    node_status(WsName, NodeDef, CurrState, "blue", "dot"),
    SendMsgFunc(NodeDef, Msg, Result, Action, CurrState, PrevState);
%% incoming message with only Action defined, and the state machine process
%% is up and runnning
handle_msg(
    {incoming,
        #{
            ?GetWsName,
            <<"action">> := Action
        } = Msg},
    #{
        '_statem_pid' := Pid,
        '_func_send_msg' := SendMsgFunc
    } = NodeDef
) ->
    {PrevState, Result, CurrState} = statem_call(Pid, Action),
    node_status(WsName, NodeDef, CurrState, "blue", "dot"),
    SendMsgFunc(NodeDef, Msg, Result, Action, CurrState, PrevState);
%% Error situaion, no action defined for a statemachine that is running - this
%% shouldn't happen.
handle_msg(
    {incoming, Msg},
    #{
        '_statem_pid' := _Pid
    } = NodeDef
) ->
    post_exception_or_debug(NodeDef, Msg, <<"no action to perform">>),
    {handled, NodeDef, dont_send_complete_msg};
%% Error situaion, statemachine process is dead or not defined
handle_msg(
    {incoming, Msg},
    NodeDef
) ->
    post_exception_or_debug(NodeDef, Msg, <<"no statemachine process">>),
    {handled, NodeDef, dont_send_complete_msg};
%%
%%
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% ------------------ Helpers

% send_message_on_state_change/6

send_message_on_state_change(
  NodeDef,
  #{<<"payload">> := OrigPayload} = Msg,
  Result,
  Action,
  CurrS,
  PrevS
) ->
    case CurrS =:= PrevS of
        true ->
            {handled, NodeDef, dont_send_complete_msg};
        _ ->
            ?SendOffMsgWithPayload
    end;
send_message_on_state_change(NodeDef, Msg, Result, Action, CurrS, PrevS) ->
    case CurrS =:= PrevS of
        true ->
            {handled, NodeDef, dont_send_complete_msg};
        _ ->
            ?SendOffMsg
    end.

% always_send_message/6

always_send_message(
  NodeDef,
  #{ <<"payload">> := OrigPayload} = Msg,
  Result,
  Action,
  CurrS,
  PrevS
) ->
    ?SendOffMsgWithPayload;
always_send_message(NodeDef, Msg, Result, Action, CurrS, PrevS) ->
    ?SendOffMsg.

% statem_call/2

statem_call(Pid, CallPayload) ->
    {
        element(1, sys:get_state(Pid)),
        gen_statem:call(Pid, CallPayload),
        element(1, sys:get_state(Pid))
    }.
