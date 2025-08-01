-module(ered_node_assert_values).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Assert node that checks the msg for correct values.
%%
%% {
%%     "id": "40364d3053b8a4e0",
%%     "type": "ut-assert-values",
%%     "z": "c4b44f0eb78bc401",
%%     "name": "",
%%     "ignore_failure_if_succeed": true, <<--- if set, ignore failures if one succeed
%%     "rules": [
%%         {
%%             "t": "eql",
%%             "p": "payload",
%%             "pt": "msg",
%%             "to": "count 1",
%%             "tot": "str"
%%         }
%%     ],
%%     "x": 1115,
%%     "y": 460.5,
%%     "wires": [
%%         []
%%     ]
%% }

-import(ered_nodered_comm, [
    assert_failure/3,
    debug/3,
    node_status/5
]).
-import(ered_nodes, [
    get_prop_value_from_map/2,
    get_prop_value_from_map/3,
    jstr/2,
    send_msg_to_connected_nodes/2,
    this_should_not_happen/2
]).
-import(ered_messages, [
    convert_to_num/1,
    decode_json/1,
    encode_json/1,
    escape_specials/1,
    get_prop/2,
    is_same/2,
    jsbuffer_to_binary/1,
    to_bool/1
]).

%%
%%
start(NodeDef, _WsName) ->
    ered_node:start(
        NodeDef#{'_success_count' => 0, '_failures' => []}, ?MODULE
    ).

debug_data(NodeDef, ErrMsg) ->
    D = ?BASE_DATA,
    D#{
        <<"msg">> => ErrMsg,
        <<"format">> => <<"string">>
    }.

%%
%%
check_rule_against_msg(<<"notset">>, <<"msg">>, Rule, Msg) ->
    case get_prop(maps:find(<<"p">>, Rule), Msg) of
        {ok, _, Prop} ->
            {failed,
                jstr(
                    "Prop '~p' should not be set on Msg: ~p",
                    [Prop, Msg]
                )};
        _ ->
            true
    end;
check_rule_against_msg(<<"set">>, <<"msg">>, Rule, Msg) ->
    case get_prop(maps:find(<<"p">>, Rule), Msg) of
        {ok, _, _} ->
            true;
        {undefined, Prop} ->
            {failed,
                jstr(
                    "Prop '~p' not set on Msg: ~p",
                    [Prop, Msg]
                )}
    end;
check_rule_against_msg(<<"noteql">>, <<"msg">>, Rule, Msg) ->
    case get_prop(maps:find(<<"p">>, Rule), Msg) of
        {ok, Val, Prop} ->
            {ok, ReqVal} = maps:find(<<"to">>, Rule),
            case is_same(ReqVal, Val) of
                true ->
                    {failed,
                        jstr(
                            "Prop '~p': Unequal but same. Exp: ~n '~p' ~n Was: ~n '~p' ~n",
                            [Prop, ReqVal, Val]
                        )};
                _ ->
                    true
            end;
        {undefined, Prop} ->
            {failed, jstr("Prop not set on msg: '~p'", [Prop])}
    end;
%% eql operator on the msg - about the only thing that is
%% supported at the time of writing this comment.
check_rule_against_msg(<<"eql">>, <<"msg">>, Rule, Msg) ->
    {ok, ToType} = maps:find(<<"tot">>, Rule),
    {ok, ReqVal} = maps:find(<<"to">>, Rule),

    case get_prop(maps:find(<<"p">>, Rule), Msg) of
        {ok, Val, Prop} ->
            eql_msg_op(Prop, Val, ToType, ReqVal, Msg);
        {undefined, Prop} ->
            {failed, jstr("Prop not found on msg: '~p'", [Prop])}
    end;
