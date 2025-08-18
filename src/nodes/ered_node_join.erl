-module(ered_node_join).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% join node is the companion of the split node that generates many messages
%% from a single message. The join node collects these together again and
%% sends them out as a single message.
%%
%% Possible attributes:
%%
%%       "mode": "custom",
%%       "build": "array",       <<---- send out as array, aka list
%%       "property": "",
%%       "propertyType": "full", <<---- collect the entire msg object
%%       "key": "topic",
%%       "joiner": "\\n",
%%       "joinerType": "str",
%%       "useparts": false,      <<---- parts is set by the split node
%%       "accumulate": false,
%%       "timeout": "",          <<---- wait this long after the first message before sending
%%       "count": "24",          <<---- wait for 24 messages before sending
%%       "reduceRight": false,
%%       "reduceExp": "",
%%       "reduceInit": "",
%%       "reduceInitType": "",
%%       "reduceFixup": "",
%%

-import(ered_nodes, [
    jstr/2,
    send_msg_to_connected_nodes/2
]).
-import(ered_nodered_comm, [
    node_status/5,
    unsupported/3
]).
-import(ered_message_exchange, [
    post_completed/2
]).
-import(ered_messages, [
    retrieve_prop_value/2
]).

%%
%%
start(#{<<"timeout">> := Timeout} = NodeDef, WsName) when Timeout =/= <<>> ->
    ErrMsg = jstr("Timeout ~p", [NodeDef]),
    unsupported(NodeDef, {websocket, WsName}, ErrMsg),
    ered_node:start(NodeDef, ered_node_ignore);
start(
    #{
        <<"mode">> := <<"custom">>,
        <<"build">> := <<"array">>,
        <<"count">> := Count,
        <<"useparts">> := true
    } = NodeDef,
    WsName
) ->
    case setup_custom(NodeDef) of
        {ok, NodeDef2} ->
            ered_node:start(
                NodeDef2#{
                    '_store' => [],
                    '_count' => convert_to_int(Count)
                },
                ered_node_join_useparts
            );
        {false, NodeDef2} ->
            ErrMsg = jstr("Node Config ~p", [NodeDef]),
            unsupported(NodeDef, {websocket, WsName}, ErrMsg),
            ered_node:start(NodeDef2, ered_node_ignore)
    end;
start(
    #{
        <<"mode">> := <<"custom">>,
        <<"build">> := <<"array">>,
        <<"count">> := Count,
        <<"useparts">> := false
    } = NodeDef,
    WsName
) ->
    case setup_custom(NodeDef) of
        {ok, NodeDef2} ->
            %% _store is defined by the registered event because we use
            %% an ETS table per process not per module.
            ered_node:start(
                NodeDef2#{
                    '_store' => undefined,
                    '_count' => convert_to_int(Count),
                    '_togo' => convert_to_int(Count)
                },
                ?MODULE
            );
        {false, NodeDef2} ->
            ErrMsg = jstr("Node Config ~p", [NodeDef]),
            unsupported(NodeDef, {websocket, WsName}, ErrMsg),
            ered_node:start(NodeDef2, ered_node_ignore)
    end;
%%
start(
    #{
        <<"mode">> := <<"auto">>
    } = NodeDef,
    WsName
) ->
    %% automatic is the same as custom mode with zero count, useparts set to
    %% true, creating an array and propety is payload on msg.
    start(
        NodeDef#{
            <<"mode">> => <<"custom">>,
            <<"build">> => <<"array">>,
            <<"count">> => <<"0">>,
            <<"useparts">> => true,
            <<"propertyType">> => <<"msg">>,
            <<"property">> => <<"payload">>
        },
        WsName
    );
start(NodeDef, WsName) ->
    ErrMsg = jstr("Node Config ~p", [NodeDef]),
    unsupported(NodeDef, {websocket, WsName}, ErrMsg),
    ered_node:start(NodeDef, ered_node_ignore).

