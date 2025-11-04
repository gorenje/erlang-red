-module(ered_node_inject).

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Inject node should have at least one outgoing wire, if not then the
%% needle won't hit the vein, i.e. the message won't flow through any nodes.
%%
%%  "id": "dc5aaefd109f64b8",
%%  "type": "inject",
%%  "z": "c4b44f0eb78bc401",
%%  "g": "3e66f8d35dcccd45",
%%  "name": "",
%%  "props": [
%%      {
%%          "p": "payload"
%%      },
%%      {
%%          "p": "action",
%%          "v": "donothing",
%%          "vt": "str"
%%      }
%%  ],
%%  "repeat": "",  <<----+- if node is trigger automagically via "once",
%%  "crontab": "", <<---/ then repeat can be used to continue the inject
%%  "once": false, <<--/ but this isn't supported. ('once' either true or false).
%%  "onceDelay": 0.1,
%%  "topic": "",
%%  "payload": "donothing",
%%  "payloadType": "str",
%%  "x": 218,
%%  "y": 783.75,
%%  "wires": [
%%      [
%%          "5c1cf21f1fb90b33"
%%      ]
%%  ]
%%
%%

-import(ered_nodes, [
    check_node_config/3,
    get_prop_value_from_map/2,
    get_prop_value_from_map/3,
    jstr/1,
    jstr/2,
    send_msg_to_connected_nodes/2
]).
-import(ered_nodered_comm, [
    post_exception_or_debug/3,
    unsupported/3
]).
-import(ered_messages, [
    convert_to_num/1,
    decode_json/1,
    delete_prop/2,
    get_prop/2,
    jsbuffer_to_binary/1,
    set_prop_value/3,
    timestamp/0,
    timestamp/1,
    to_bool/1
]).
-import(ered_message_exchange, [
    post_completed/2
]).
-import(ered_messages, [
    create_outgoing_msg/1
]).

%%
%%
% erlfmt:ignore - alignment
start(NodeDef, WsName) ->
    %% TODO support repeat and crontab
    case check_node_config([
        {<<"repeat">>,  <<"">>},
        {<<"crontab">>, <<"">>}
    ], NodeDef, WsName) of
        ok ->
            ered_node:start(NodeDef, ?MODULE);
        _ ->
            ered_node:start(NodeDef, ered_node_ignore)
    end.

%%
%%
handle_event(
    {flow_started, WsName},
    #{<<"once">> := Once, <<"onceDelay">> := Delay} = NodeDef
) when Once =:= true; Once =:= <<"true">> ->
    {ok, TRef} = send_out_after(Delay, WsName),
    NodeDef#{onceref => TRef};
