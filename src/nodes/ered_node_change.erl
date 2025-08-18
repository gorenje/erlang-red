-module(ered_node_change).

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Change node modifies the contents of messages but also sets values in
%% the flow and global contexts. It has many possible features and this
%% implementation only implements a small subset
%%
%%
%% {
%%    "id": "c96b74e7b2e444e7",
%%    "type": "change",
%%    "z": "866410b56fa42447",
%%    "g": "5e6c5aa86609cf42",
%%    "name": "alter _msgid",
%%    "rules": [
%%        {
%%            "t": "set",
%%            "p": "payload",
%%            "pt": "msg",
%%            "to": "counter",
%%            "tot": "msg"
%%        },
%%        {
%%            "t": "set",
%%            "p": "counter",
%%            "pt": "msg",
%%            "to": "$$.counter + 1",
%%            "tot": "jsonata"
%%        },
%%        {
%%            "t": "set",
%%            "p": "'_msgid'",
%%            "pt": "msg",
%%            "to": "$string($substring( $pad( $formatBase($random() * 100000, 16), 4, '0'),0,4) & \t$substring( $pad( $formatBase($random() * 100000, 16), 4, '0'),0,4) & \t$substring( $pad( $formatBase($random() * 100000, 16), 4, '0'),0,4) & \t$substring( $pad( $formatBase($random() * 100000, 16), 4, '0'),0,4))",
%%            "tot": "jsonata"
%%        }
%%
%%
-import(ered_nodered_comm, [
    post_exception_or_debug/3,
    node_status/5,
    unsupported/3
]).
-import(ered_nodes, [
    jstr/2,
    send_msg_to_connected_nodes/2
]).
-import(ered_messages, [
    convert_to_num/1,
    jsbuffer_to_binary/1,
    decode_json/1,
    delete_prop/2,
    get_prop/2,
    set_prop_value/3,
    timestamp/0,
    to_bool/1
]).

%%
%%
start(#{<<"rules">> := Rules} = NodeDef, WsName) ->
    %% Pre-compile all JSONata stanzas and error out the node if something
    %% does not compile.
    case ered_jsonata_compiler:compile_stanzas(retrieve_jsonatas(Rules)) of
        {[], Cache} ->
            Rules2 = replace_jsonatas_with_functions(Rules, Cache),
            ered_node:start(NodeDef#{<<"rules">> => Rules2}, ?MODULE);
        {Errors, _} ->
            ErrMsg = jstr("JSONata Errors ~p", [Errors]),
            unsupported(NodeDef, {websocket, WsName}, ErrMsg),
            node_status(
                WsName, NodeDef, "jsonata compile failed", "red", "dot"
            ),
            ered_node:start(NodeDef, ered_node_ignore)
    end;
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
handle_msg({incoming, Msg}, NodeDef) ->
    {ok, Rules} = maps:find(<<"rules">>, NodeDef),
    try
        Msg2 = handle_rules(Rules, Msg, NodeDef),
        send_msg_to_connected_nodes(NodeDef, Msg2),
        {handled, NodeDef, Msg2}
    catch
        throw:dont_send_message ->
            {handled, NodeDef, dont_send_complete_msg}
    end;
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% ---------- helpers
%%
do_move({ok, <<"msg">>}, {ok, <<"msg">>}, {ok, FromProp}, {ok, ToProp}, Msg, _) ->
    case get_prop({ok, FromProp}, Msg) of
        {ok, Val, _} ->
            set_prop_value(
                ToProp,
                Val,
                delete_prop(FromProp, Msg)
            );
        _ ->
            Msg
    end;
do_move(A, B, C, D, Msg, NodeDef) ->
    unsupported(
        NodeDef,
        Msg,
        jstr("move rule: ~p, ~p, ~p, ~p", [A, B, C, D])
    ),
    Msg.

%%
%% first type check ...
do_change({ok, <<"msg">>}, {ok, <<"str">>}, {ok, <<"str">>}, Rule, Msg, _) ->
    do_change_str(
        maps:find(<<"p">>, Rule),
        maps:find(<<"from">>, Rule),
        maps:find(<<"to">>, Rule),
        Msg
    );
do_change(A, B, C, _, Msg, NodeDef) ->
    unsupported(
        NodeDef,
        Msg,
        jstr("change rule: ~p, ~p, ~p", [A, B, C])
    ),
    Msg.

%%
%%
do_change_str({ok, Prop}, {ok, FromStr}, {ok, ToStr}, Msg) ->
    case get_prop({ok, Prop}, Msg) of
        {ok, Val, _} ->
            set_prop_value(
                Prop,
                list_to_binary(
                    lists:flatten(
                        string:replace(
                            binary_to_list(Val),
                            binary_to_list(FromStr),
                            binary_to_list(ToStr),
                            all
                        )
                    )
                ),
                Msg
            );
        _ ->
            Msg
    end.

%%
%%
do_set_value(Prop, Value, <<"num">>, Msg, _NodeDef) ->
    set_prop_value(Prop, convert_to_num(Value), Msg);
do_set_value(Prop, _Value, <<"date">>, Msg, _NodeDef) ->
    set_prop_value(Prop, timestamp(), Msg);
do_set_value(Prop, Value, <<"str">>, Msg, _NodeDef) ->
    set_prop_value(Prop, Value, Msg);
do_set_value(Prop, Value, <<"bool">>, Msg, _NodeDef) ->
    set_prop_value(Prop, to_bool(Value), Msg);
do_set_value(Prop, Value, <<"json">>, Msg, _NodeDef) ->
    set_prop_value(Prop, decode_json(Value), Msg);
do_set_value(Prop, Value, <<"msg">>, Msg, _NodeDef) ->
    %% set a propery on the message to the value of another
    %% property on the message
    case get_prop({ok, Value}, Msg) of
        {ok, Val, _} ->
            set_prop_value(Prop, Val, Msg);
        _ ->
            set_prop_value(Prop, <<>>, Msg)
    end;
do_set_value(Prop, Value, <<"bin">>, Msg, NodeDef) ->
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
do_set_value(
    Prop,
    Func,
    <<"jsonata">>,
    Msg,
    NodeDef
) ->
    %% "t": "set",
    %% "p": "payload",
    %% "pt": "msg",
    %% "to": "$count($$.payload)",
    %% "tot": "jsonata"
    try
        set_prop_value(Prop, Func(Msg), Msg)
    catch
        error:jsonata_unsupported:Stacktrace ->
            [H | _] = Stacktrace,
            Error =
                list_to_binary(
                    io_lib:format(
                        "jsonata unsupported function: ~p", element(3, H)
                    )
                ),
            post_exception_or_debug(NodeDef, Msg, Error),
            throw(dont_send_message);
        E:M:S ->
            ErrMsg = jstr("jsonata exception:~n~n~p~n~n~p~n~n~p", [E, M, S]),
            post_exception_or_debug(NodeDef, Msg, ErrMsg),
            throw(dont_send_message)
    end;
do_set_value(_, _, Tot, Msg, NodeDef) ->
    unsupported(NodeDef, Msg, jstr("set ToT: ~p", [Tot])),
    Msg.

%%
%%
handle_rules([], Msg, _NodeDef) ->
    Msg;
handle_rules([Rule | MoreRules], Msg, NodeDef) ->
    {ok, RuleType} = maps:find(<<"t">>, Rule),
    handle_rules(
        MoreRules,
        handle_rule(RuleType, Rule, Msg, NodeDef),
        NodeDef
    ).

handle_rule(<<"set">>, Rule, Msg, NodeDef) ->
    %%
    %% pt can be many things (flow,global,...) we only support
    %% msg - at least until this comment gets removed.
    %%
    case maps:find(<<"pt">>, Rule) of
        {ok, <<"msg">>} ->
            {ok, Prop} = maps:find(<<"p">>, Rule),
            {ok, Value} = maps:find(<<"to">>, Rule),
            {ok, ToType} = maps:find(<<"tot">>, Rule),
            do_set_value(Prop, Value, ToType, Msg, NodeDef);
        PropType ->
            unsupported(
                NodeDef,
                Msg,
                jstr("delete proptype: ~p", [PropType])
            ),
            Msg
    end;
handle_rule(<<"delete">>, Rule, Msg, NodeDef) ->
    case maps:find(<<"pt">>, Rule) of
        {ok, <<"msg">>} ->
            delete_prop(maps:find(<<"p">>, Rule), Msg);
        PropType ->
            unsupported(
                NodeDef,
                Msg,
                jstr("delete proptype: ~p", [PropType])
            ),
            Msg
    end;
handle_rule(<<"move">>, Rule, Msg, NodeDef) ->
    do_move(
        maps:find(<<"pt">>, Rule),
        maps:find(<<"tot">>, Rule),
        maps:find(<<"p">>, Rule),
        maps:find(<<"to">>, Rule),
        Msg,
        NodeDef
    );
handle_rule(<<"change">>, Rule, Msg, NodeDef) ->
    do_change(
        maps:find(<<"pt">>, Rule),
        maps:find(<<"fromt">>, Rule),
        maps:find(<<"tot">>, Rule),
        Rule,
        Msg,
        NodeDef
    );
handle_rule(_, Rule, Msg, NodeDef) ->
    unsupported(NodeDef, Msg, jstr("Rule: ~p", [Rule])),
    Msg.

%%
%%
replace_jsonatas_with_functions(Rules, JSONataCache) ->
    replace_jsonatas_with_functions(Rules, JSONataCache, []).

replace_jsonatas_with_functions([], _JSONataCache, Acc) ->
    lists:reverse(Acc);
replace_jsonatas_with_functions(
    [#{<<"to">> := JSONata, <<"tot">> := <<"jsonata">>} = Whole | Rest],
    JSONataCache,
    Acc
) ->
    replace_jsonatas_with_functions(
        Rest,
        JSONataCache,
        [
            Whole#{
                <<"to">> =>
                    ered_jsonata_compiler:find_function_for_stanza(
                        JSONata,
                        JSONataCache
                    )
            }
            | Acc
        ]
    );
replace_jsonatas_with_functions([Rule | Rest], C, Acc) ->
    replace_jsonatas_with_functions(Rest, C, [Rule | Acc]).

%%
%%
retrieve_jsonatas(Rules) ->
    retrieve_jsonatas(Rules, []).

retrieve_jsonatas([], Acc) ->
    Acc;
retrieve_jsonatas([#{<<"to">> := S, <<"tot">> := <<"jsonata">>} | Rest], Acc) ->
    retrieve_jsonatas(Rest, [S | Acc]);
retrieve_jsonatas([_Rule | Rest], Acc) ->
    retrieve_jsonatas(Rest, Acc).
