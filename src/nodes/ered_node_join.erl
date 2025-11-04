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
start(
    #{
        <<"mode">> := <<"custom">>,
        <<"build">> := <<"array">>,
        <<"timeout">> := Timeout,
        <<"useparts">> := false,
        <<"accumulate">> := false
    } = NodeDef,
    WsName
) when Timeout =/= <<>> ->
    case convert_to_int(Timeout) of
        V when V > 0 ->
            ered_node:start(
                NodeDef#{
                    '_timeout' => V,
                    '_counter' => 0,
                    '_store' => undefined
                },
                ered_node_join_timeout
            );
        _ ->
            ErrMsg = jstr("Timeout ~p", [NodeDef]),
            unsupported(NodeDef, {websocket, WsName}, ErrMsg),
            ered_node:start(NodeDef, ered_node_ignore)
    end;
%%
%% consider parts attribute on messages
%%
start(
    #{
        <<"mode">> := <<"custom">>,
        <<"build">> := <<"array">>,
        <<"count">> := Count,
        <<"useparts">> := true
    } = NodeDef,
    WsName
) ->
    case check_property_type(NodeDef) of
        {ok, NodeDef2} ->
            IntCount = convert_to_int(Count),
            case IntCount > 0 of
                true ->
                    ered_node:start(
                        NodeDef2#{
                            '_store' => undefined,
                            '_count' => IntCount
                        },
                        ered_node_join_useparts
                    );
                false ->
                    ered_node:start(
                        NodeDef2#{
                            '_store' => undefiend
                        },
                        ered_node_join_useparts_no_count
                    )
            end;
        {false, NodeDef2} ->
            ErrMsg = jstr("Node Config ~p", [NodeDef]),
            unsupported(NodeDef, {websocket, WsName}, ErrMsg),
            ered_node:start(NodeDef2, ered_node_ignore)
    end;
%%
%% ignore parts attribute on messages and check the count value. Count must be
%% non-negative and non-zero.
%%
start(
    #{
        <<"mode">> := <<"custom">>,
        <<"build">> := <<"array">>,
        <<"count">> := Count,
        <<"useparts">> := false
    } = NodeDef,
    WsName
) ->
    case check_property_type(NodeDef) of
        {ok, NodeDef2} ->
            %% _store is defined by the registered event because we use
            %% an ETS table per process not per module.
            IntCount = convert_to_int(Count),
            case IntCount > 0 of
                true ->
                    ered_node:start(
                        NodeDef2#{
                            '_store' => undefined,
                            '_count' => IntCount,
                            '_togo' => IntCount
                        },
                        ered_node_join_count
                    );
                false ->
                    ered_node:start(
                        NodeDef2#{
                            '_store' => undefined,
                            '_counter' => 0
                        },
                        ered_node_join_no_count
                    )
            end;
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
    %% true, creating an array and property is payload on msg.
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
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% -------------------- helpers
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
check_property_type(
    #{<<"propertyType">> := PropType, <<"useparts">> := UseParts} = NodeDef
) when
    (PropType =:= <<"full">> orelse PropType =:= <<"msg">>) andalso
        (UseParts =:= true orelse UseParts =:= false)
->
    {ok, NodeDef};
check_property_type(NodeDef) ->
    {false, NodeDef}.
