-module(ered_nodes).

%%
%% External exports, should be used by others.
%%
-export([
    create_outgoing_msg/1,
    create_pid_for_node/2,
    get_prop_value_from_map/2,
    get_prop_value_from_map/3,
    generate_id/0,
    generate_id/1,
    jstr/2,
    jstr/1,
    nodeid_to_pid/2,
    node_init/1,
    post_exception/3,
    tabid_to_error_collector/1,
    this_should_not_happen/2,
    trigger_outgoing_messages/3,
    unpriv/1
]).

%% send_msg_to_connnected_nodes assues an attribute 'wires' while
%% send send_msg_on is given an array of node ids and triggers the
%% 'incoming' message to be sent
-export([
    send_msg_on/2,
    send_msg_to_connected_nodes/2
]).

-import(ered_nodered_comm, [
    ws_from/1
]).

%%
%% Map priv directory in file names
unpriv(FileName) when is_binary(FileName) ->
    unpriv(binary_to_list(FileName));
unpriv(FileName) when is_list(FileName) ->
    string:replace(FileName, "${priv}", code:priv_dir(erlang_red), all);
unpriv(FileName) ->
    %% Let it fail.
    FileName.

%%
%% Common functionality
%%
jstr(Fmt, Args) ->
    list_to_binary(lists:flatten(io_lib:format(Fmt, Args))).

jstr(Str) when is_binary(Str) ->
    Str;
jstr(Str) when is_atom(Str) ->
    atom_to_binary(Str);
jstr(Str) ->
    list_to_binary(lists:flatten(Str)).

%%
%%
this_should_not_happen(NodeDef, Arg) ->
    {ok, TabId} = maps:find(z, NodeDef),
    ErrCollector = tabid_to_error_collector(TabId),

    case whereis(ErrCollector) of
        undefined ->
            io:format("TSNH: ~s\n", [Arg]);
        _ ->
            {ok, IdStr} = maps:find(id, NodeDef),
            {ok, ZStr} = maps:find(z, NodeDef),
            ErrCollector ! {it_happened, {IdStr, ZStr}, Arg}
    end.

%%
%%
generate_id(Length) ->
    IntLen = erlang:list_to_integer(
        erlang:float_to_list(Length / 2, [{decimals, 0}])
    ),
    string:lowercase(
        list_to_binary(
            [
                io_lib:format(
                    "~2.16.0B",
                    [X]
                )
             || <<X>> <= crypto:strong_rand_bytes(IntLen)
            ]
        )
    ).

%% generate an id in a form that is conform with NodeRED ids: 16 hexadecimal.
generate_id() ->
    generate_id(16).

%% processes for nodes are scoped by the websocket name so that each
%% each websocket connection gets its own collection of processes for nodes.
nodeid_to_pid(WsName, IdStr) ->
    binary_to_atom(
        list_to_binary(
            lists:flatten(
                io_lib:format("~s~s~s~s", [
                    "node_pid_", jstr(WsName), "_", IdStr
                ])
            )
        )
    ).

tabid_to_error_collector(IdStr) ->
    binary_to_atom(
        list_to_binary(
            lists:flatten(
                io_lib:format("~s~s", ["error_collector_", IdStr])
            )
        )
    ).

%%
%% Generate a group name for the pg module to group together all catch
%% nodes on one flow.
pg_catch_group_name(NodeDef) ->
    {ok, FlowId} = maps:find(z, NodeDef),
    jstr("catch_nodes_~s", [FlowId]).

%%
%% Called by a node before it enters receivership. Does not much but
%% might later on, original it dumped some debug to the console.
node_init(_NodeDef) ->
    ok.

%% TODO: a tab node (i.e. the tab containing a flow) also has a disabled
%% TODO: flag but this is called 'disabled'. If it is set, then the entire
%% TODO: flow should be ignoreed --> this is not handled at the moment.
%%
%% TODO2: Append the websocket name to the pid so that two browsers
%% TODO2: don't test with the same set of nodes. Each node is given the
%% TODO2: websocket name in the Msg object, so its not a problem for them
%% TODO2: to send their messages to the correct processes.
create_pid_for_node(Ary, WsName) ->
    create_pid_for_node(Ary, [], WsName).

%% erlfmt:ignore equals and arrows should line up here.
create_pid_for_node([], Pids, _WsName) ->
    Pids;
