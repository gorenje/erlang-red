-module(ered_node_supervisor).

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

-export([init/1]).
-export([extract_nodes/3]).

%%
%% Supervisor for restarting processes that die unexpectedly.
%%
%% "type": "erlsupervisor",
%% "scope": [         <<--- this can also be "group" or "flow"
%%     "874cb18b3842747d",
%%     "84927e2b99bfc27b"
%% ],
%% "supervisor_type": "static", <<--- or "dynamic"
%% "strategy": "one_for_all", <<--+- as desribed in the OTP docu
%% "auto_shutdown": "never", <<--/
%% "intensity": "5",     <<-----/
%% "period": "30",     <<------/
%% "child_type": "worker",
%% "child_restart": "permanent",
%% "child_shutdown": "brutal_kill",  <<--- if this timeout then
%% "child_shutdown_timeout": "",  <<<---- this value is relevant
%%
%% This node is a "manager" of a manager. The architecture of this node
%% isn't that simple. First off there is a process for the node but only
%% if it can be intiailised, i.e., it has a valid configuration and its
%% nodes (i.e. children) are available.
%%
%% Once the node is ready, it's spun up using the start/2 call. Once that
%% has happened it will receive a "registered" event and spins up its children
%% using the ered_supervisor_manager - which is the supervisor responsible
%% for starting and restarting the children. It implements the configuration
%% of the node.
%%
%% The ered_supervisor_manager dies when the intensity is reached. This death
%% would take this node with it (supervisors always being linked) but since
%% that is not desirable, there is another supervisr between this node and
%% the ered_supervisor_manager. It buffers the death of the manager and
%% not much more. It does not perform a restart of the manager because its
%% restart strategy is temporary.
%%
%% This buffer supervisor is created in the create_children/3 call. This call
%% is also used when an incoming message requests the restart of the supervisor.
%% create_children/3 will stop any exising "buffer" supervisor and also
%% restart the ered_supervisor_manager.
%%
%% This works fine if this supervisor node is not being supervised by another
%% supervisor, i.e., supervisor-of-supervisor pattern. The problem there is
%% the death of the ered_supervisor_manager has to be propagated up the
%% supervisor chain. But this node does everything to prevent itself from
%% dying with the supervisor dies. In a supervisor-of-supervisor pattern,
%% this node needs to die since the supervisor is supervising the node
%% process NOT the process of the supervisor that dies when the children die.
%%
%% Luckily that happens is that this node receives a message when the supervisor
%% goes down - the "{'DOWN', ...}" message. It receievs this message to alter
%% its status - from started to dead. What we do is set a flag on the NodeDef
%% of this node to tell it to go down if and only if its supervisor goes down.
%% We only set this flag if the supervisor node is being supervised.
%%
%% When the node goes down, the supervisor supervising it, restarts the entire
%% node. Simple really.
%%
-import(ered_nodes, [
    is_supervisor/1,
    jstr/1,
    send_msg_to_connected_nodes/2
]).

-import(ered_nodered_comm, [
    node_status/5,
    unsupported/3,
    ws_from/1
]).

-import(ered_msg_handling, [
    convert_to_num/1,
    create_outgoing_msg/1
]).

%%
%%
start(NodeDef, WsName) ->
    node_status(WsName, NodeDef, "starting", "green", "ring"),
    ered_node:start(maps:put('_ws', WsName, NodeDef), ?MODULE).

%% erlfmt:ignore alignment
init(Children) ->
    {ok, {
          #{
            strategy      => one_for_all,
            intensity     => 1,
            period        => 5,
            auto_shutdown => any_significant
      }, Children}}.

%%
%%
check_config(NodeDef) ->
    check_config(
        maps:get(strategy, NodeDef),
        maps:get(auto_shutdown, NodeDef),
        maps:get(supervisor_type, NodeDef)
    ).

check_config(_Strategy, <<"any_significant">>, _SupervisorType) ->
    {no, "auto shutdown"};
check_config(_Strategy, <<"all_significant">>, _SupervisorType) ->
    {no, "auto shutdown"};
check_config(_Strategy, _AutoShutdown, <<"dymanic">>) ->
    {no, "dynamic supervisor type"};
check_config(<<"simple_one_for_one">>, _AutoShutdown, _SupervisorType) ->
    {no, "simple one-to-one"};