check_rule_against_msg(<<"mth">>, <<"msg">>, Rule, Msg) ->
    {ok, ToType} = maps:find(<<"tot">>, Rule),
    {ok, ReqVal} = maps:find(<<"to">>, Rule),

    case get_prop(maps:find(<<"p">>, Rule), Msg) of
        {ok, PropVal, Prop} ->
            case re:compile(ReqVal) of
                {ok, ReqPattern} ->
                    match_value_on_msg(
                        Prop,
                        PropVal,
                        ToType,
                        ReqPattern,
                        ReqVal,
                        Msg
                    );
                _ ->
                    {failed, jstr("Match not RegExp: '~p'", [ReqVal])}
            end;
        {undefined, Prop} ->
            {failed, jstr("Propery unfound on Msg: '~p'", [Prop])}
    end;
check_rule_against_msg(_Operator, _ObjectType, _, _) ->
    unsupported.

%%
%%
match_value_on_msg(Prop, MsgVal, <<"str">>, ReqPattern, MatchVal, Msg) when
    is_integer(MsgVal)
->
    match_value_on_msg(
        Prop,
        integer_to_list(MsgVal),
        <<"str">>,
        ReqPattern,
        MatchVal,
        Msg
    );
match_value_on_msg(Prop, MsgVal, <<"str">>, ReqPattern, MatchVal, _Msg) ->
    case re:run(MsgVal, ReqPattern) of
        {match, _} ->
            true;
        _ ->
            {failed,
                jstr(
                    "Prop '~p':~n~nNot matched.~n~nMat~n~n'~p'~n~nVal:~n~n'~p'~n~n",
                    [Prop, MatchVal, MsgVal]
                )}
    end;
match_value_on_msg(_, _, _, _, _, _) ->
    unsupported.

%%
%%
eql_msg_op(Prop, SrcVal, <<"bin">>, ReqVal, _Msg) ->
    case jsbuffer_to_binary(ReqVal) of
        {ok, Val} ->
            case is_same(Val, SrcVal) of
                true ->
                    true;
                _ ->
                    {failed,
                     jstr(
                       "Prop '~p':~n~nExp:~n~n'~p'~n~nWas:~n~n'~p'~n~n",
                       [Prop, jsbuffer_to_binary(ReqVal), SrcVal]
                      )}
            end;
        {error, Error} ->
            {failed,
             jstr(
               "Prop '~p':~n~nNot parsable:~n~n~p~n~nError:~n~n~p~n~n",
               [Prop, ReqVal, Error]
              )}
    end;
eql_msg_op(Prop, SrcVal, <<"json">>, ReqVal, _Msg) ->
    DecodedVal = decode_json(ReqVal),
    case is_same(DecodedVal, decode_json(encode_json(SrcVal))) of
        true ->
            true;
        _ ->
            %% TODO this can and will happend as decode_json uses
            %% TODO binary values and jsonata uses string/list values.
            %% TODO best to refer to specific values and do a string compare
            %% TODO is_same(..) converts binaries to lists for comparison.
            {failed,
                jstr(
                    "Prop '~p':~n~nExp:~n~n'~p'~n~nWas:~n~n'~p'~n~n",
                    [Prop, DecodedVal, decode_json(encode_json(SrcVal))]
                )}
    end;
eql_msg_op(Prop, SrcVal, <<"str">>, ReqVal, _Msg) ->
    % replace/escape all specials so that a test case can use \r \t \n for
    % these things and it becomes visible what is desired. Ie. in the SrcVal
    % we escape these to their visible equivalents.
    case is_same(ReqVal, escape_specials(SrcVal)) of
        true ->
            true;
        _ ->
            {failed,
                jstr(
                    "Prop '~p':~n~nExp:~n~n'~p'~n~nWas:~n~n'~p'~n~n",
                    [Prop, ReqVal, SrcVal]
                )}
    end;
eql_msg_op(Prop, SrcVal, <<"bool">>, ReqVal, _Msg) ->
    case is_same(to_bool(ReqVal), to_bool(SrcVal)) of
        true ->
            true;
        _ ->
            {failed,
                jstr(
                    "Prop '~p':~n~nExp:~n~n'~p'~n~nWas:~n~n'~p'~n~n",
                    [Prop, ReqVal, SrcVal]
                )}
    end;