create_pid_for_node([NodeDef | MoreNodeDefs], Pids, WsName) ->
    {ok, IdStr} = maps:find(id, NodeDef),
    {ok, TypeStr} = maps:find(type, NodeDef),

    %% here have to respect the 'd' (disabled) attribute. if true, then
    %% the node does not need to have a Pid created for it.
    {Module, Fun} = node_type_to_fun(TypeStr, disabled(NodeDef)),

    NodePid = nodeid_to_pid(WsName, IdStr),

    case whereis(NodePid) of
        undefined ->
            ok;
        _ ->
            NodePid ! stop,
            unregister(NodePid)
    end,

    %% internal message counters, get updated automagically in
    %% enter_receivership ==> 'mc' is message counter.
    NodeDef2 = maps:put('_mc_incoming',    0, NodeDef),
    NodeDef3 = maps:put('_mc_link_return', 0, NodeDef2),
    NodeDef4 = maps:put('_mc_websocket',   0, NodeDef3),
    NodeDef5 = maps:put('_mc_outgoing',    0, NodeDef4),
    NodeDef6 = maps:put('_mc_exception',   0, NodeDef5),

    NodeDef7 = maps:put('_node_pid_', NodePid, NodeDef6),

    FinalNodeDef = NodeDef7,

    Pid = spawn(Module, Fun, [FinalNodeDef, WsName]),
    register(NodePid, Pid),

    %% Post spawn activities. Important one is the catch node to the pg group
    %% because any exceptions caused by nodes needs dealing with.
    %% Also need to reprsent the disabled flags extra here - the catch node
    %% here is actually a disabled node but it's configuration is still
    %% that of a catch node for example.
    {ok, NodeType} = maps:find(type, FinalNodeDef),
    case {disabled(FinalNodeDef), NodeType} of
        {false, <<"catch">>} ->
            %% register the catch node as being responsible for z value
            %% beware multiple catch nodes can be included in a flow so the
            %% z value won't be unique
            pg:join(pg_catch_group_name(FinalNodeDef), Pid);
        {false, <<"ut-assert-status">>} ->
            {ok, TgtNodeId} = maps:find(nodeid, FinalNodeDef),
            ered_ws_event_exchange:subscribe(
                WsName, TgtNodeId, status, NodePid
            );
        {false, <<"ut-assert-debug">>} ->
            {ok, TgtNodeId} = maps:find(nodeid, FinalNodeDef),
            {ok, MsgType} = maps:find(msgtype, FinalNodeDef),
            %%
            %% inverse means that there should be **no** debug message, this
            %% means that this node needs to subscribe too all types of debug
            %% messages.
            case maps:find(inverse, NodeDef) of
                {ok, true} ->
                    ered_ws_event_exchange:subscribe(
                      WsName,
                      TgtNodeId,
                      debug,
                      any,

                      NodePid
                     );
                _ ->
                    ered_ws_event_exchange:subscribe(
                      WsName,
                      TgtNodeId,
                      debug,
                      MsgType,
                      NodePid
                     )
            end;
        _ ->
            ignore
    end,

    %% io:format("~p ~p\n",[Pid,NodePid]),
    create_pid_for_node(MoreNodeDefs, [NodePid | Pids], WsName).

%%
%% tab node usses 'disabled', everything else 'd'.
disabled(NodeDef) ->
    case maps:find(d, NodeDef) of
        {ok, V} ->
            V;
        _ ->
            case maps:find(disabled, NodeDef) of
                {ok, V} ->
                    V;
                _ ->
                    false
            end
    end.

%%
%% Post exception passes errors to the catch nodes, if any are defined.
%% It also provides feed back to the caller as to whether there was a
%% catch node or not, if not, deal with it yourself is the message.
%%
post_exception(SrcNode, SrcMsg, ErrMsg) ->
    case pg:get_members(pg_catch_group_name(SrcNode)) of
        [] ->
            deal_with_it_yourself;
        Members ->
            [M ! {exception, SrcNode, SrcMsg, ErrMsg} || M <- Members],
            dealt_with
    end.

%%
%% The wires attribute is an array of arrays. The toplevel
%% array has one entry per port that a node has. (Port being the connectors
%% from which wires leave the node.)
%% If a node only has one port, then wires will be an array containing
%% exactly one array. This is the [Val] case and is the most common case.
%%
send_msg_to_connected_nodes(NodeDef, Msg) ->
    case maps:find(wires, NodeDef) of
        {ok, [Val]} ->
            send_msg_on(Val, Msg);
        {ok, Val} ->
            send_msg_on(Val, Msg)
    end.

