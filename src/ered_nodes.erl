-module(ered_nodes).

-include("ered_nodes.hrl").

-export([
    check_config/4,
    check_node_config/3,
    get_node_name/2,
    get_prop_value_from_map/2,
    get_prop_value_from_map/3,
    generate_id/0,
    generate_id/1,
    jstr/2,
    jstr/1,
    nodeid_to_pid/2,

    %% send_msg_to_connnected_nodes assues an attribute 'wires' while
    %% send send_msg_on is given an array of node ids and triggers the
    %% 'incoming' message to be sent
    send_msg_on/2,
    send_msg_on_by_pids/2,
    send_msg_to_connected_nodes/2,

    tabid_to_error_collector/1,
    this_should_not_happen/2,
    trigger_outgoing_messages/3,
    unpriv/1,

    within_range/3
]).

%%
%% Module provides help for the nodes doing the work. Just a collection
%% of helper functionality that may or may not be used.
%%

-import(ered_nodered_comm, [
    unsupported/3,
    ws_from/1
]).
-import(ered_messages, [
    create_outgoing_msg/1
]).

%%
%% Given a range, From - To, is a given value within that range?
%%
within_range(From, To, Value) when
    From =:= Value;
    To =:= Value;
    From < To, Value > From, Value < To;
    From > To, Value < From, Value > To
->
    true;
within_range(_, _, _) ->
    false.

%%
%% Ensure a nodes configuration is supported. This is usually used in the
%% start(..) function of a node module. If a configuration is not supported,
%% the node is replaced by an ignore node.

check_node_config([{Property, SupportedValue} | Rest], NodeDef, WsName) ->
    check_node_config(
        Rest,
        NodeDef,
        WsName,
        check_config(Property, SupportedValue, NodeDef, WsName)
    ).

check_node_config([], _NodeDef, _WsName, RVale) ->
    RVale;
check_node_config([{Property, SupportedValue} | Rest], NodeDef, WsName, ok) ->
    check_node_config(
        Rest,
        NodeDef,
        WsName,
        check_config(Property, SupportedValue, NodeDef, WsName)
    );
check_node_config(
    [{Property, SupportedValue} | Rest], NodeDef, WsName, false
) ->
    check_config(Property, SupportedValue, NodeDef, WsName),
    check_node_config(Rest, NodeDef, WsName, false).

%%
%%
check_config(ParaName, OnlySupportedValue, NodeDef, WsName) ->
    case maps:get(ParaName, NodeDef) of
        OnlySupportedValue ->
            ok;
        Unsupported ->
            ErrMsg = jstr(
                "config: attr: ~s => value: ~s",
                [ParaName, Unsupported]
            ),
            unsupported(NodeDef, {websocket, WsName}, ErrMsg),
            false
    end.

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
    {ok, TabId} = maps:find(<<"z">>, NodeDef),
    ErrCollector = tabid_to_error_collector(TabId),

    case whereis(ErrCollector) of
        undefined ->
            io:format("TSNH: ~s\n", [Arg]);
        _ ->
            {ok, IdStr} = maps:find(<<"id">>, NodeDef),
            {ok, ZStr} = maps:find(<<"z">>, NodeDef),
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
get_node_name(WsName, IdStr) ->
    list_to_binary(
        lists:flatten(
            io_lib:format("~s~s~s~s", [
                "node_pid_", jstr(WsName), "_", IdStr
            ])
        )
    ).

nodeid_to_pid(WsName, IdStr) ->
    Name = get_node_name(WsName, IdStr),
    case pg:get_members(Name) of
        [] ->
            {error, undefined};
        [Pid | []] ->
            {ok, Pid};
        [_H | _T] ->
            io:format("Multiple PIDs for node name ~p~n", [Name]),
            {error, too_many}
    end.

tabid_to_error_collector(IdStr) ->
    binary_to_atom(
        list_to_binary(
            lists:flatten(
                io_lib:format("~s~s", ["error_collector_", IdStr])
            )
        )
    ).

%%
%% The wires attribute is an array of arrays. The toplevel
%% array has one entry per port that a node has. (Port being the connectors
%% from which wires leave the node.)
%% If a node only has one port, then wires will be an array containing
%% exactly one array. This is the [Val] case and is the most common case.
%%
send_msg_to_connected_nodes(NodeDef, Msg) ->
    case maps:find(<<"wires">>, NodeDef) of
        {ok, [Val]} ->
            send_msg_on(Val, Msg);
        {ok, Val} ->
            send_msg_on(Val, Msg)
    end.

%%
%% Avoid having to create the same case all the time.
%%
get_prop_value_from_map(Prop, Map, Default) when is_atom(Prop) ->
    get_prop_value_from_map(atom_to_binary(Prop), Map, Default);
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

    case NodePid of
        {error, _} ->
            ignore;
        {ok, Pid} ->
            gen_server:cast(Pid, {incoming, Msg})
    end,
    send_msg_on(Wires, Msg).

%%
%%
send_msg_on_by_pids([], _) ->
    ok;
send_msg_on_by_pids([Pid | Wires], Msg) ->
    gen_server:cast(Pid, {incoming, Msg}),
    send_msg_on_by_pids(Wires, Msg).

%% A list of all nodes that support outgoing messages, this was originally
%% only the inject node but then I realised that for testing purposes there
%% are in fact more.
trigger_outgoing_messages(<<"inject">>, IdStr, WsName) ->
    case nodeid_to_pid(WsName, IdStr) of
        {ok, Pid} ->
            gen_server:cast(Pid, create_outgoing_msg(WsName));
        {error, _} ->
            ignore
    end;
trigger_outgoing_messages(_, _, _) ->
    ok.