check_config(_Strategy, _AutoShutdown, _SupervisorType) ->
    ok.

%%
%%
handle_event({registered, WsName, _Pid}, NodeDef) ->
    case maps:find('_my_node_defs', NodeDef) of
        {ok, Children} ->
            create_children(Children, NodeDef, WsName);
        _ ->
            ignore
    end,
    NodeDef;
handle_event({stop, WsName}, NodeDef) ->
    node_status(WsName, NodeDef, "stopped", "red", "dot"),
    case maps:find('_super_ref', NodeDef) of
        {ok, SupRef} ->
            is_process_alive(SupRef) andalso exit(SupRef, shutdown),
            maps:remove('_super_ref', NodeDef);
        _ ->
            NodeDef
    end;
handle_event({'DOWN', _, process, Pid, shutdown}, NodeDef) ->
    WsName = ws_from(NodeDef),

    case maps:get('_super_ref', NodeDef) of
        Pid ->
            node_status(WsName, NodeDef, "dead", "blue", "ring"),
            send_status_message(<<"dead">>, NodeDef, WsName);
        _ ->
            ignore
    end,

    case maps:find('_fail_on_supervisor_death', NodeDef) of
        {ok, true} ->
            self() ! {stop, WsName};
        _ ->
            ignore
    end,
    NodeDef;
handle_event({supervisor_started, _SupRef}, NodeDef) ->
    % This event is generated by the the ered_supervisor_manager module
    % once it has spun up the supervisor that actually supervises the nodes.
    WsName = ws_from(NodeDef),
    node_status(WsName, NodeDef, "started", "green", "dot"),
    send_status_message(<<"started">>, NodeDef, WsName),
    NodeDef;
handle_event({monitor_this_process, SupRef}, NodeDef) ->
    % This event is generated by the the ered_supervisor_manager module
    % once it has spun up the supervisor that actually supervises the nodes.
    erlang:monitor(process, SupRef),
    maps:put('_super_ref', SupRef, NodeDef);
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg({incoming, Msg}, NodeDef) ->
    WsName = ws_from(Msg),

    case maps:get(action, Msg) of
        <<"restart">> ->
            case maps:find('_my_node_defs', NodeDef) of
                {ok, MyNodeDefs} ->
                    create_children(MyNodeDefs, NodeDef, WsName),
                    send_status_message(<<"restarted">>, NodeDef, WsName);
                _ ->
                    ErrMsg = "restart action",
                    unsupported(
                        NodeDef, {websocket, WsName}, ErrMsg
                    ),
                    self() ! {stop, WsName}
            end;
        _ ->
            ignore
    end,
    {handled, NodeDef, Msg};
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%%
send_status_message(Status, NodeDef, WsName) ->
    {_, Msg} = create_outgoing_msg(WsName),
    Msg2 = maps:put(status, Status, Msg),
    send_msg_to_connected_nodes(NodeDef, Msg2).

%%
%%
filter_nodedefs(<<"flow">>, _NodeDefs) ->
    {error, "scope flow"};
filter_nodedefs(<<"group">>, _NodeDefs) ->
    {error, "scope group"};
filter_nodedefs(Scope, NodeDefs) when is_list(Scope) ->
    filter_nodedefs_by_ids(Scope, NodeDefs);
filter_nodedefs(_, _) ->
    {error, "unknown"}.

%%
%% Filter the NodeDefs by Id given a list of NodeIds for which this
%% node will act as supervisor.
filter_nodedefs_by_ids(LstOfNodeIds, NodeDefs) ->
    filter_nodedefs_by_ids(LstOfNodeIds, NodeDefs, [], []).
filter_nodedefs_by_ids(LstOfNodeIds, [], RestNodes, MyNodes) ->
    % order the nodes for this supervisor in the order of the IDs defined
    % in the scope list. This defines the start-up and shutdown order and
    % is for rest-for-one restart policy important.
    case {length(MyNodes), length(LstOfNodeIds)} of
        {Same, Same} ->
            Lookup = lists:map(fun(E) -> {maps:get(id, E), E} end, MyNodes),
            OrderMyNodes = lists:map(
                fun(E) ->
                    element(2, lists:keyfind(E, 1, Lookup))
                end,
                LstOfNodeIds
            ),
            {ok, {RestNodes, OrderMyNodes}};
        {_But, _Different} ->
            {error, "not all nodes found"}
    end;
