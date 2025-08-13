-module(ered_node_sort).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Basic sort node for sorting a list of messages based on their sequence.
%%
%% {
%%     "id": "3c70b3f97b8d63a0",
%%     "type": "sort",
%%     "z": "5f6929bb3374b782",
%%     "name": "",
%%     "order": "ascending",
%%     "as_num": true,
%%     "target": "",
%%     "targetType": "seq", <<<---- use parts.index to sort the mesages
%%     "msgKey": "payload",
%%     "msgKeyType": "elem",
%%     "seqKey": "$$.parts.index", <<<--- ensure that it's really used
%%     "seqKeyType": "jsonata",
%%     "x": 936,
%%     "y": 627,
%%     "wires": [
%%         [
%%             "121ca5dc5bd3ccbc"
%%         ]
%%     ]
%% }
%%
%% See https://discourse.nodered.org/t/sort-node-broken/98592 but I suspect
%% that there is something fishy about the sort node - at least it didn't do
%% what I expected but this configuration is a workaround that works for me,
%%
%%

-import(ered_nodes, [
    send_msg_to_connected_nodes/2
]).

-import(ered_messages, [
    create_outgoing_msg/1,
    get_prop/2
]).

-import(ered_nodered_comm, [
    unsupported/3
]).

start(NodeDef, _WsName) ->
    ered_node:start(NodeDef#{'_store' => []}, ?MODULE).

%%
%%
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg(
    {incoming, Msg},
    #{
        <<"targetType">> := <<"seq">>,
        '_store' := Store
    } = NodeDef
) ->
    {handled, NodeDef#{'_store' => is_store_complete(NodeDef, [Msg | Store])},
        dont_send_complete_msg};
%%
handle_msg(
    {incoming, Msg},
    #{
        <<"targetType">> := <<"msg">>,
        <<"target">> := PropName
    } = NodeDef
) ->
    sort_and_send_if_list(get_prop(PropName, Msg), Msg, NodeDef),
    {handled, NodeDef, dont_send_complete_msg};
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% ---------------- Helpers
%%

%%
%%
is_store_complete(
    #{
        <<"seqKeyType">> := <<"jsonata">>,
        <<"seqKey">> := JsonAtaStr
    } = NodeDef,
    [#{<<"parts">> := #{<<"count">> := Count}} | _] = Store
) when Count =:= length(Store) ->
    SortFun =
        fun(Msg1, Msg2) ->
            sort_by_elem(
                erlang_red_jsonata:execute(JsonAtaStr, Msg1),
                erlang_red_jsonata:execute(JsonAtaStr, Msg2)
            )
        end,
    send_sorted_individual_messages(NodeDef, lists:sort(SortFun, Store)),
    [];
is_store_complete(
    #{
        <<"seqKeyType">> := <<"msg">>,
        <<"seqKey">> := PropName
    } = NodeDef,
    [#{<<"parts">> := #{<<"count">> := Count}} | _] = Store
) when Count =:= length(Store) ->
    SortFun =
        fun(Msg1, Msg2) ->
            sort_by_elem(get_prop(PropName, Msg1), get_prop(PropName, Msg2))
        end,
    send_sorted_individual_messages(NodeDef, lists:sort(SortFun, Store)),
    [];
is_store_complete(_NodeDef, Store) ->
    Store.

%%
%%
sort_and_send_if_list(
    {ok, Value, _},
    Msg,
    #{
        <<"msgKeyType">> := <<"jsonata">>,
        <<"msgKey">> := Str
    } = NodeDef
) when is_list(Value) ->
    SortFun =
        fun(Msg1, Msg2) ->
            sort_by_elem(
                erlang_red_jsonata:execute(Str, Msg1),
                erlang_red_jsonata:execute(Str, Msg2)
            )
        end,
    send_sorted(NodeDef, Msg, lists:sort(SortFun, Value));
sort_and_send_if_list(
    {ok, Value, _},
    Msg,
    #{
        <<"msgKeyType">> := <<"elem">>,
        <<"target">> := PropName
    } = NodeDef
) when is_list(Value) ->
    SortFun =
        fun(Msg1, Msg2) ->
            sort_by_elem(get_prop(PropName, Msg1), get_prop(PropName, Msg2))
        end,
    send_sorted(NodeDef, Msg, lists:sort(SortFun, Value));
sort_and_send_if_list(_, _, _) ->
    ok.

%%
%%

send_sorted_individual_messages(
    #{<<"order">> := <<"ascending">>} = NodeDef, Lst
) ->
    [send_msg_to_connected_nodes(NodeDef, Msg) || Msg <- Lst];
send_sorted_individual_messages(NodeDef, Lst) ->
    [send_msg_to_connected_nodes(NodeDef, Msg) || Msg <- lists:reverse(Lst)].

%%
%%
send_sorted(#{<<"order">> := <<"ascending">>} = NodeDef, Msg, Lst) ->
    send_msg_to_connected_nodes(NodeDef, Msg#{?AddPayload(Lst)});
send_sorted(NodeDef, Msg, Lst) ->
    send_msg_to_connected_nodes(NodeDef, Msg#{?AddPayload(lists:reverse(Lst))}).
%%
%%
sort_by_elem({ok, V1}, {ok, V2}) ->
    V2 > V1;
sort_by_elem({ok, V1, _}, {ok, V2, _}) ->
    V2 > V1;
sort_by_elem(_, _) ->
    true.