%%
%% Avoid having to create the same case all the time.
%%
get_prop_value_from_map(Prop, Map, Default) ->
    case maps:find(Prop, Map) of
        {ok, Val} ->
            case Val of
                <<"">> -> Default;
                "" -> Default;
                _ -> Val
            end;
        _ ->
            Default
    end.

get_prop_value_from_map(Prop, Map) ->
    get_prop_value_from_map(Prop, Map, "").

%%
%% Helper for passing on messages once a node has completed with the message
%%

%% Here 'on' is the same 'pass on' not as in 'on & off'. Standing on the
%% shoulders of great people is also not the same 'on' as here.
send_msg_on([], _) ->
    ok;
send_msg_on([NodeId | Wires], Msg) ->
    NodePid = nodeid_to_pid(ws_from(Msg), NodeId),

    case whereis(NodePid) of
        undefined ->
            ok;
        _ ->
            NodePid ! {incoming, Msg}
    end,
    send_msg_on(Wires, Msg).

%%
%% Lookup table for mapping node type to function. Also here we respect the
%% disabled flag: if node is disabled, give it a noop node else continue
%% on checking by type.
%%
node_type_to_fun(_Type, true) ->
    io:format("node disabled, ignoring\n"),
    {ered_node_disabled, node_disabled};
node_type_to_fun(Type, _) ->
    node_type_to_fun(Type).

node_type_to_fun(<<"inject">>) ->
    {ered_node_inject, node_inject};
node_type_to_fun(<<"switch">>) ->
    {ered_node_switch, node_switch};
node_type_to_fun(<<"debug">>) ->
    {ered_node_debug, node_debug};
node_type_to_fun(<<"junction">>) ->
    {ered_node_junction, node_junction};
node_type_to_fun(<<"change">>) ->
    {ered_node_change, node_change};
node_type_to_fun(<<"link out">>) ->
    {ered_node_link_out, node_link_out};
node_type_to_fun(<<"link in">>) ->
    {ered_node_link_in, node_link_in};
node_type_to_fun(<<"link call">>) ->
    {ered_node_link_call, node_link_call};
node_type_to_fun(<<"delay">>) ->
    {ered_node_delay, node_delay};
node_type_to_fun(<<"file in">>) ->
    {ered_node_file_in, node_file_in};
node_type_to_fun(<<"json">>) ->
    {ered_node_json, node_json};
node_type_to_fun(<<"template">>) ->
    {ered_node_template, node_template};
node_type_to_fun(<<"join">>) ->
    {ered_node_join, node_join};
node_type_to_fun(<<"split">>) ->
    {ered_node_split, node_split};
node_type_to_fun(<<"catch">>) ->
    {ered_node_catch, node_catch};
%%
%% Assert nodes for testing functionality of the nodes
%%
node_type_to_fun(<<"ut-assert-values">>) ->
    {ered_node_assert_values, node_assert_values};
node_type_to_fun(<<"ut-assert-failure">>) ->
    {ered_node_assert_failure, node_assert_failure};
node_type_to_fun(<<"ut-assert-success">>) ->
    {ered_node_assert_success, node_assert_success};
node_type_to_fun(<<"ut-assert-status">>) ->
    {ered_node_assert_status, node_assert_status};
node_type_to_fun(<<"ut-assert-debug">>) ->
    {ered_node_assert_debug, node_assert_debug};
node_type_to_fun(Unknown) ->
    io:format("noop node initiated for unknown type: ~p\n", [Unknown]),
    {ered_node_noop, node_noop}.

%%
%%
create_outgoing_msg(WsName) ->
    {outgoing, #{'_msgid' => generate_id(), '_ws' => WsName}}.

%% A list of all nodes that support outgoing messages, this was originally
%% only the inject node but then I realised that for testing purposes there
%% are in fact more.
trigger_outgoing_messages({ok, <<"http in">>}, {ok, IdStr}, WsName) ->
    nodeid_to_pid(WsName, IdStr) ! create_outgoing_msg(WsName);
trigger_outgoing_messages({ok, <<"inject">>}, {ok, IdStr}, WsName) ->
    nodeid_to_pid(WsName, IdStr) ! create_outgoing_msg(WsName);
trigger_outgoing_messages(_, _, _) ->
    ok.