%%
%%
handle_event({registered, _WsName, MyPid}, NodeDef) ->
    Tab = ets:new(
        list_to_atom(pid_to_list(MyPid)),
        [ordered_set, private, {write_concurrency, true}]
    ),
    NodeDef#{'_store' => Tab};
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg(
    {incoming, #{<<"complete">> := true} = Msg},
    #{
        '_store' := Store,
        '_togo' := ToGo
    } = NodeDef
) ->
    NewToGo = ToGo - 1,
    true = ets:insert(Store, {NewToGo, term_to_binary(Msg)}),
    Batch = ets:foldl(fun({_, M}, Acc) -> [M | Acc] end, [], Store),
    ets:delete_all_objects(Store),
    NodeDef2 = send_out_collected_messages(NodeDef, Msg, Batch),
    {handled, NodeDef2, dont_send_complete_msg};
handle_msg(
    {incoming, Msg},
    #{
        '_store' := Store,
        '_togo' := ToGo
    } = NodeDef
) ->
    NewToGo = ToGo - 1,
    true = ets:insert(Store, {NewToGo, term_to_binary(Msg)}),

    NodeDef2 =
        case NewToGo of
            0 ->
                Batch = ets:foldl(fun({_, M}, Acc) -> [M | Acc] end, [], Store),
                ets:delete_all_objects(Store),
                send_out_collected_messages(NodeDef, Msg, Batch);
            _ ->
                NodeDef#{'_togo' => NewToGo}
        end,

    {handled, NodeDef2, dont_send_complete_msg};
%%
%%
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%%
%% --------------- helpers

%%
%%
send_out_collected_messages(
    #{<<"propertyType">> := <<"full">>} = NodeDef,
    Msg,
    RevStore
) ->
    Store = [binary_to_term(M) || M <- RevStore],
    send_out_collected_messages(NodeDef, Msg, Store, Store);
send_out_collected_messages(
    #{<<"propertyType">> := <<"msg">>, <<"property">> := PropName} = NodeDef,
    Msg,
    RevStore
) ->
    Store = [binary_to_term(M) || M <- RevStore],
    Lst2 = [retrieve_prop_value(PropName, M) || M <- Store],
    send_out_collected_messages(NodeDef, Msg, Store, Lst2).

%%
send_out_collected_messages(
    #{'_count' := Count} = NodeDef, Msg, AllMsgs, PayloadForNodes
) ->
    %% retrieve the latest message and use that as a basis for sending out
    %% these messages - TODO perhaps this is wrong but will do for now.
    send_msg_to_connected_nodes(NodeDef, Msg#{?AddPayload(PayloadForNodes)}),

    %% now that we are ready to send out our message, we are completed
    %% with the message that make up that message (!!) so those
    %% messages should be sent to a complete node - if there is one
    %% See this post for details:
    %%   https://discourse.nodered.org/t/complete-node-msg-before-or-after-computation/96648/5
    [post_completed(NodeDef, M) || M <- AllMsgs],

    %% reset the store, ready to receive more messages
    NodeDef#{'_togo' => Count}.

%%
%%
convert_to_int(Val) when is_integer(Val) ->
    Val;
convert_to_int(Val) when is_float(Val) ->
    erlang:element(1, string:to_integer(io_lib:format("~p", [Val])));
convert_to_int(Val) ->
    case string:to_float(Val) of
        {error, _} ->
            case string:to_integer(Val) of
                {error, _} ->
                    -1;
                {V, _} ->
                    V
            end;
        {V, _} ->
            %% V is now a float and the guard 'is_float' will catch it now
            convert_to_int(V)
    end.

%%
%%
setup_custom(
    #{<<"propertyType">> := PropType, <<"useparts">> := UseParts} = NodeDef
) when
    (PropType =:= <<"full">> orelse PropType =:= <<"msg">>) andalso
        (UseParts =:= true orelse UseParts =:= false)
->
    {ok, NodeDef};
setup_custom(NodeDef) ->
    {false, NodeDef}.
