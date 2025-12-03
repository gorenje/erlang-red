-module(ered_node_elxmodule).

-behaviour(ered_node).

-include("ered_nodes.hrl").

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

-export([install/2]).

%%
%% Erlang-Red Elixir module node for defining modules in Elixir
%%
%% This does not nothing except for install code into the BEAM.
%%
%% The install process isn't managed by the node, instead the startup
%% procedure does the installation. That is because there has to be an
%% order maintained in how things happen. Another node wanting to use this
%% code must have that code already installed.
%%

-import(ered_nodered_comm, [
    node_status/5,
    node_status_clear/2,
    post_exception_or_debug/3,
    send_out_debug_warning/2
]).

-import(ered_erlmodule_exchange, [
    remove_module_for_nodeid/1,
    add_module/2
]).

%%
%%
start(
    #{<<"module_name">> := ModuleName} = NodeDef,
    WsName
) when ModuleName =:= <<>>; ModuleName =:= "" ->
    node_status(
        WsName,
        NodeDef,
        "module name not defined",
        "red",
        "dot"
    ),
    ered_node:start(NodeDef, ered_node_ignore);
start(NodeDef, _WsName) ->
    ered_node:start(NodeDef, ?MODULE).

%%
%%
handle_event(?StopEvent, #{<<"id">> := NodeId} = NodeDef) ->
    remove_module_for_nodeid(NodeId),
    NodeDef;
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%%
install(
    #{
        <<"module_name">> := ModBinaryName,
        <<"code">> := ModuleCode,
        <<"id">> := NodeId
    } = NodeDef,
    WsName
) when ModBinaryName =/= <<>>, ModBinaryName =/= "" ->
    ModuleName = binary_to_atom(ModBinaryName),

    FileName = binary_to_list(
        list_to_binary(
            io_lib:format("/tmp/~s.ex", [ModuleName])
        )
    ),

    file:write_file(FileName, ModuleCode),

    try
        case 'Elixir.Code':compile_file(list_to_binary(FileName), nil) of
            [] ->
                node_status(WsName, NodeDef, "no code found", "blue", "dot");
            [{FullModuleName, _Binary}] ->
                add_module(NodeId, FullModuleName),
                node_status(WsName, NodeDef, "installed", "green", "dot"),
                spawn(fun() -> clear_status_after_one_sec(WsName, NodeDef) end);
            R ->
                post_exception_or_debug(
                    NodeDef,
                    ?AddWsName(#{somethingelse => R}),
                    "something else"
                ),
                node_status(WsName, NodeDef, "something else", "blue", "ring")
        end
    catch
        E:F:S ->
            node_status(WsName, NodeDef, "compile failed", "red", "dot"),
            post_exception_or_debug(
                NodeDef,
                ?AddWsName(#{exception => E, error => F, stacktrace => S}),
                "compile failed"
            )
    end;
install(_NodeDef, _WsName) ->
    ignore.

%%
%%
clear_status_after_one_sec(WsName, NodeDef) ->
    timer:sleep(1000),
    node_status_clear(WsName, NodeDef).
