-module(ered_startup).

-include("ered_nodes.hrl").

-export([
    create_pids_for_nodes/2,
    %% Spin up and link node is called by a supervisor to spin a node.
    spin_up_and_link_node/2,
    is_supervisor/1,
    add_counters/2,
    bump_counter/2
]).

%%
%% Creation time.
%%
%% The main rasion d'etre for this module is the create_pids_for_nodes/2
%% functionality that spins up the processes for the nodes defined in
%% a flow. This is used by unittest code and the compute engine. In
%% contains all sorts of logic for the various types of nodes and their
%% specific behaviours.
%%

-import(ered_nodered_comm, [
    node_status/5,
    send_out_debug_msg/4
]).
-import(ered_message_exchange, [
    clear_pg_group/1
]).
-import(ered_nodes, [
    get_node_name/2
]).

-define(IncrementCounter(CntName), begin
    NodeDef#{
        CntName => maps:get(CntName, NodeDef) + 1
    }
end).

%% TODO: a tab node (i.e. the tab containing a flow) also has a disabled
%% TODO: flag but this is called 'disabled'. If it is set, then the entire
%% TODO: flow should be ignored --> this is not handled at the moment.
create_pids_for_nodes(AryAll, WsName) ->
    store_config_nodes(AryAll, WsName),

    % all this does is ensure that the code contained in a module node
    % is installed in this instance of the BEAM.
    % TODO: because we do this before initialising any catch nodes, the
    % TODO: exception raised here always ends up in the debug panel.
    install_module_node_code(AryAll, WsName),

    % as a side affect, this will drop any disabled nodes from the list.
    {Ary, Supervisors} = extract_supervisors(AryAll),

    % limit is set sufficiently large (`+ 100`) so that complex supervisor trees
    % are supported. If the limit is too small, that can lead to distractingly
    % difficult bugs to debug. The Limit is a hard upper limit on the recursion
    % required for constructing supervisors trees. If there are no more
    % supervisors to configure, then the recursion exits before the limit
    % is reached.
    ReducedAry = supervisor_filter_nodes(
        Supervisors,
        Ary,
        [],
        WsName,
        length(Supervisors) + 100
    ),

    create_pids_for_nodes(ReducedAry, [], WsName).

create_pids_for_nodes([], Pids, WsName) ->
    [Pid ! {flow_started, WsName} || Pid <- Pids],
    Pids;
create_pids_for_nodes([NodeDef | MoreNodeDefs], Pids, WsName) ->
    case spin_up_node(NodeDef, WsName) of
        {ok, Pid} ->
            create_pids_for_nodes(MoreNodeDefs, [Pid | Pids], WsName);
        {error, no_id_found} ->
            create_pids_for_nodes(MoreNodeDefs, Pids, WsName)
    end.

%%
%% This can be used by a supervisor to revive a dead process.
spin_up_node(#{<<"id">> := IdStr, <<"type">> := TypeStr} = NodeDef, WsName) ->
    %% here have to respect the 'd' (disabled) attribute. if true, then
    %% the node does not need to have a Pid created for it.
    Module = node_type_to_module(TypeStr, disabled(NodeDef)),

    GrpName = get_node_name(WsName, IdStr),

    clear_pg_group(GrpName),

    %% The Module:start calls the ered_node:start(..) function which registers
    %% the PID with the corresponding pg group
    {ok, Pid} = Module:start(add_counters(NodeDef, GrpName), WsName),

    %% Perform any Post spawn activities. This is mostly registering with
    %% collectors of events as subscribers, see catch and complete nodes
    %% for examples. This is done after the spawn because to register
    %% with the various servers, a Pid is needed and that is not known
    %% when a node is initialised via the Module:start.
    gen_server:call(Pid, {registered, WsName, Pid}),

    {ok, Pid};
spin_up_node(NodeDef, _WsName) ->
    io:format("NO ID/TYPE FOUND FOR ~p~n", [NodeDef]),
    {error, no_id_found}.

%% Used by the supervisor node to restart/start nodes.
spin_up_and_link_node(NodeDef, WsName) ->
    {ok, Pid} = spin_up_node(NodeDef, WsName),

    erlang:link(Pid),

    % this flag indicates that a supervisor node should fall down if
    % its supervisor process dies, that's because the supervisor node
    % is being started by another supervisor. that supervisor is responsible
    % for restarting this node when it goes down. Also this function is
    % exclusively used by supervisor nodes, so its safe to set the
    % flag here. The top-level supervisor is started by the spin_up_nodes
    % function and hence does not have this flag.
    gen_server:call(Pid, {being_supervised, WsName}),

    {ok, Pid}.

%%
%%
install_module_node_code([], _WsName) ->
    ok;
install_module_node_code([NodeDef | ModeNodeDefs], WsName) ->
    case {is_module_node(NodeDef), disabled(NodeDef)} of
        {true, false} ->
            ered_node_erlmodule:install(NodeDef, WsName);
        _ ->
            ignore
    end,
    install_module_node_code(ModeNodeDefs, WsName).

%%
%% Add the state to the NodeDef to prepare it for starting the flow.
%%
%% internal message counters, get updated automagically in
%% enter_receivership ==> 'mc' is message counter.
%% erlfmt:ignore
add_counters(NodeDef, NodePid) ->
    NodeDef#{
       '_node_pid_'      => NodePid,
       '_mc_incoming'    => 0,
       '_mc_link_return' => 0,
       '_mc_websocket'   => 0,
       '_mc_outgoing'    => 0,
       '_mc_exception'   => 0
    }.