eql_msg_op(Prop, SrcVal, <<"msg">>, ReqProp, Msg) ->
    %% ReqProp not ReqVal because the value is actually a property name
    %% on the message object. That property then contains the required
    %% value.
    %%
    %% {
    %%     "t": "eql",
    %%     "p": "_msgid",
    %%     "pt": "msg",
    %%     "to": "originalmsgid",
    %%     "tot": "msg"
    %% }
    case get_prop({ok, ReqProp}, Msg) of
        {ok, ReqVal, _} ->
            case is_same(ReqVal, SrcVal) of
                true ->
                    true;
                _ ->
                    {failed,
                        jstr(
                            "Prop '~p':~n~nExp:~n~n'~p'~n~nWas:~n~n'~p'~n~n",
                            [Prop, ReqVal, SrcVal]
                        )}
            end;
        _ ->
            {failed, jstr("Prop not set on msg: '~p': ~p", [ReqProp, Msg])}
    end;
eql_msg_op(Prop, SrcVal, <<"num">>, ReqVal, _Msg) ->
    %% "t": "eql",
    %% "p": "payload",
    %% "pt": "msg",
    %% "to": "8",
    %% "tot": "num"
    case convert_to_num(SrcVal) of
        {error, _} ->
            {failed,
                jstr(
                    "Prop val '~p' was not a num: ~p",
                    [Prop, SrcVal]
                )};
        SrcNum ->
            case convert_to_num(ReqVal) of
                {error, _} ->
                    {failed,
                        jstr(
                            "Required val for ~p was not a num: ~p",
                            [Prop, ReqVal]
                        )};
                ReqNum ->
                    case ReqNum == SrcNum of
                        true ->
                            true;
                        _ ->
                            {failed,
                                jstr(
                                    "Values not equal for ~p Exp: ~p != Was: ~p",
                                    [Prop, ReqNum, SrcNum]
                                )}
                    end
            end
    end;
eql_msg_op(_, _, _, _, _) ->
    unsupported.

%%
%%
check_rules(Rules, NodeDef, Msg) ->
    check_rules(Rules, NodeDef, Msg, 0, [], 0).

check_rules([], _NodeDef, Msg, 0, _Failures, SuccessCount) ->
    Msg#{
        <<"assert_succeed">> => true,
        <<"assert_failures">> => [],
        <<"success_count">> => SuccessCount,
        <<"failure_count">> => 0
    };
check_rules([], _NodeDef, Msg, FailureCount, Failures, SuccessCount) ->
    Msg#{
        <<"assert_succeed">> => false,
        <<"assert_failures">> => Failures,
        <<"success_count">> => SuccessCount,
        <<"failure_count">> => FailureCount
    };
check_rules([H | T], NodeDef, Msg, FailureCount, Failures, SuccessCount) ->
    {ok, Op} = maps:find(<<"t">>, H),
    {ok, Pt} = maps:find(<<"pt">>, H),

    case check_rule_against_msg(Op, Pt, H, Msg) of
        true ->
            check_rules(
                T,
                NodeDef,
                Msg,
                FailureCount,
                Failures,
                SuccessCount + 1
            );
        unsupported ->
            check_rules(
                T,
                NodeDef,
                Msg,
                FailureCount + 1,
                [{unsupported, H} | Failures],
                SuccessCount
            );
        {failed, ErrMsg} ->
            check_rules(
                T,
                NodeDef,
                Msg,
                FailureCount + 1,
                [{failure, H, ErrMsg} | Failures],
                SuccessCount
            )
    end.

