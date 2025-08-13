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
    get_prop/2,
    retrieve_prop_value/2
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
route_and_handle_val(Val, NodeDef, Msg) when is_atom(Val) ->
    unsupported(NodeDef, Msg, "splitting the atom");
route_and_handle_val(Val, NodeDef, Msg) when is_binary(Val) ->
    %% binary isn't the same as a NodeJS buffer - this is also something that
    %% needs revisiting.
    unsupported(NodeDef, Msg, "split operation");
route_and_handle_val(Val, NodeDef, Msg) when is_list(Val) ->
    %% this can either be "string" or ["string","string","string"], i.e,
    %% a string or an array. Turns out to be a rather difficult thing to
    %% distinguish between the two. So for now make the assumption that
    %% any list is an array.
    %% TODO: distinguish between string (which is a list) and an array
    %% TODO: which is also a list in Erlang.
    split_array(Val, 0, erlang:length(Val), generate_id(), NodeDef, Msg);
route_and_handle_val(Val, NodeDef, Msg) ->
    unsupported(NodeDef, Msg, jstr("value type ~p", [Val])).

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
        <<"parts">> => generate_array_part(Cnt, TotalCnt, PartsId),
        ?AddPayload(Val)
    },

    send_msg_to_connected_nodes(NodeDef, Msg2),
    split_array(MoreVals, Cnt + 1, TotalCnt, PartsId, NodeDef, Msg).

%%
%%
%% erlfmt:ignore because of alignment
generate_array_part(Cnt,TotalCnt, PartsId) ->
    %% index starts from zero so the last element will have Cnt == TotalCnt-1
    #{
      <<"id">>    => PartsId,
      <<"type">>  => <<"array">>, %% TODO figure out what this means
      <<"len">>   => 1,           %% TODO figure out what this means
      <<"count">> => TotalCnt,
      <<"index">> => Cnt
     }.
