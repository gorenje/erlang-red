-module(ered_node_switch).

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% representation of a switch node.
%%
%% Switch nodes represent control flow within Node-RED and are central to
%% creating complex flows.
%%
%% Basic working of a switch node is that it has a collection of rules that are
%% tested for truthfulness. If true, then then message is sent to all wires
%% on the port (Node-RED *port* is the point of connection for wires) for that
%% rule. A switch can either test all rules or stop after the first true rule,
%% that is specified by the "checkall" attribute.
%%

-import(ered_nodes, [
    jstr/2,
    send_msg_on/2
]).
-import(ered_message_exchange, [
    post_completed/2
]).
-import(ered_messages, [
    convert_to_num/1,
    get_prop/2,
    is_not_same/2,
    is_same/2,
    to_bool/1
]).
-import(ered_nodered_comm, [
    post_exception_or_debug/3,
    unsupported/3
]).
%%
%%
start(#{<<"repair">> := true} = NodeDef, WsName) ->
    unsupported(NodeDef, {websocket, WsName}, "recreate message sequence"),
    ered_node:start(NodeDef, ered_node_ignore);
start(NodeDef, _WsName) ->
    ered_node:start(NodeDef, ?MODULE).

%%
%%
handle_event(_, NodeDef) ->
    NodeDef.

%%
%% Handler for incoming messages
%%
handle_msg(
    {incoming, Msg},
    #{<<"rules">> := Rules, <<"wires">> := Wires} = NodeDef
) ->
    case
        obtain_compare_to_value(
            maps:find(<<"propertyType">>, NodeDef),
            maps:find(<<"property">>, NodeDef),
            Msg
        )
    of
        {ok, Val} ->
            case maps:find(<<"checkall">>, NodeDef) of
                {ok, <<"true">>} ->
                    %% last flag indicates that nothing has yet matched -
                    %% required for the otherwise ('else') operator.
                    handle_check_all_rules(
                        Rules,
                        Val,
                        Wires,
                        NodeDef,
                        Msg,
                        false
                    );
                _ ->
                    handle_stop_after_one(
                        Rules,
                        Val,
                        Wires,
                        NodeDef,
                        Msg
                    )
            end;
        property_not_found_on_msg ->
            case maps:find(<<"checkall">>, NodeDef) of
                {ok, <<"true">>} ->
                    %% last flag indicates that nothing has yet matched -
                    %% required for the otherwise ('else') operator.
                    handle_check_all_rules(
                        Rules,
                        not_defined_on_msg,
                        Wires,
                        NodeDef,
                        Msg,
                        false
                    );
                _ ->
                    handle_stop_after_one(
                        Rules,
                        not_defined_on_msg,
                        Wires,
                        NodeDef,
                        Msg
                    )
            end;
        {error, ErrMsg} ->
            post_exception_or_debug(NodeDef, Msg, ErrMsg);
        {unsupported, ErrMsg} ->
            unsupported(NodeDef, Msg, ErrMsg);
        {exception, ErrMsg} ->
            post_exception_or_debug(NodeDef, Msg, ErrMsg)
    end,

    {handled, NodeDef, dont_send_complete_msg};
%%
%%
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% ----------------------- Helpers
%%

obtain_operator_value(<<"jsonata">>, OpVal, Msg) ->
    case erlang_red_jsonata:execute(OpVal, Msg) of
        {ok, Result} ->
            {ok, Result};
        {undefined, _Result} ->
            {ok, undefined};
        {error, Error} ->
            {error, jstr("jsonata term: ~p", [Error])};
        {unsupported, Error} ->
            {exception, Error};
        {exception, {_E, M, _S}} ->
            {exception, M}
    end;
obtain_operator_value(<<"num">>, OpVal, _Msg) ->
    {ok, convert_to_num(OpVal)};
obtain_operator_value(<<"str">>, OpVal, _Msg) ->
    {ok, OpVal};
obtain_operator_value(<<"bool">>, OpVal, _Msg) ->
    {ok, OpVal};
obtain_operator_value(<<"msg">>, OpVal, Msg) ->
    case get_prop({ok, OpVal}, Msg) of
        {ok, Val, _} ->
            {ok, Val};
        _ ->
            {error, jstr("value not found on msg: ~p", [OpVal])}
    end;
obtain_operator_value(OpType, OpVal, _Msg) ->
    {unsupported,
        jstr(
            "unsupported operator type: ~p --> V: ~p",
            [OpType, OpVal]
        )}.

%%
%%
does_rule_match(<<"neq">>, OpCompVal, MsgVal) ->
    is_not_same(OpCompVal, MsgVal);
does_rule_match(<<"eq">>, OpCompVal, MsgVal) ->
    is_same(OpCompVal, MsgVal);
does_rule_match(<<"gte">>, OpCompVal, MsgVal) ->
    MsgVal >= OpCompVal;
does_rule_match(<<"gt">>, OpCompVal, MsgVal) ->
    MsgVal > OpCompVal;
does_rule_match(<<"lt">>, OpCompVal, MsgVal) ->
    MsgVal < OpCompVal;
does_rule_match(<<"lte">>, OpCompVal, MsgVal) ->
    MsgVal =< OpCompVal;
does_rule_match(<<"bleq">>, OpCompVal, MsgVal) ->
    is_same(to_bool(MsgVal), OpCompVal);
does_rule_match(<<"cont">>, OpCompVal, MsgVal) ->
    string:find(MsgVal, OpCompVal) =/= nomatch;
does_rule_match(Op, _, _) ->
    {unsupported, jstr("unsupported rule ~p", [Op])}.

does_rule_match(Op, Type, OpVal, MsgVal, NodeDef, Msg) ->
    case obtain_operator_value(Type, OpVal, Msg) of
        {ok, OpCompVal} ->
            case does_rule_match(Op, OpCompVal, MsgVal) of
                {unsupported, ErrMsg} ->
                    unsupported(NodeDef, Msg, ErrMsg);
                V ->
                    V
            end;
        {error, ErrMsg} ->
            post_exception_or_debug(NodeDef, Msg, ErrMsg),
            false;
        {unsupported, ErrMsg} ->
            unsupported(NodeDef, Msg, ErrMsg),
            false;
        {exception, ErrMsg} ->
            post_exception_or_debug(NodeDef, Msg, ErrMsg),
            false
    end.
%%
%%
get_caseless(false) ->
    [];
get_caseless(true) ->
    [caseless].

does_regex_match(
    #{
        <<"case">> := IgnoreCase,
        <<"v">> := OpVal,
        <<"vt">> := OpType
    } = _Rule,
    MsgVal,
    NodeDef,
    Msg
) ->
    case obtain_operator_value(OpType, OpVal, Msg) of
        {ok, OpCompVal} ->
            {ok, RegExp} = re:compile(
                OpCompVal,
                [dollar_endonly, dotall, extended] ++ get_caseless(IgnoreCase)
            ),
            case re:run(MsgVal, RegExp) of
                {match, _} ->
                    true;
                nomatch ->
                    false
            end;
        {error, ErrMsg} ->
            post_exception_or_debug(NodeDef, Msg, ErrMsg),
            false;
        {unsupported, ErrMsg} ->
            unsupported(NodeDef, Msg, ErrMsg),
            false;
        {exception, ErrMsg} ->
            post_exception_or_debug(NodeDef, Msg, ErrMsg),
            false
    end.

