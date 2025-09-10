-module(ered_node_rbe).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Report by exception (filter) node. Reports on messages that are exceptional.
%%
%%    "type": "rbe",
%%    "z": "f19fdae0c02b4f03",
%%    "name": "",
%%    "func": "rbe", <<<---- block unless value changes
%%    "gap": "",  <<--- percent/number difference between current value and last value
%%    "start": "",  <<---- possible start value or initial message
%%    "inout": "out",   <<---- compare to the last input or output value?
%%    "septopics": true,  <<<---- group by topic or "topi" property
%%    "property": "payload",
%%    "topi": "topic",
%%

-import(ered_nodes, [
    jstr/2
]).
-import(ered_nodered_comm, [
    unsupported/3
]).

-define(GroupByTopic, <<"septopics">> := true).
-define(NoGrouping, <<"septopics">> := false).

start(NodeDef, WsName) ->
    ModName =
        case NodeDef of
            #{<<"func">> := <<"rbe">>, ?NoGrouping} ->
                ered_node_rbe_mode_rbe_no_topic;
            #{<<"func">> := <<"rbe">>, ?GroupByTopic} ->
                ered_node_rbe_mode_rbe_topic;
            #{<<"func">> := <<"rbei">>, ?NoGrouping} ->
                ered_node_rbe_mode_rbei_no_topic;
            #{<<"func">> := <<"rbei">>, ?GroupByTopic} ->
                ered_node_rbe_mode_rbei_topic;
            #{<<"func">> := <<"narrowbandEq">>, <<"gap">> := <<>>} ->
                %% Without a valid gap value, the node is valid but does nothing.
                ered_node_sink;
            #{<<"func">> := <<"narrowbandEq">>, ?NoGrouping} ->
                ered_node_rbe_mode_narrowbandeq;
            _ ->
                ErrMsg = jstr("Node Config ~p", [NodeDef]),
                unsupported(NodeDef, {websocket, WsName}, ErrMsg),
                ered_node_ignore
        end,
    ered_node:start(NodeDef, ModName).

%%
%%
handle_event(_, NodeDef) ->
    NodeDef.

%%
%% fall through
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.
