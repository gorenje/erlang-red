-module(ered_node_erlgenserver).

-behaviour(ered_node).

-include("ered_nodes.hrl").

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Generic server starter node.
%%

-import(ered_nodes, [
    jstr/2,
    send_msg_to_connected_nodes/2
]).

-import(ered_nodered_comm, [
    post_exception_or_debug/3,
    node_status/5
]).

-define(UseNameAddressing, <<"use_module_name_addressing">> := true).
-define(UsePidAddressing, <<"use_module_name_addressing">> := false).
-define(GetLookup, '_lookup' := Lookup).
-define(CallFindDetails,
    case find_module_details(ModuleNodeId, Starter) of
        {ok, ModuleName, Pid} ->
            %% indirectly all modules are started as being linked to this
            %% process - this ensures that all nodes have a status update
            %% when a module shutsdown.
            erlang:monitor(process, Pid),
            start_modules(Rest, NodeDef#{
                '_lookup' => Lookup#{ModuleName => Pid}
            });
        {error, _NodeId} ->
            {error, modoule_not_found}
    end
).

%%
%%
start(NodeDef, WsName) ->
    ered_node:start(NodeDef#{'_ws' => WsName, '_lookup' => #{}}, ?MODULE).

%%
%%
handle_event(
    {registered, WsName, _MyPid},
    #{<<"scope">> := ModuleNodeIds} = NodeDef
) ->
    process_flag(trap_exit, true),

    case start_modules(ModuleNodeIds, NodeDef) of
        {ok, NewNodeDef} ->
            node_status(WsName, NodeDef, "started", "green", "dot"),
            NewNodeDef;
        {error, ModuleName} ->
            ErrMsg = jstr("failed to load: ~p", [ModuleName]),
            node_status(WsName, NodeDef, ErrMsg, "red", "dot"),
            NodeDef
    end;
%%
%% event handler shutdown but we're not being supervised.
handle_event(
    {'DOWN', _Ref, process, _Pid, _Reason},
    #{?GetWsName} = NodeDef
) ->
    node_status(WsName, NodeDef, "stopped", "red", "dot");
%%
handle_event(
    {'EXIT', _From, normal = Reason},
    #{?GetWsName} = NodeDef
) ->
    node_status(WsName, NodeDef, "stopped", "red", "dot"),
    exit(self(), Reason);
handle_event(
    {'EXIT', _From, Reason},
    #{?GetWsName} = NodeDef
) ->
    node_status(WsName, NodeDef, "killed", "red", "dot"),
    exit(self(), Reason);
handle_event(
    {gen_server_terminated, Event},
    #{?GetWsName, '_lookup' := Lookup} = NodeDef
) ->
    Msg = ?AddWsName(#{error => Event}),
    post_exception_or_debug(NodeDef, Msg, "fatal error"),
    node_status(WsName, NodeDef, "fatal error", "red", "ring"),
    [exit(P, kill) || {_, P} <- maps:to_list(Lookup)],
    handled;
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg(
    {incoming,
        #{
            <<"module">> := ModuleName,
            <<"call">> := CallName,
            <<"payload">> := Payload
        } = Msg},
    NodeDef
) ->
    Msg2 =
        Msg#{
            <<"payload">> => call_module(ModuleName, CallName, Payload, NodeDef)
        },
    send_msg_to_connected_nodes(NodeDef, Msg2),
    {handled, NodeDef, Msg2};
handle_msg(
    {incoming,
        #{
            <<"module">> := ModuleName,
            <<"call">> := CallName
        } = Msg},
    NodeDef
) ->
    Msg2 = Msg#{<<"payload">> => call_module(ModuleName, CallName, NodeDef)},
    send_msg_to_connected_nodes(NodeDef, Msg2),
    {handled, NodeDef, Msg2};
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%%  helpers
%%
start_modules([], NodeDef) ->
    {ok, NodeDef};
start_modules(
    [ModuleNodeId | Rest],
    #{?GetLookup, ?UseNameAddressing} = NodeDef
) ->
    Starter = fun(Exports, ModuleName) ->
        case
            case lists:keyfind(start_link, 1, Exports) of
                false ->
                    ModuleName:start();
                _ ->
                    ModuleName:start_link()
            end
        of
            {ok, P} ->
                P;
            {error, {already_started, P1}} ->
                P1
        end
    end,
    ?CallFindDetails;
start_modules(
    [ModuleNodeId | Rest],
    #{?GetLookup, ?UsePidAddressing} = NodeDef
) ->
    Starter =
        fun RefStarter(Exports, ModuleName) ->
            case
                case lists:keyfind(start_link, 1, Exports) of
                    false ->
                        ModuleName:start();
                    _ ->
                        ModuleName:start_link()
                end
            of
                {ok, P} ->
                    unregister(ModuleName),
                    P;
                {error, {already_started, _P1}} ->
                    unregister(ModuleName),
                    RefStarter(Exports, ModuleName)
            end
        end,
    ?CallFindDetails.

%%
%%
find_module_details(ModuleNodeId, ModuleStarter) ->
    case ered_erlmodule_exchange:find_module(ModuleNodeId) of
        {not_found, _NodeId} ->
            {error, ModuleNodeId};
        {ok, ModuleName} ->
            case code:is_loaded(ModuleName) of
                false ->
                    {error, ModuleNodeId};
                _ ->
                    Exports =
                        element(
                            2,
                            lists:keyfind(
                                exports, 1, ModuleName:module_info()
                            )
                        ),
                    Pid = ModuleStarter(Exports, ModuleName),
                    {ok, ModuleName, Pid}
            end
    end.

%%
%%
%% With a payload
call_module(
    ModuleName, CallName, Payload, NodeDef
) when is_binary(ModuleName) ->
    call_module(binary_to_atom(ModuleName), CallName, Payload, NodeDef);
call_module(
    ModuleName, CallName, Payload, NodeDef
) when is_binary(CallName) ->
    call_module(ModuleName, binary_to_atom(CallName), Payload, NodeDef);
call_module(
    ModuleName,
    CallName,
    Payload,
    #{?GetLookup, ?UsePidAddressing}
) when is_atom(ModuleName), is_atom(CallName) ->
    io:format("ddd ~p ~p~n", [CallName, Payload]),
    #{ModuleName := ModulePid} = Lookup,
    gen_server:call(ModulePid, {CallName, Payload});
call_module(
    ModuleName,
    CallName,
    Payload,
    #{?UseNameAddressing}
) when is_atom(ModuleName), is_atom(CallName) ->
    ModuleName:CallName(Payload).

%%
%% Without a payload
call_module(
    ModuleName, CallName, NodeDef
) when is_binary(ModuleName) ->
    call_module(binary_to_atom(ModuleName), CallName, NodeDef);
call_module(
    ModuleName, CallName, NodeDef
) when is_binary(CallName) ->
    call_module(ModuleName, binary_to_atom(CallName), NodeDef);
call_module(
    ModuleName,
    CallName,
    #{?GetLookup, ?UsePidAddressing}
) when is_atom(ModuleName), is_atom(CallName) ->
    #{ModuleName := ModulePid} = Lookup,
    gen_server:call(ModulePid, CallName);
call_module(
    ModuleName, CallName, #{?UseNameAddressing}
) when is_atom(ModuleName), is_atom(CallName) ->
    ModuleName:CallName().