filter_nodedefs_by_ids(
    LstOfNodeIds,
    [NodeDef | OtherNodeDefs],
    RestNodes,
    MyNodes
) ->
    case lists:member(maps:get(id, NodeDef), LstOfNodeIds) of
        true ->
            filter_nodedefs_by_ids(
                LstOfNodeIds,
                OtherNodeDefs,
                RestNodes,
                [NodeDef | MyNodes]
            );
        _ ->
            filter_nodedefs_by_ids(
                LstOfNodeIds,
                OtherNodeDefs,
                [NodeDef | RestNodes],
                MyNodes
            )
    end.

%%
%%
cf_child_restart(<<"temporary">>) -> temporary;
cf_child_restart(<<"transient">>) -> transient;
cf_child_restart(_) -> permanent.

cf_child_shutdown(<<"infinite">>, _) -> infinity;
cf_child_shutdown(<<"timeout">>, Timeout) -> convert_to_num(Timeout);
cf_child_shutdown(_, _Timeout) -> brutal_kill.

cf_child_type(<<"supervisor">>) -> supervisor;
cf_child_type(_) -> worker.

create_children(MyNodeDefs, SupNodeDef, WsName) ->
    SupNodeId = maps:get('_node_pid_', SupNodeDef),

    StartChild = fun(NodeDef) ->
        ChildId = binary_to_atom(
            list_to_binary(
                io_lib:format(
                    "child_~s_~s",
                    [SupNodeId, maps:get(id, NodeDef)]
                )
            )
        ),

        #{
            id => ChildId,
            start => {
                ered_nodes, spin_up_and_link_node, [NodeDef, WsName]
            },
            restart => cf_child_restart(maps:get(child_restart, SupNodeDef)),
            shutdown => cf_child_shutdown(
                maps:get(child_shutdown, SupNodeDef),
                maps:get(child_shutdown_timeout, SupNodeDef)
            ),
            type => cf_child_type(maps:get(child_type, SupNodeDef))
        }
    end,

    SupOfSupName = binary_to_atom(
        list_to_binary(
            io_lib:format(
                "supervisor_manager_~s",
                [SupNodeId]
            )
        )
    ),

    whereis(SupOfSupName) =/= undefined andalso unregister(SupOfSupName),

    %% this supervisor ensures that this node does not go down when the
    %% supervisor supervising the nodes goes down.
    %% The configuraton for this supervisor is the init/1 function of this
    %% module.

    supervisor:start_link(?MODULE, [
        #{
            id => SupOfSupName,
            start => {
                ered_supervisor_manager,
                start_link,
                [
                    self(),
                    SupNodeDef,
                    [StartChild(NodeDef) || NodeDef <- MyNodeDefs]
                ]
            },
            restart => temporary,
            shutdown => brutal_kill,
            type => supervisor
        }
    ]),

    maps:put('_my_node_defs', MyNodeDefs, SupNodeDef).

%%
%% From the list of Node definitions, remove all those nodes that are managed
%% by the Supervisor (defined by the SupNodeDef) and return the reduced list of
%% nodes including this supervisor definition.
%%
%% If something goes wrong, return the original list of node definitions.
extract_nodes(SupNodeDef, NodeDefs, WsName) ->
    case check_config(SupNodeDef) of
        {no, ErrMsg} ->
            unsupported(SupNodeDef, {websocket, WsName}, ErrMsg),
            {error, NodeDefs};
        _ ->
            case filter_nodedefs(maps:get(scope, SupNodeDef), NodeDefs) of
                {ok, {RestNodeDefs, MyNodeDefs}} ->
                    SupNodeDefWithNodes =
                        maps:put(
                            '_my_node_defs',
                            MyNodeDefs,
                            SupNodeDef
                        ),
                    {ok, [SupNodeDefWithNodes | RestNodeDefs]};
                {error, ErrMsg} ->
                    % TODO: group and flow are both not supported, although
                    % TODO: flow would be easy since it would imply all the
                    % TODO: nodedefs while group are all the nodes with the
                    % TODO: same 'g' value as the supervisor
                    unsupported(SupNodeDef, {websocket, WsName}, ErrMsg),
                    {error, NodeDefs}
            end
    end.
