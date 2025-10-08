-module(ered_node_split).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Split node takes an array, string or buffer and for each item, it generates
%% a new message with a new msg. It also adds a parts attribute to the
%% message to identify this message as being part of a collection that the
%% join node can group back together again.
%%
%% Most interesting attributes:
%%
%%     "splt": "\\n",
%%     "spltType": "str",
%%     "arraySplt": 1,
%%     "arraySpltType": "len",
%%     "stream": false,
%%     "addname": "",
%%     "property": "payload",
%%
%% (Note: the misspelling 'splt' is desired)
%%
%% This node decides on the type of payload what to do. I.e. if the payload
%% is an array, then the array configuraiton is taken and everything else
%% is ignored. Similar for string & buffer.
%%
%% Also this acts only on properties defined on the msg object, flow, global
%% are not accessible.
%%
%% TODO: note to self: type distinguishes in Erlang are difficult and expensice.
%% TODO: In NodeJS there are strings, arrays, objects in Erlang there are
%% TODO: atoms, binaries and lists. This split node is basically a burning
%% TODO: wreck what to wreak havoc!

-import(ered_nodered_comm, [
    send_out_debug_msg/4,
    unsupported/3
]).
-import(ered_nodes, [
    generate_id/0,
    jstr/1,
    jstr/2,
    send_msg_to_connected_nodes/2
]).
-import(ered_message_exchange, [
    post_completed/2
]).

-import(ered_messages, [
    any_to_integer/1,
    convert_to_integer/1,
    get_prop/2,
    retrieve_prop_value/2
]).

-define(CommonParts,
    <<"id">> => PartsId,
    <<"type">> => <<"array">>,
    <<"count">> => TotalCnt,
    <<"index">> => Cnt
).
%%
%%
start(#{<<"arraySplt">> := V} = NodeDef, _WsName) ->
    ered_node:start(
        NodeDef#{<<"arraySplt">> => convert_to_integer(V)}, ?MODULE
    ).

%%
%%
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg(
    {incoming, Msg},
    #{<<"property">> := Property} = NodeDef
) ->
    case get_prop(Property, Msg) of
        {ok, Val, _} ->
            route_and_handle_val(Val, NodeDef, Msg);
        {undefined, Prop} ->
            ErrMsg = jstr("Unable to find property value: ~p in ~p", [Prop, Msg]),
            send_out_debug_msg(NodeDef, Msg, ErrMsg, error)
    end,
    {handled, NodeDef, dont_send_complete_msg};
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% ------------------- Helpers
%%
%% this can either be "string" or ["string","string","string"], i.e,
%% a string or an array. Turns out to be a rather difficult thing to
%% distinguish between the two. So for now make the assumption that
%% any list is an array.
%% TODO: distinguish between string (which is a list) and an array
%% TODO: which is also a list in Erlang.
route_and_handle_val(Val, NodeDef, Msg) when is_atom(Val) ->
    unsupported(NodeDef, Msg, "splitting the atom");
%%
%% Binary splitting by fixed length & chars
%%
route_and_handle_val(
    Val,
    #{
        <<"arraySpltType">> := <<"len">>,
        <<"arraySplt">> := Length
    } = NodeDef,
    Msg
) when is_binary(Val), Length > 0 ->
    %% binary isn't the same as a NodeJS buffer - this is also something that
    %% needs revisiting.
    MatchIngFunc = fun
        (<<Packet:Length/bytes, Rest/bits>>) -> {Packet, Rest};
        (<<Rest/bits>>) -> {Rest, <<>>}
    end,
    NewLst = split_binary_into_list(MatchIngFunc, Val),
    split_array(NewLst, 0, erlang:length(NewLst), generate_id(), NodeDef, Msg);
%%
%% List values
%%
route_and_handle_val(
    Val,
    #{
        <<"arraySpltType">> := <<"len">>,
        <<"arraySplt">> := 0,
        <<"splt">> := SearchPattern
    } = NodeDef,
    Msg
) when is_list(Val); is_binary(Val) ->
    %% If arraySplt is zero, then we assume this is a string-based split on
    %% splt pattern. Either binary or list are supported.
    NewLst =
        case SearchPattern of
            <<"\\", C, "\\", D, "\\", A>> ->
                string:split(
                    Val,
                    to_escape(C) ++ to_escape(D) ++ to_escape(A),
                    all
                );
            <<"\\", C, "\\", D>> ->
                string:split(Val, to_escape(C) ++ to_escape(D), all);
            <<"\\", C>> ->
                string:split(Val, to_escape(C), all);
            _ ->
                string:split(Val, binary_to_list(SearchPattern), all)
        end,

    split_array(NewLst, 0, erlang:length(NewLst), generate_id(), NodeDef, Msg);