%%
%% this needs to be in sync with ered_nodes:add_counters/2
% erlfmt:ignore - alignment
bump_counter(exception,   NodeDef) -> ?IncrementCounter('_mc_exception');
bump_counter(ws_event,    NodeDef) -> ?IncrementCounter('_mc_websocket');
bump_counter(outgoing,    NodeDef) -> ?IncrementCounter('_mc_outgoing');
bump_counter(incoming,    NodeDef) -> ?IncrementCounter('_mc_incoming');
bump_counter(link_return, NodeDef) -> ?IncrementCounter('_mc_link_return');
bump_counter(_, NodeDef) ->
    NodeDef.

%%
%%
extract_supervisors(NodeDefs) ->
    extract_supervisors(NodeDefs, [], []).

extract_supervisors([], Supervisors, Nodes) ->
    {Nodes, Supervisors};
extract_supervisors([NodeDef | MoreNodeDefs], Supervisors, Nodes) ->
    case {is_supervisor(maps:get(<<"type">>, NodeDef)), disabled(NodeDef)} of
        {_, true} ->
            %% drop any disabled nodes from the list of nodes
            extract_supervisors(MoreNodeDefs, Supervisors, Nodes);
        {true, false} ->
            extract_supervisors(MoreNodeDefs, [NodeDef | Supervisors], Nodes);
        {false, false} ->
            extract_supervisors(MoreNodeDefs, Supervisors, [NodeDef | Nodes])
    end.

%%
%% supervisor_filter_nodes iterates through the node defintions until all
%% supervisors have their nodes. This iteration is needed for implementing
%% the supervisor-of-supervisor pattern.
%%
%% What each supervisor definition does is add the nodes to its definition
%% and remove those nodes from the list of node definitions. here order is
%% important since a supervisor should only be defined once the other supervisor
%% has defined itself. It has done this when it reappears in the list of
%% node definitions.
%%
%% A supervisor node definition will be removed from the list of node
%% definitions to be started but the supervisor will add itself back to the
%% list of node definitions once it has found all its children. Hence another
%% supervisor that is supervising that supervisor can then pick it up from
%% there.
supervisor_filter_nodes(
    Supervisors,
    NodeDefs,
    RedoSupers,
    WsName,
    0
) when length(Supervisors) > 0; length(RedoSupers) > 0 ->
    FailedSuper = fun(NodeDef, WebsocketName) ->
        send_out_debug_msg(
            NodeDef,
            #{'_ws' => WebsocketName},
            <<"Not all supervisors configured, check configurations">>,
            error
        ),
        node_status(WsName, NodeDef, "configuration failure", "red", "ring")
    end,
    [FailedSuper(ND, WsName) || ND <- (RedoSupers ++ Supervisors)],
    NodeDefs;
supervisor_filter_nodes(_Supervisors, NodeDefs, _RedoSupervisors, _WsName, 0) ->
    NodeDefs;
supervisor_filter_nodes([], NodeDefs, [], _WsName, _Limit) ->
    NodeDefs;
supervisor_filter_nodes([], NodeDefs, RedoSupervisors, _WsName, Limit) ->
    supervisor_filter_nodes(RedoSupervisors, NodeDefs, [], _WsName, Limit - 1);
