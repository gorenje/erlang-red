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

%%
%% Check for supervision
-define(IsBeingSupervised, '_being_supervised' := true).
-define(SetBeingSupervised, '_being_supervised' => true).

-define(NodeStatus(EM, CLR, SHP), node_status(WsName, NodeDef, EM, CLR, SHP)).

%%
%% Message types
%%
-define(MSG_STOP, {stop, _WsName}).
-define(MSG_STOP_WS, {stop, WsName}).
-define(MSG_INCOMING, {incoming, Msg}).
-define(MSG_REGISTERED, {registered, WsName, NodePid}).

-define(NodePid, '_node_pid_' := NodePid).
-define(GetNodePid, '_node_pid_' := NodePid).

-define(GetPayload, <<"payload">> := Payload).
-define(SetPayload, <<"payload">> => Payload).
-define(AddPayload(V), <<"payload">> => V).

-define(AddTopic(V), <<"topic">> => V).
-define(GetTopic, <<"topic">> := Topic).
-define(SetTopic, <<"topic">> => Topic).

-define(GetIdStr, <<"id">> := IdStr).
-define(GetTypeStr, <<"type">> := TypeStr).

-define(AddParts(V), <<"parts">> => V).

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
    #{
        <<"z">> := Zstr,
        <<"id">> := IdStr,
        <<"type">> := Type
    } = NodeDef,

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
