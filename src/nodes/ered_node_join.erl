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
        <<"count">> := Count
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
                ?MODULE
            );
        {false, NodeDef2} ->
            ErrMsg = jstr("Node Config ~p", [NodeDef]),
            unsupported(NodeDef, {websocket, WsName}, ErrMsg),
            ered_node:start(NodeDef2, ered_node_ignore)
    end;
start(
    #{
        <<"mode">> := <<"auto">>
    } = NodeDef,
    WsName
) ->
    %% automatic is the same as custom mode with zero count, useparts set to
    %% true, creating an array and propety is payload on msg.
    start(NodeDef#{
        <<"mode">> => <<"custom">>,
        <<"build">> => <<"array">>,
        <<"count">> => <<"0">>,
        <<"useparts">> => true,
        <<"propertyType">> => <<"msg">>,
        <<"property">> => <<"payload">>
    }, WsName);
start(NodeDef, WsName) ->
    ErrMsg = jstr("Node Config ~p", [NodeDef]),
    unsupported(NodeDef, {websocket, WsName}, ErrMsg),
    ered_node:start(NodeDef, ered_node_ignore).

%%
%%
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg(
    {incoming, #{<<"complete">> := true} = Msg},
    #{
        '_store' := Store,
        <<"useparts">> := false
    } = NodeDef
) ->
    NodeDef2 = send_out_collected_messages(NodeDef, [Msg | Store]),
    {handled, NodeDef2, dont_send_complete_msg};
handle_msg(
    {incoming,
        #{
            <<"complete">> := true,
            <<"parts">> := #{<<"id">> := IdStr}
        } = Msg},
    #{
        '_store' := Store,
        <<"useparts">> := true
    } = NodeDef
) ->
    {WithId, WithoutId} = divide_and_conquer(IdStr, [Msg | Store]),

    send_out_collected_messages(NodeDef, lists:reverse(WithId)),

    {handled, NodeDef#{'_store' => WithoutId}, dont_send_complete_msg};
handle_msg(
    {incoming, #{<<"complete">> := true} = Msg},
    #{
        '_store' := Store,
        '_count' := Count,
        <<"useparts">> := true
    } = NodeDef
) when Count =< 0 ->
    {WithId, WithoutId} = divide_and_conquer_no_idstr([Msg | Store]),

    send_out_collected_messages(NodeDef, lists:reverse(WithoutId)),

    {handled, NodeDef#{'_store' => WithId}, dont_send_complete_msg};
handle_msg(
    {incoming, #{<<"complete">> := true} = Msg},
    #{
        '_store' := Store,
        '_count' := Count,
        <<"useparts">> := true
    } = NodeDef
) when Count > 0 ->
    NodeDef2 = send_out_collected_messages(NodeDef, [Msg | Store]),
    {handled, NodeDef2, dont_send_complete_msg};
handle_msg(
    {incoming, Msg},
    #{
        '_store' := Store,
        '_count' := Count,
        <<"useparts">> := true
    } = NodeDef
) when Count =< 0 ->
    %% No count set, but using parts - so we have to check whether all parts
    %% have arrived, if so then send out the parts/messages. If not, it's
    %% back to the daily grind.
    NodeDef2 = have_all_parts_arrived(NodeDef, [Msg | Store]),
    {handled, NodeDef2, dont_send_complete_msg};
handle_msg(
    {incoming, Msg},
    #{
        '_store' := Store,
        '_count' := Count
    } = NodeDef
) when Count > 0, length(Store) =:= (Count - 1) ->
    NodeDef2 = send_out_collected_messages(NodeDef, [Msg | Store]),
    {handled, NodeDef2, dont_send_complete_msg};
