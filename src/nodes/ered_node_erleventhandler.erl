-module(ered_node_erleventhandler).

-behaviour(ered_node).

-include("ered_nodes.hrl").

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Event handler node for implementing the gen_event behaviour
%%
%% A very basic implementation that does not support passing arguments to
%% the add_handler/3 call nor id value in the name of the handler. That
%% is just so.
%%

-import(ered_nodered_comm, [
    node_status/5,
    node_status_clear/2,
    post_exception_or_debug/3,
    ws_from/1
]).

-import(ered_nodes, [
    jstr/1,
    send_msg_to_connected_nodes/2
]).

-define(EVENTHANDLER_PID, '_eventh_pid' := EventHandlerPid).

%%
%%
start(NodeDef, WsName) ->
    ered_node:start(?AddWsName(NodeDef), ?MODULE).

%%
%%
handle_event({registered, WsName, _MyPid}, NodeDef) ->
    {ok, {Pid, _Ref}} = gen_event:start_monitor(),

    case add_handlers(Pid, maps:find(<<"handlers">>, NodeDef)) of
        ok ->
            node_status(WsName, NodeDef, "started", "green", "dot");
        {error, ErrorList} ->
            [
                post_exception_or_debug(NodeDef, #{?SetWsName}, jstr(ErrMsg))
             || ErrMsg <- ErrorList
            ],
            node_status(WsName, NodeDef, "invalid", "blue", "ring")
    end,

    NodeDef#{'_eventh_pid' => Pid};
%%
handle_event({being_supervised, _WsName}, NodeDef) ->
    %% need this to obtain the exits when the supervisor kills this node
    %% this then triggers a killing of the state machine process - see EXIT
    %% event below.
    process_flag(trap_exit, true),
    NodeDef;
%%
%% if the event handler goes down and we're being supervised, then we
%% also go down, i.e., the node process goes down so that the supervisor
%% can deal with it.
handle_event(
    {'DOWN', _Ref, process, _Pid, Reason},
    #{?IsBeingSupervised, ?GetWsName} = NodeDef
) ->
    node_status(WsName, NodeDef, "stopped", "red", "dot"),
    exit(self(), Reason),
    maps:remove('_eventh_pid', NodeDef);
%%
%% event handler shutdown but we're not being supervised.
handle_event(
    {'DOWN', _Ref, process, _Pid, _Reason},
    #{?GetWsName} = NodeDef
) ->
    node_status(WsName, NodeDef, "stopped", "red", "dot"),
    maps:remove('_eventh_pid', NodeDef);
%%
handle_event(
    {'EXIT', _From, Reason},
    #{?IsBeingSupervised, ?EVENTHANDLER_PID, ?GetWsName} = NodeDef
) ->
    node_status(WsName, NodeDef, "killed", "red", "ring"),
    exit(EventHandlerPid, Reason),
    exit(self(), Reason),
    maps:remove('_eventh_pid', NodeDef);
handle_event(
    {stop, _WsName},
    #{?EVENTHANDLER_PID} = NodeDef
) ->
    exit(EventHandlerPid, normal),
    maps:remove('_eventh_pid', NodeDef);
handle_event(_, NodeDef) ->
    NodeDef.

%%
%% Add a handler to the event handler, the "payload" attribute must be the
%% name of a loaded module.
handle_msg(
    {incoming,
        #{
            <<"action">> := <<"add_handler">>,
            <<"payload">> := ModuleName
        } = Msg},
    #{?EVENTHANDLER_PID} = NodeDef
) ->
    ModAtom = binary_to_atom(ModuleName),
    case code:is_loaded(ModAtom) of
        false ->
            post_exception_or_debug(NodeDef, Msg, <<"module not loaded">>);
        _ ->
            R = gen_event:add_handler(EventHandlerPid, ModAtom, Msg),
            send_msg_to_connected_nodes(NodeDef, Msg#{<<"payload">> => R})
    end,
    {handled, NodeDef, dont_send_complete_msg};
%%
%% delete a previously defined handler from an event handler.
handle_msg(
    {incoming,
        #{
            <<"action">> := <<"delete_handler">>,
            <<"payload">> := ModuleName
        } = Msg},
    #{?EVENTHANDLER_PID} = NodeDef
) ->
    ModAtom = binary_to_atom(ModuleName),
    R = gen_event:delete_handler(EventHandlerPid, ModAtom, Msg),
    send_msg_to_connected_nodes(NodeDef, Msg#{<<"payload">> => R}),
    {handled, NodeDef, dont_send_complete_msg};
%%
%% handle an event
handle_msg(
    {incoming,
        #{
            <<"event">> := EventName
        } = Msg},
    #{?EVENTHANDLER_PID} = NodeDef
) ->
    gen_event:notify(EventHandlerPid, {EventName, Msg, NodeDef}),
    {handled, NodeDef, dont_send_complete_msg};
%%
%% event handler process is not running, handle message but do nothing with it
handle_msg(
    {incoming, _Msg},
    NodeDef
) ->
    {handled, NodeDef, dont_send_complete_msg};
%%
%%
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% ------------------- Helpers
%%
%%
%% add handlers is used for the static configuration of the event handler.
add_handlers(_EventHandlerPid, error) ->
    % missing list, no static configuration
    ok;
add_handlers(EventHandlerPid, {ok, Handlers}) ->
    add_handlers(EventHandlerPid, Handlers, []).

%%
%% Collect together all errors - nothing worse than fixing one error and then
%% being confronted with the next even though the system knew that already.
add_handlers(_EventHandlerPid, [], []) ->
    % empty handler list and empty error list, all done
    ok;
add_handlers(_EventHandlerPid, [], ErrorList) ->
    % empty handler list and empty error list, all done
    {error, ErrorList};
add_handlers(
    EventHandlerPid,
    [#{<<"nodeid">> := NodeId} | MoreHndlrs],
    ErrorList
) ->
    case ered_erlmodule_exchange:find_module(NodeId) of
        {not_found, _NodeId} ->
            Error = io_lib:format(
                "Module for NodeId ~p not found",
                [NodeId]
            ),
            add_handlers(EventHandlerPid, MoreHndlrs, [Error | ErrorList]);
        {ok, ModuleName} ->
            case code:is_loaded(ModuleName) of
                false ->
                    Error = io_lib:format(
                        "Module ~p (~p) is not loaded",
                        [NodeId, ModuleName]
                    ),
                    add_handlers(
                        EventHandlerPid,
                        MoreHndlrs,
                        [Error | ErrorList]
                    );
                _ ->
                    gen_event:add_handler(
                        EventHandlerPid,
                        ModuleName,
                        []
                    ),
                    add_handlers(EventHandlerPid, MoreHndlrs, ErrorList)
            end
    end.