handle_event({stop, _WsName}, #{onceref := TRef} = NodeDef) ->
    timer:cancel(TRef),
    maps:remove(onceref, NodeDef);
handle_event(_, NodeDef) ->
    NodeDef.

%%
%% outgoing messages are triggered by button presses on the UI
%%
handle_msg({outgoing, Msg}, NodeDef) ->
    case maps:find(<<"props">>, NodeDef) of
        {ok, Val} ->
            Props = Val;
        _ ->
            Props = []
    end,

    try
        Msg2 = parse_props(Props, NodeDef, Msg),
        send_msg_to_connected_nodes(NodeDef, Msg2),
        %% this should be done by the behaviour but it does not allow
        %% outgoing messages to generated completed messages, so do this
        %% here directly.
        post_completed(NodeDef, Msg2),
        {handled, NodeDef, Msg2}
    catch
        throw:dont_send_message ->
            {handled, NodeDef, Msg}
    end;
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% ------------------------ Helpers
%%
send_out_after(<<>>, WsName) ->
    send_out_after(<<"0.1">>, WsName);
send_out_after(Delay, WsName) ->
    ToThisPid = self(),
    timer:apply_after(
        round(convert_to_num(Delay) * 1000),
        fun() ->
            %% simulate a button press
            gen_server:cast(ToThisPid, create_outgoing_msg(WsName))
        end
    ).

%%
%%
value_for_proptype(<<"date">>, <<"iso">>, Prop, _NodeDef, Msg) ->
    set_prop_value(Prop, timestamp(iso), Msg);
value_for_proptype(<<"date">>, _Val, Prop, _NodeDef, Msg) ->
    set_prop_value(Prop, timestamp(), Msg);
value_for_proptype(<<"json">>, Val, Prop, _NodeDef, Msg) ->
    set_prop_value(Prop, decode_json(Val), Msg);
value_for_proptype(<<"str">>, Val, Prop, _NodeDef, Msg) ->
    set_prop_value(Prop, Val, Msg);
value_for_proptype(<<"num">>, Val, Prop, _NodeDef, Msg) ->
    set_prop_value(Prop, convert_to_num(Val), Msg);
value_for_proptype(<<"bool">>, Val, Prop, _NodeDef, Msg) ->
    set_prop_value(Prop, to_bool(Val), Msg);
value_for_proptype(<<"msg">>, Val, Prop, _NodeDef, Msg) ->
    case get_prop({ok, Val}, Msg) of
        {ok, Value, _} ->
            set_prop_value(Prop, Value, Msg);
        _ ->
            set_prop_value(Prop, <<>>, Msg)
    end;
value_for_proptype(<<"bin">>, Value, Prop, NodeDef, Msg) ->
    case jsbuffer_to_binary(Value) of
        {ok, Val} ->
            set_prop_value(Prop, Val, Msg);
        {error, Error} ->
            unsupported(
                NodeDef,
                Msg,
                jstr("buffer string: ~p in ~p", [Error, Value])
            ),
            Msg
    end;
value_for_proptype(<<"jsonata">>, Val, Prop, NodeDef, Msg) ->
    case erlang_red_jsonata:execute(Val, Msg) of
        {ok, Result} ->
            set_prop_value(Prop, Result, Msg);
        {undefined, _Result} ->
            delete_prop(Prop, Msg);
        {error, Error} ->
            unsupported(NodeDef, Msg, jstr("jsonata term: ~p", [Error])),
            Msg;
        {unsupported, Error} ->
            post_exception_or_debug(NodeDef, Msg, Error),
            throw(dont_send_message);
        {exception, {E, M, S}} ->
            ErrMsg = jstr("jsonata exception:~n~n~p~n~n~p~n~n~p", [E, M, S]),
            post_exception_or_debug(NodeDef, Msg, ErrMsg),
            throw(dont_send_message)
    end;
value_for_proptype(PropType, _Val, PropName, NodeDef, Msg) ->
    unsupported(
        NodeDef,
        Msg,
        jstr(
            "proptype ~p for ~p, handling as string type",
            [PropType, PropName]
        )
    ),
    Msg.

%%
%% topic property has a topic attribute of the NodeDef containing the
%% string value iff the type is "str" otherwise the value is set on
%% the property defintion, i.e. 'v'.
obtain_topic_value(NodeDef, _Prop, <<"str">>) ->
    get_prop_value_from_map(<<"topic">>, NodeDef);
obtain_topic_value(_NodeDef, Prop, _) ->
    get_prop_value_from_map(<<"v">>, Prop).

%%
%%
parse_props([], _, Msg) ->
    Msg;
parse_props([Prop | RestProps], NodeDef, Msg) ->
    case maps:find(<<"p">>, Prop) of
        {ok, <<"payload">>} ->
            Val = get_prop_value_from_map(<<"payload">>, NodeDef),
            PropType = get_prop_value_from_map(<<"payloadType">>, NodeDef),

            parse_props(
                RestProps,
                NodeDef,
                value_for_proptype(PropType, Val, <<"payload">>, NodeDef, Msg)
            );
        {ok, <<"topic">>} ->
            PropType = get_prop_value_from_map(<<"vt">>, Prop),
            Val = obtain_topic_value(NodeDef, Prop, PropType),

            parse_props(
                RestProps,
                NodeDef,
                value_for_proptype(PropType, Val, <<"topic">>, NodeDef, Msg)
            );
        {ok, PropName} ->
            Val = get_prop_value_from_map(<<"v">>, Prop),
            PropType = get_prop_value_from_map(<<"vt">>, Prop),
            parse_props(
                RestProps,
                NodeDef,
                value_for_proptype(PropType, Val, PropName, NodeDef, Msg)
            );
        _ ->
            unsupported(NodeDef, Msg, jstr("Prop: NoMATCH: ~p\n", [Prop])),
            parse_props(RestProps, NodeDef, Msg)
    end.