%%
%% If we make it here, then just store the message and move on.
handle_msg(
    {incoming, Msg},
    #{
        '_store' := Store
    } = NodeDef
) ->
    {handled, NodeDef#{'_store' => [Msg | Store]}, dont_send_complete_msg};
%%
%%
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%%
%% --------------- helpers

%%
%%
have_all_parts_arrived(
    NodeDef,
    [#{<<"parts">> := #{<<"count">> := Count}} | _] = AllMsgs
) ->
    have_all_parts_arrived(
        NodeDef,
        AllMsgs,
        length(AllMsgs) =:= convert_to_int(Count)
    );
have_all_parts_arrived(#{'_store' := Store} = NodeDef, [LastMsg | _]) ->
    NodeDef#{'_store' => [LastMsg | Store]}.
%%
have_all_parts_arrived(#{'_store' := Store} = NodeDef, [LastMsg | _], false) ->
    NodeDef#{'_store' => [LastMsg | Store]};
have_all_parts_arrived(NodeDef, AllMsgs, true) ->
    send_out_collected_messages(NodeDef, AllMsgs).

%%
%%
send_out_collected_messages(
    #{<<"propertyType">> := <<"full">>} = NodeDef,
    Store
) ->
    AllMsgs = sort_messages(NodeDef, Store),
    send_out_collected_messages(NodeDef, AllMsgs, AllMsgs);
send_out_collected_messages(
    #{<<"propertyType">> := <<"msg">>, <<"property">> := PropName} = NodeDef,
    Store
) ->
    AllMsgs = sort_messages(NodeDef, Store),
    Lst2 = [retrieve_prop_value(PropName, Msg) || Msg <- AllMsgs],
    send_out_collected_messages(NodeDef, AllMsgs, Lst2).

%%
send_out_collected_messages(NodeDef, AllMsgs, PayloadForNodes) ->
    %% now that we are ready to send out our message, we are completed
    %% with the message that make up that message (!!) so those
    %% messages should be sent to a complete node - if there is one
    %% See this post for details:
    %%   https://discourse.nodered.org/t/complete-node-msg-before-or-after-computation/96648/5
    [post_completed(NodeDef, M) || M <- AllMsgs],

    %% retrieve the latest message and use that as a basis for sending out
    %% these messages - TODO perhaps this is wrong but will do for now.
    [Msg | _] = lists:reverse(AllMsgs),
    send_msg_to_connected_nodes(NodeDef, Msg#{?AddPayload(PayloadForNodes)}),

    %% reset the store, ready to receive more messages
    NodeDef#{'_store' => []}.

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

%%
%%
%% parts_sort_funct( #{ <<"parts">> := #{ <<"index">> := IndxA } },
%%                   #{ <<"parts">> := #{ <<"index">> := IndxB } } ) ->
%%     convert_to_int(IndxA) < convert_to_int(IndxB);
%% parts_sort_funct(_,_) ->
%%     true.

sort_messages(#{<<"useparts">> := true}, AllMsgs) ->
    lists:reverse(AllMsgs);
%% see test #5cf6aec7d688fce4 but ordering is by receivership not index.
%% lists:sort(fun parts_sort_funct/2, AllMsgs);
sort_messages(#{<<"useparts">> := false}, AllMsgs) ->
    lists:reverse(AllMsgs).

%%
%%
divide_and_conquer(IdStr, Store) ->
    divide_and_conquer(IdStr, Store, [], []).

divide_and_conquer(_IdStr, [], AccWithId, AccNotId) ->
    {AccWithId, AccNotId};
divide_and_conquer(
    IdStr,
    [#{<<"parts">> := #{<<"id">> := IdStr}} = Msg | Rest],
    AccWithId,
    AccNotId
) ->
    divide_and_conquer(IdStr, Rest, [Msg | AccWithId], AccNotId);
divide_and_conquer(IdStr, [Msg | Rest], AccWithId, AccNotId) ->
    divide_and_conquer(IdStr, Rest, AccWithId, [Msg | AccNotId]).

%%
%%
divide_and_conquer_no_idstr(Store) ->
    divide_and_conquer_no_idstr(Store, [], []).

divide_and_conquer_no_idstr([], AccWithId, AccWithoutId) ->
    {AccWithId, AccWithoutId};
divide_and_conquer_no_idstr(
    [#{<<"parts">> := #{<<"id">> := _IdStr}} = Msg | Rest],
    AccWithId,
    AccWithoutId
) ->
    divide_and_conquer_no_idstr(Rest, [Msg | AccWithId], AccWithoutId);
divide_and_conquer_no_idstr(
    [Msg | Rest],
    AccWithId,
    AccWithoutId
) ->
    divide_and_conquer_no_idstr(Rest, AccWithId, [Msg | AccWithoutId]).
