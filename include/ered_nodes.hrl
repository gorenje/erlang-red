%% Avoid a "Warning: expression updates a literal" warning when using this
%% macro on a Hash directly, i.e., ?PUT_WS(#{....})
%% inspired by
%%     https://github.com/WhatsApp/erlfmt/issues/353#issuecomment-1957166129
-define(AddWsName(Map), begin
    Map
end#{
    '_ws' => WsName
}).
-define(GetWsName, '_ws' := WsName).
-define(SetWsName, '_ws' => WsName).
-define(WsNameIsSet, '_ws' := _WsName).

%%
%% Check for supervision
-define(IsBeingSupervised, '_being_supervised' := true).
-define(SetBeingSupervised, '_being_supervised' => true).

-define(NodeStatus(EM, CLR, SHP), node_status(WsName, NodeDef, EM, CLR, SHP)).

%%
%% Message types
%%
-define(StopEvent, {stop, _WsName}).
-define(MSG_INCOMING, {incoming, Msg}).
-define(MSG_REGISTERED, {registered, WsName, NodePid}).

-define(NodePid, '_node_pid_' := NodePid).
-define(GetNodePid, '_node_pid_' := NodePid).

-define(GetPayload, <<"payload">> := Payload).
-define(PayloadIsSet, <<"payload">> := _Payload).
-define(SetPayload, <<"payload">> => Payload).
-define(AddPayload(V), <<"payload">> => V).

-define(AddTopic(V), <<"topic">> => V).
-define(GetTopic, <<"topic">> := Topic).
-define(SetTopic, <<"topic">> => Topic).

-define(GetIdStr, <<"id">> := IdStr).
-define(GetTypeStr, <<"type">> := TypeStr).

-define(AddParts(V), <<"parts">> => V).

-define(PostExceptionOrDebug(E,F,S), begin
    ErrMsg2 = jstr("Exception: ~p ~p", [E, F]),
    post_exception_or_debug(
        NodeDef,
        ?AddWsName(#{
            <<"stacktrace">> => S
        }),
        ErrMsg2
    )
end).

-define(TopicFrom(Msg), begin
    ToBinary = fun
        (V) when is_list(V) -> list_to_binary(V);
        (V) when is_integer(V) -> integer_to_binary(V);
        (V) -> V
    end,
    case maps:find(<<"topic">>, Msg) of
        {ok, Val2} -> ToBinary(Val2);
        _ -> <<"">>
    end
end).

-define(ObtainFrom(NodeDef), begin
    {Zstr, IdStr, Type} =
        case NodeDef of
            #{
                <<"z">> := Zstr2,
                <<"id">> := IdStr2,
                <<"type">> := Type2
            } ->
                {Zstr2, IdStr2, Type2};
            #{
                <<"id">> := IdStr2,
                <<"type">> := Type2
            } ->
                {<<"config node">>, IdStr2, Type2}
        end,

    Name =
        case maps:find(<<"name">>, NodeDef) of
            {ok, Val} when Val =:= <<"">>; Val =:= "" -> Type;
            {ok, Val} -> Val;
            _ -> Type
        end,

    #{
        <<"z">> => Zstr,
        <<"id">> => IdStr,
        <<"path">> => Zstr,
        <<"name">> => Name
    }
end).