supervisor_filter_nodes(
    [SupNodeDef | MoreSupNodeDefs],
    NodeDefs,
    RedoSupervisors,
    WsName,
    Limit
) ->
    Module = node_type_to_module(SupNodeDef),

    case Module:extract_nodes(SupNodeDef, NodeDefs, WsName) of
        {ok, ReducedNodeDefs} ->
            supervisor_filter_nodes(
                MoreSupNodeDefs,
                ReducedNodeDefs,
                RedoSupervisors,
                WsName,
                Limit - 1
            );
        {error, _} ->
            supervisor_filter_nodes(
                MoreSupNodeDefs,
                NodeDefs,
                [SupNodeDef | RedoSupervisors],
                WsName,
                Limit - 1
            )
    end.

%%
%% Squirrel away all config nodes to the config store for later retrieval
%% by nodes that use the config nodes.
store_config_nodes([], _WsName) ->
    ok;
store_config_nodes(
    [#{<<"type">> := NodeType} = NodeDef | OtherNodeDefs],
    WsName
) ->
    case is_config_node(NodeType) of
        true ->
            ered_config_store:store_config_node(NodeDef, WsName);
        _ ->
            ignore
    end,
    store_config_nodes(OtherNodeDefs, WsName).

%%
%% tab node usses 'disabled', everything else 'd'.
disabled(NodeDef) ->
    case maps:find(<<"d">>, NodeDef) of
        {ok, V} ->
            V;
        _ ->
            case maps:find(<<"disabled">>, NodeDef) of
                {ok, V} ->
                    V;
                _ ->
                    false
            end
    end.

%%
%% Lookup table for mapping node type to function. Also here we respect the
%% disabled flag: if node is disabled, give it a noop node else continue
%% on checking by type.
%%

node_type_to_module(_Type, true) ->
    ered_node_disabled;
node_type_to_module(Type, _) ->
    node_type_to_module(Type).

%%
%% Mapping more Node-RED Node Type to Erlang node module. Required because
%% some node types map to the same module, i.e. ered_node_ignore.
%%
%% erlfmt:ignore alignment.
node_type_to_module(#{<<"type">> := Type} = NodeDef) when is_map(NodeDef) ->
    node_type_to_module(Type);
node_type_to_module(<<"inject">>)            -> ered_node_inject;
node_type_to_module(<<"switch">>)            -> ered_node_switch;
node_type_to_module(<<"debug">>)             -> ered_node_debug;
node_type_to_module(<<"junction">>)          -> ered_node_junction;
node_type_to_module(<<"change">>)            -> ered_node_change;
node_type_to_module(<<"link out">>)          -> ered_node_link_out;
node_type_to_module(<<"link in">>)           -> ered_node_link_in;
node_type_to_module(<<"link call">>)         -> ered_node_link_call;
node_type_to_module(<<"delay">>)             -> ered_node_delay;
node_type_to_module(<<"file in">>)           -> ered_node_file_in;
node_type_to_module(<<"json">>)              -> ered_node_json;
node_type_to_module(<<"template">>)          -> ered_node_template;
node_type_to_module(<<"join">>)              -> ered_node_join;
node_type_to_module(<<"split">>)             -> ered_node_split;
node_type_to_module(<<"catch">>)             -> ered_node_catch;
node_type_to_module(<<"comment">>)           -> ered_node_ignore;
node_type_to_module(<<"tab">>)               -> ered_node_ignore;
node_type_to_module(<<"complete">>)          -> ered_node_complete;
node_type_to_module(<<"group">>)             -> ered_node_ignore;
node_type_to_module(<<"status">>)            -> ered_node_status;
node_type_to_module(<<"trigger">>)           -> ered_node_trigger;
node_type_to_module(<<"http in">>)           -> ered_node_http_in;
node_type_to_module(<<"http response">>)     -> ered_node_http_response;
node_type_to_module(<<"http request">>)      -> ered_node_http_request;
node_type_to_module(<<"mqtt in">>)           -> ered_node_mqtt_in;
node_type_to_module(<<"mqtt out">>)          -> ered_node_mqtt_out;
node_type_to_module(<<"exec">>)              -> ered_node_exec;
node_type_to_module(<<"function">>)          -> ered_node_function;
node_type_to_module(<<"markdown">>)          -> ered_node_markdown;
node_type_to_module(<<"csv">>)               -> ered_node_csv;
node_type_to_module(<<"FlowHubPull">>)       -> ered_node_flowhub_pull;
node_type_to_module(<<"erlsupervisor">>)     -> ered_node_erlsupervisor;
node_type_to_module(<<"erlmodule">>)         -> ered_node_erlmodule;
node_type_to_module(<<"erlstatemachine">>)   -> ered_node_erlstatemachine;
node_type_to_module(<<"erleventhandler">>)   -> ered_node_erleventhandler;
node_type_to_module(<<"tcp in">>)            -> ered_node_tcp_in;
node_type_to_module(<<"tcp out">>)           -> ered_node_tcp_out;
node_type_to_module(<<"erlgenserver">>)      -> ered_node_erlgenserver;
node_type_to_module(<<"ClientCode">>)        -> ered_node_clientcode;
node_type_to_module(<<"tcp request">>)       -> ered_node_tcp_request;
node_type_to_module(<<"file">>)              -> ered_node_file;
node_type_to_module(<<"i2c out">>)           -> ered_node_i2c_out;
node_type_to_module(<<"binary">>)            -> ered_node_binary;
node_type_to_module(<<"sort">>)              -> ered_node_sort;
node_type_to_module(<<"batch">>)             -> ered_node_batch;
node_type_to_module(<<"rbe">>)               -> ered_node_rbe;
node_type_to_module(<<"range">>)             -> ered_node_range;
node_type_to_module(<<"erlprocess">>)        -> ered_node_erlprocess;
node_type_to_module(<<"erlcaptureio">>)      -> ered_node_erlcaptureio;

%% TODO: don't do this again! The kafka nodes are based on an existing
%% TODO: Node-RED node package --> @asinino/node-red-kafkajs that uses
%% TODO: different node types (node-red-kafkajs-XXX) which I mapped to
%% TODO: ered-kafka-XXX - that was a mistake. Because copying these nodes
%% TODO: between Node-RED and Erlang-Red now won't work. In fact it will
%% TODO: just break. Pity but the naming convention of 'node-red-kafkajs...'
%% TODO: isn't suited here.
node_type_to_module(<<"ered-kafka-consumer">>) -> ered_node_kafka_consumer;
node_type_to_module(<<"ered-kafka-producer">>) -> ered_node_kafka_producer;

%
% These are "frontend-only" nodes, they don't have any backend functionality.
node_type_to_module(<<"mermaid-state-start">>) -> ered_node_ignore;
node_type_to_module(<<"mermaid-state-end">>)   -> ered_node_ignore;
node_type_to_module(<<"mermaid-state-state">>) -> ered_node_ignore;
node_type_to_module(<<"mermaid-flowchart">>)   -> ered_node_ignore;
node_type_to_module(<<"Sink">>)                -> ered_node_ignore;
node_type_to_module(<<"Seeker">>)              -> ered_node_ignore;

%%
%% Assert nodes for testing functionality of the nodes. These are the first
%% Node-RED and Erlang-RED nodes - they have implmentations for both because
%% they confirm the compatiability between Node-RED and ErlangRED.
%%
node_type_to_module(<<"ut-assert-values">>)  -> ered_node_assert_values;
node_type_to_module(<<"ut-assert-failure">>) -> ered_node_assert_failure;
node_type_to_module(<<"ut-assert-success">>) -> ered_node_assert_success;
node_type_to_module(<<"ut-assert-status">>)  -> ered_node_assert_status;
node_type_to_module(<<"ut-assert-debug">>)   -> ered_node_assert_debug;
node_type_to_module(Unknown) ->
    case is_config_node(Unknown) of
        false ->
            io:format("noop node initiated for unknown type: ~p\n", [Unknown]),
            ered_node_noop;
        _ ->
            ered_node_ignore
    end.

%%
%% List of all known config nodes that need to be stored away before
%% a flow is executed
%% erlfmt:ignore alignment
is_config_node(<<"mqtt-broker">>)        -> true;
is_config_node(<<"tls-config">>)         -> true;
is_config_node(<<"FlowCompareCfg">>)     -> true;
is_config_node(<<"Flow2MermaidCfg">>)    -> true;
is_config_node(<<"FlowHubCfg">>)         -> true;
is_config_node(<<"ScratchPadCfg">>)      -> true;
is_config_node(<<"websocket-listener">>) -> true;
is_config_node(<<"erlconfigCfg">>)       -> true;
is_config_node(<<"ered-kafka-broker">>)  -> true;
is_config_node(_)                        -> false.

%%
%% this is also used by the supervisor node, hence the extra support.
is_supervisor(NodeDef) when is_map(NodeDef) ->
    is_supervisor(maps:get(<<"type">>, NodeDef));
is_supervisor(<<"erlsupervisor">>) ->
    true;
is_supervisor(_) ->
    false.

%%
%% module nodes are started before everything else as these define
%% code modules needed for the statemachine node (for example).
is_module_node(NodeDef) when is_map(NodeDef) ->
    is_module_node(maps:get(<<"type">>, NodeDef));
is_module_node(<<"erlmodule">>) ->
    true;
is_module_node(_) ->
    false.
