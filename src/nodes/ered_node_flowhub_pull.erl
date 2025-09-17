-module(ered_node_flowhub_pull).

-include("ered_nodes.hrl").
-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% FlowHub node is designed to retrieve flows for usage within a flow.
%%
%% In Erlang-RED, it additionally installs the flow when it receives a message.
%%
%% Also unlike the Node-RED variation, this node does not retrieve content
%% from anywhere else, its only locally (priv/testflows/.../) installed flows
%% that it retrieves - until this comment is removed.
%%

-import(ered_nodes, [
    jstr/1,
    jstr/2,
    send_msg_on/2
]).

-import(ered_messages, [
    to_bool/1
]).

-import(ered_nodered_comm, [
    post_exception_or_debug/3,
    ws_from/1
]).

%%
%%
start(NodeDef, _WsName) ->
    ered_node:start(NodeDef, ?MODULE).

%%
%%
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg(
    {incoming, Msg},
    #{<<"flowid">> := FlowId} = NodeDef
) when FlowId =/= <<>>, FlowId =/= "" ->
    handle_flowid(FlowId, Msg, NodeDef);
handle_msg(
    {incoming, #{<<"flowid">> := FlowId} = Msg},
    NodeDef
) when FlowId =/= <<>>, FlowId =/= "" ->
    handle_flowid(FlowId, Msg, NodeDef);
handle_msg(
    {incoming, Msg},
    NodeDef
) ->
    ErrMsg = jstr("Empty flowids not supported"),
    post_exception_or_debug(NodeDef, Msg, ErrMsg),
    {handled, NodeDef, Msg};
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% --------------------- helpers
%%

handle_flowid(FlowId, Msg, #{<<"wires">> := [WiresPort1 | _]} = NodeDef) ->
    FileName = io_lib:format(
        "~s/testflows/~s/flows.json",
        [code:priv_dir(erlang_red), FlowId]
    ),

    case file:read_file(FileName) of
        {ok, FileData} ->
            % node has two ports, therefore its wires attribute is:
            %   [ [WiresPort1], [WiresPort2] ]
            Msg2 = Msg#{?AddPayload(FileData)},
            send_msg_on(WiresPort1, Msg2),

            % should we install the flow?
            case to_bool(maps:get(<<"install_flow">>, Msg, false)) of
                true ->
                    Ary = ered_flows:parse_flow_file(FileName),
                    ered_startup:create_pids_for_nodes(Ary, ws_from(Msg));
                _ ->
                    ignore
            end,

            {handled, NodeDef, Msg2};
        _ ->
            ErrMsg = jstr("Flow id not found: ~p", [FlowId]),
            post_exception_or_debug(NodeDef, Msg, ErrMsg),
            {handled, NodeDef, Msg}
    end.