%%
%%
is_empty(Val) when is_list(Val) ->
    length(Val) =:= 0;
is_empty(Val) when is_map(Val) ->
    maps:size(Val) =:= 0;
is_empty(<<"">>) ->
    true;
is_empty(undefined) ->
    false;
is_empty(Val) when is_number(Val) ->
    false;
is_empty(_) ->
    false.
%%
%%
is_not_empty(Val) when is_list(Val) ->
    length(Val) =/= 0;
is_not_empty(Val) when is_map(Val) ->
    maps:size(Val) =/= 0;
is_not_empty(<<"">>) ->
    false;
is_not_empty(null) ->
    false;
is_not_empty(true) ->
    false;
is_not_empty(false) ->
    false;
is_not_empty(undefined) ->
    false;
is_not_empty(Val) when is_number(Val) ->
    false;
is_not_empty(_) ->
    true.

%%
%% HasMatch is a indicated whether a match has been made. Used for the
%% else operator.
handle_check_all_rules([], _, _, _, _, _) ->
    ok;
handle_check_all_rules(
    [#{<<"t">> := Op} = _Rule | Rules],
    not_defined_on_msg = Val,
    [Wires | MoreWires],
    NodeDef,
    Msg,
    HadMatch
) ->
    %% else operator has no vt nor v values.
    case {Op, HadMatch} of
        {<<"else">>, false} ->
            send_msg_on(Wires, Msg),
            handle_check_all_rules(Rules, Val, MoreWires, NodeDef, Msg, true);
        {<<"else">>, true} ->
            handle_check_all_rules(Rules, Val, MoreWires, NodeDef, Msg, true);
        {<<"null">>, _} ->
            send_msg_on(Wires, Msg),
            handle_check_all_rules(Rules, Val, MoreWires, NodeDef, Msg, true);
        _ ->
            handle_check_all_rules(
                Rules, Val, MoreWires, NodeDef, Msg, HadMatch
            )
    end;
handle_check_all_rules(
    [#{<<"t">> := Op} = Rule | Rules],
    Val,
    [Wires | MoreWires],
    NodeDef,
    Msg,
    HadMatch
) ->
    %% else, true, false, null empty, ...  operators have no vt nor v values.
    case {Op, HadMatch} of
        {<<"else">>, false} ->
            %% Interesting, interesting - the "otherwise" rule only matches
            %% in the "check all rules" if nothing else matched - mimicing the
            %% behaviour of the stop-after-one mode. I personally would have
            %% thought it would match **all** the time, regardless.
            %% But "otherwise" means something different to "always".
            %% See test flow "ce2f98273da05245" for more details.
            %% Turns other otherwise is context specific: if it is reached
            %% and nothing has matched, it matches. Is it reached and something
            %% has matched, then it doesn't match.
            send_msg_on(Wires, Msg),
            handle_check_all_rules(Rules, Val, MoreWires, NodeDef, Msg, true);
        {<<"else">>, true} ->
            handle_check_all_rules(Rules, Val, MoreWires, NodeDef, Msg, true);
        {<<"true">>, _} ->
            %% this is a "is true" operation
            case
                does_rule_match(<<"bleq">>, <<"bool">>, true, Val, NodeDef, Msg)
            of
                true ->
                    send_msg_on(Wires, Msg),
                    handle_check_all_rules(
                        Rules, Val, MoreWires, NodeDef, Msg, true
                    );
                _ ->
                    handle_check_all_rules(
                        Rules, Val, MoreWires, NodeDef, Msg, HadMatch
                    )
            end;
        {<<"false">>, _} ->
            %% this is a "is false" operation
            case
                does_rule_match(
                    <<"bleq">>, <<"bool">>, false, Val, NodeDef, Msg
                )
            of
                true ->
                    send_msg_on(Wires, Msg),
                    handle_check_all_rules(
                        Rules, Val, MoreWires, NodeDef, Msg, true
                    );
                _ ->
                    handle_check_all_rules(
                        Rules, Val, MoreWires, NodeDef, Msg, HadMatch
                    )
            end;
        {<<"nempty">>, _} ->
            case is_not_empty(Val) of
                true ->
                    send_msg_on(Wires, Msg),
                    handle_check_all_rules(
                        Rules, Val, MoreWires, NodeDef, Msg, true
                    );
                false ->
                    handle_check_all_rules(
                        Rules, Val, MoreWires, NodeDef, Msg, HadMatch
                    )
            end;
        {<<"empty">>, _} ->
            case is_empty(Val) of
                true ->
                    send_msg_on(Wires, Msg),
                    handle_check_all_rules(
                        Rules, Val, MoreWires, NodeDef, Msg, true
                    );
                false ->
                    handle_check_all_rules(
                        Rules, Val, MoreWires, NodeDef, Msg, HadMatch
                    )
            end;
        {<<"regex">>, _} ->
            case does_regex_match(Rule, Val, NodeDef, Msg) of
                true ->
                    send_msg_on(Wires, Msg),
                    handle_check_all_rules(
                        Rules, Val, MoreWires, NodeDef, Msg, true
                    );
                false ->
                    handle_check_all_rules(
                        Rules, Val, MoreWires, NodeDef, Msg, HadMatch
                    )
            end;
        {<<"null">>, _} ->
            %% Javascript has "null" "undefined" "NaN" and "Infinity"
            %% JSON has "true", "false", and "null" - the latter being the
            %% atom null in Erlang.
            (Val =:= null orelse Val =:= undefined) andalso send_msg_on(Wires, Msg),
            handle_check_all_rules(
                Rules, Val, MoreWires, NodeDef, Msg, Val =:= null
            );
        {<<"nnull">>, _} ->
            %% not-null is the exact opposite of <<"null">> operator
            Val =/= null andalso Val =/= undefined
                andalso send_msg_on(Wires, Msg),
            handle_check_all_rules(
                Rules, Val, MoreWires, NodeDef, Msg, Val =/= null
            );
        _ ->
            {ok, Type} = maps:find(<<"vt">>, Rule),
            {ok, OpVal} = maps:find(<<"v">>, Rule),

            case does_rule_match(Op, Type, OpVal, Val, NodeDef, Msg) of
                true ->
                    %% ?? switch node does not generate complete message for the
                    %% ?? complete node - make sense since the switch node is only
                    %% ?? control not computation, i.e. it's direct the flow of data
                    %% ?? but not directly altering data.
                    %% post_completed(NodeDef, Msg),
                    send_msg_on(Wires, Msg),
                    handle_check_all_rules(
                        Rules, Val, MoreWires, NodeDef, Msg, true
                    );
                _ ->
                    handle_check_all_rules(
                        Rules, Val, MoreWires, NodeDef, Msg, HadMatch
                    )
            end
    end.

%%
%%
handle_stop_after_one([], _, _, _, _) ->
    ok;
handle_stop_after_one(
    [#{<<"t">> := Op} = _Rule | Rules],
    not_defined_on_msg = Val,
    [Wires | MoreWires],
    NodeDef,
    Msg
) ->
    case Op of
        <<"null">> ->
            send_msg_on(Wires, Msg);
        <<"else">> ->
            send_msg_on(Wires, Msg);
        _ ->
            handle_stop_after_one(Rules, Val, MoreWires, NodeDef, Msg)
    end;
handle_stop_after_one(
    [#{<<"t">> := Op} = Rule | Rules],
    Val,
    [Wires | MoreWires],
    NodeDef,
    Msg
) ->
    %% else, true, false, null empty, ...  operators have no vt nor v values.
    case Op of
        %% else operator has no vt nor v values.
        <<"else">> ->
            send_msg_on(Wires, Msg);
        <<"true">> ->
            %% this is a "is true" operation
            case
                does_rule_match(<<"bleq">>, <<"bool">>, true, Val, NodeDef, Msg)
            of
                true ->
                    send_msg_on(Wires, Msg);
                _ ->
                    handle_stop_after_one(Rules, Val, MoreWires, NodeDef, Msg)
            end;
        <<"false">> ->
            %% this is a "is false" operation
            case
                does_rule_match(
                    <<"bleq">>, <<"bool">>, false, Val, NodeDef, Msg
                )
            of
                true ->
                    send_msg_on(Wires, Msg);
                _ ->
                    handle_stop_after_one(Rules, Val, MoreWires, NodeDef, Msg)
            end;
        <<"nempty">> ->
            case is_not_empty(Val) of
                true ->
                    send_msg_on(Wires, Msg);
                false ->
                    handle_stop_after_one(Rules, Val, MoreWires, NodeDef, Msg)
            end;
        <<"empty">> ->
            case is_empty(Val) of
                true ->
                    send_msg_on(Wires, Msg);
                false ->
                    handle_stop_after_one(Rules, Val, MoreWires, NodeDef, Msg)
            end;
        <<"regex">> ->
            case does_regex_match(Rule, Val, NodeDef, Msg) of
                true ->
                    send_msg_on(Wires, Msg);
                false ->
                    handle_stop_after_one(Rules, Val, MoreWires, NodeDef, Msg)
            end;
        <<"null">> ->
            case Val of
                undefined ->
                    send_msg_on(Wires, Msg);
                null ->
                    send_msg_on(Wires, Msg);
                _ ->
                    handle_stop_after_one(Rules, Val, MoreWires, NodeDef, Msg)
            end;
        <<"nnull">> ->
            case Val of
                null ->
                    handle_stop_after_one(Rules, Val, MoreWires, NodeDef, Msg);
                undefined ->
                    handle_stop_after_one(Rules, Val, MoreWires, NodeDef, Msg);
                _ ->
                    send_msg_on(Wires, Msg)
            end;
        _ ->
            {ok, Type} = maps:find(<<"vt">>, Rule),
            {ok, OpVal} = maps:find(<<"v">>, Rule),

            case does_rule_match(Op, Type, OpVal, Val, NodeDef, Msg) of
                true ->
                    send_msg_on(Wires, Msg);
                _ ->
                    handle_stop_after_one(Rules, Val, MoreWires, NodeDef, Msg)
            end
    end.

%%
%% This function retrieves the value to which the rules are compared to.
%% This value can come from the (1) Msg object or the (2) flow context or the
%% (3) global context or as a (4) jsonata expression or the (5) environment
%% variable.
obtain_compare_to_value({ok, <<"msg">>}, {ok, PropName}, Msg) ->
    case get_prop({ok, PropName}, Msg) of
        {ok, Val, _} ->
            {ok, Val};
        _ ->
            property_not_found_on_msg
    end;
obtain_compare_to_value({ok, <<"jsonata">>}, {ok, PropName}, Msg) ->
    case erlang_red_jsonata:execute(PropName, Msg) of
        {ok, Result} ->
            {ok, Result};
        {undefined, _Result} ->
            {ok, undefined};
        {error, Error} ->
            {error, jstr("jsonata term: ~p", [Error])};
        {unsupported, Error} ->
            {exception, Error};
        {exception, {_E, M, _S}} ->
            {exception, M}
    end;
obtain_compare_to_value({ok, PropType}, {ok, PropName}, _Msg) ->
    {unsupported,
        jstr("unsupported property: ~p with type ~p", [PropName, PropType])};
obtain_compare_to_value(Err1, Err2, _Msg) ->
    {error, jstr("error finding property Err1: ~p Err2: ~p", [Err1, Err2])}.