%%
%%
handle_event({stop, WsName}, NodeDef) ->
    case maps:find('_mc_incoming', NodeDef) of
        {ok, 0} ->
            {IdStr, TypeStr} = ?NODE_ID_AND_TYPE(NodeDef),

            this_should_not_happen(
                NodeDef,
                io_lib:format(
                    "Assert Values Error: Node was not reached [~p](~p)\n",
                    [TypeStr, IdStr]
                )
            ),

            D = ?BASE_DATA,

            Data = D#{
                <<"msg">> => <<"Assert Values Not Reached">>,
                <<"format">> => <<"string">>
            },

            debug(WsName, Data, error),
            node_status(WsName, NodeDef, "assert failed", "red", "dot");
        _ ->
            case maps:find(<<"ignore_failure_if_succeed">>, NodeDef) of
                {ok, true} ->
                    succeed_or_not(NodeDef, WsName);
                _ ->
                    ok
            end
    end,
    NodeDef#{'_success_count' => 0, '_failures' => []};
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg({incoming, Msg}, NodeDef) ->
    Msg2 = check_rules(maps:get(<<"rules">>, NodeDef), NodeDef, Msg),

    %% this option is relatively new, so there are only instances of
    %% this node that do not define this option, hence a 'maps:find' and
    %% not a 'maps:get'
    case maps:find(<<"ignore_failure_if_succeed">>, NodeDef) of
        {ok, true} ->
            #{'_success_count' := SuccCnt} = NodeDef,
            #{'_failures' := FailureLst} = NodeDef,
            #{<<"success_count">> := Cnt} = Msg2,
            #{<<"assert_failures">> := Failures} = Msg2,
            {handled,
                NodeDef#{
                    '_success_count' => SuccCnt + Cnt,
                    '_failures' => [{Msg, Failures} | FailureLst]
                },
                Msg2};
        _ ->
            post_failures(maps:get(<<"assert_failures">>, Msg2), NodeDef, Msg),
            set_node_status(
                maps:get(<<"assert_succeed">>, Msg2), NodeDef, Msg2
            ),
            send_msg_to_connected_nodes(NodeDef, Msg2),
            {handled, NodeDef, Msg2}
    end;
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% ------------- Helpers
%%

succeed_or_not(
    #{'_success_count' := SuccCnt} = NodeDef,
    WsName
) when SuccCnt > 0 ->
    node_status(WsName, NodeDef, <<"assert succeed">>, "green", "ring");
succeed_or_not(#{'_failures' := FailureLst} = NodeDef, WsName) ->
    case count_failures(FailureLst, 0) of
        0 ->
            node_status(WsName, NodeDef, <<"assert succeed">>, "green", "ring");
        FailureCnt ->
            ErrMsg = jstr("~p check(s) failed", [FailureCnt]),
            node_status(WsName, NodeDef, ErrMsg, "red", "dot"),
            post_final_failures(FailureLst, NodeDef, WsName)
    end.

%%
%%
post_final_failures([], _, _) ->
    done;
post_final_failures([{Msg, Failures} | FailureLst], NodeDef, WsName) ->
    post_failures(Failures, NodeDef, ?AddWsName(Msg)),
    post_final_failures(FailureLst, NodeDef, WsName).

%%
%%
count_failures([], Cnt) ->
    Cnt;
count_failures([{_Msg, Failures} | Lst], Cnt) ->
    count_failures(Lst, Cnt + length(Failures)).

%%
%%
set_node_status(true, NodeDef, #{?GetWsName} = _Msg) ->
    node_status(WsName, NodeDef, <<"assert succeed">>, "green", "ring");
set_node_status(false, NodeDef, #{?GetWsName} = Msg) ->
    ErrMsg = jstr("~p check(s) failed", [maps:get(<<"failure_count">>, Msg)]),
    node_status(WsName, NodeDef, ErrMsg, "red", "dot").

%%
%%
post_failures([], _, _) ->
    done;
post_failures([{unsupported, Rule} | Lst], NodeDef, #{?GetWsName} = Msg) ->
    ErrMsg = jstr("Assert values: unsupported Rule: '~p'", [Rule]),
    %%
    %% Unlike other nodes (i.e. change, switch), this is an assertion
    %% failure. Can't be silently ignoring tests.
    assert_failure(NodeDef, WsName, ErrMsg),
    post_failures(Lst, NodeDef, Msg);
post_failures([{failure, _Rule, ErrMsg} | Lst], NodeDef, #{?GetWsName} = Msg) ->
    this_should_not_happen(
        NodeDef,
        io_lib:format("~p ~p\n", [ErrMsg, Msg])
    ),
    debug(WsName, debug_data(NodeDef, ErrMsg), error),
    post_failures(Lst, NodeDef, Msg).
