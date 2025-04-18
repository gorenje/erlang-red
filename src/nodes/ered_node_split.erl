-module(ered_node_split).

-export([node_split/2]).
-export([handle_incoming/2]).

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

-import(ered_node_receivership, [
    enter_receivership/3
]).
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

%%
%%
route_and_handle_val(Val, NodeDef, Msg) when is_atom(Val) ->
    unsupported(NodeDef, Msg, "splitting the atom");
route_and_handle_val(Val, NodeDef, Msg) when is_binary(Val) ->
    %% binary isn't the same as a NodeJS buffer - this is also something that
    %% needs revisiting.
    split_buffer(Val, NodeDef, Msg);
route_and_handle_val(Val, NodeDef, Msg) when is_list(Val) ->
    %% this can either be "string" or ["string","string","string"], i.e,
    %% a string or an array. Turns out to be a rather difficult thing to
    %% distinguish between the two. So for now make the assumption that
    %% any list is an array.
    %% TODO: distinguish between string (which is a list) and an array
    %% TODO: which is also a list in Erlang.
    split_array(Val, 0, erlang:length(Val), NodeDef, Msg);
route_and_handle_val(Val, NodeDef, Msg) ->
    unsupported(NodeDef, Msg, jstr("value type ~p", [Val])).

%%
%%
%% erlfmt:ignore because of alignment
generate_array_part(Cnt,TotalCnt) ->
    %% index starts from zero so the last element will have Cnt == TotalCnt-1
    #{
      id    => generate_id(),
      type  => <<"array">>, %% TODO figure out what this means
      len   => 1,           %% TODO figure out what this means
      count => TotalCnt,
      index => Cnt
     }.

%%
%%
split_array([], _Cnt, _TotalLength, _NodeDef, _Msg) ->
    %% last value was already sent - could send an extra "complete msg"
    %% here but I don't think the split node does that.
    ok;
split_array([Val | MoreVals], Cnt, TotalCnt, NodeDef, Msg) ->
    Msg2 = maps:put('_msgid', generate_id(), Msg),
    Msg3 = maps:put(payload, Val, Msg2),
    Msg4 = maps:put(parts, generate_array_part(Cnt, TotalCnt), Msg3),
    send_msg_to_connected_nodes(NodeDef, Msg4),

    split_array(MoreVals, Cnt + 1, TotalCnt, NodeDef, Msg).

split_buffer(_Val, NodeDef, Msg) ->
    unsupported(NodeDef, Msg, "split buffer").

%% split_string(_Val, NodeDef, Msg) ->
%%     unsupported(NodeDef, Msg, "split string").

%%
%%
handle_incoming(NodeDef, Msg) ->
    {ok, Prop} = maps:find(property, NodeDef),

    case maps:find(binary_to_atom(Prop), Msg) of
        {ok, Val} ->
            route_and_handle_val(Val, NodeDef, Msg);
        _ ->
            ErrMsg = jstr(
                "Unable to find property value: ~p in ~p",
                [Prop, Msg]
            ),
            send_out_debug_msg(NodeDef, Msg, ErrMsg, error)
    end,

    NodeDef.

node_split(NodeDef, _WsName) ->
    ered_nodes:node_init(NodeDef),
    enter_receivership(?MODULE, NodeDef, only_incoming).