%%
route_and_handle_val(
    Val,
    #{
        <<"arraySpltType">> := <<"len">>,
        <<"arraySplt">> := 1
    } = NodeDef,
    Msg
) when is_list(Val) ->
    %% if arraySplt is one, then just split the array as is
    split_array(Val, 0, erlang:length(Val), generate_id(), NodeDef, Msg);
%%
route_and_handle_val(
    Val,
    #{
        <<"arraySpltType">> := <<"len">>,
        <<"arraySplt">> := Length
    } = NodeDef,
    Msg
) when is_list(Val) ->
    %% split by fixed length
    IntLength = convert_to_integer(Length),
    NewLst = lists:foldr(
        fun
            (E, []) -> [[E]];
            (E, [H | RAcc]) when length(H) < IntLength -> [[E | H] | RAcc];
            (E, [H | RAcc]) -> [[E], [H] | RAcc]
        end,
        [],
        Val
    ),
    split_array(NewLst, 0, erlang:length(NewLst), generate_id(), NodeDef, Msg);
%%
route_and_handle_val(Val, _NodeDef, _Msg) when is_integer(Val) ->
    silent_ly_ignor_ed;
%%
%% everything else is unsupported. Thank you for caring.
%%
route_and_handle_val(Val, NodeDef, Msg) ->
    unsupported(NodeDef, Msg, jstr("value type ~p cannot be splited", [Val])).

%%
%%
split_array([], _Cnt, _TotalLength, _PartsId, NodeDef, Msg) ->
    %% last value was already sent - could send an extra "complete msg"
    %% here but I don't think the split node does that.
    %%
    %% The post complete msg takes the original msg containing the original
    %% value not the last value and posts that.
    %%
    %% In Node-RED there might be a bug since it sends the last msg
    %% not the original -->
    %%   https://discourse.nodered.org/t/complete-split-is-the-value-wrong/96650/2
    %% logically speaking, the split node *completed* with the original
    %% message and has *initiated* the last message.
    post_completed(NodeDef, Msg);
split_array([Val | MoreVals], Cnt, TotalCnt, PartsId, NodeDef, Msg) ->
    Msg2 = Msg#{
        '_msgid' => generate_id(),
        <<"parts">> => generate_array_part(
            Cnt, TotalCnt, PartsId, NodeDef, Msg
        ),
        ?AddPayload(Val)
    },

    send_msg_to_connected_nodes(NodeDef, Msg2),
    split_array(MoreVals, Cnt + 1, TotalCnt, PartsId, NodeDef, Msg).

%%
%%
%% index starts from zero so the last element will have Cnt == TotalCnt-1
generate_array_part(
    Cnt,
    TotalCnt,
    PartsId,
    #{<<"arraySplt">> := Len} = _NodeDef,
    #{<<"parts">> := ExistingParts} = _Msg
) ->
    #{
        ?CommonParts,
        <<"len">> => any_to_integer(Len),
        <<"parts">> => ExistingParts
    };
generate_array_part(
    Cnt,
    TotalCnt,
    PartsId,
    #{<<"arraySplt">> := Len} = _NodeDef,
    _Msg
) ->
    #{
        ?CommonParts,
        <<"len">> => any_to_integer(Len)
    };
generate_array_part(
    Cnt,
    TotalCnt,
    PartsId,
    _NodeDef,
    #{<<"parts">> := ExistingParts} = _Msg
) ->
    #{
        ?CommonParts,
        <<"len">> => 1,
        <<"parts">> => ExistingParts
    };
generate_array_part(
    Cnt,
    TotalCnt,
    PartsId,
    _NodeDef,
    _Msg
) ->
    #{
        ?CommonParts,
        <<"len">> => 1
    }.

%%
%%
split_binary_into_list(_MatchFunc, <<>>) ->
    [];
split_binary_into_list(MatchFunc, Binary) ->
    split_binary_into_list(MatchFunc, Binary, []).
%%
split_binary_into_list(_MatchFunc, <<>>, Acc) ->
    lists:reverse(Acc);
split_binary_into_list(MatchFunc, Binary, Acc) ->
    {Packet, Rest} = MatchFunc(Binary),
    split_binary_into_list(MatchFunc, Rest, [Packet | Acc]).

%%
%% support the most popular escape sequences
%%
to_escape(98) -> "\b";
to_escape(110) -> "\n";
to_escape(114) -> "\r";
to_escape(116) -> "\t";
to_escape(_) -> "\n".
