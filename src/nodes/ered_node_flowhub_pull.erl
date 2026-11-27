-module(ered_node_flowhub_pull).

-include("ered_nodes.hrl").
-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% FlowHub node is designed to retrieve flows for usage within a flow.
%%
%% It allows for meta programming by maintaining code in one instance while
%% installing that code in another instance. Or by using code to create
%% packages much as the unittesting node package is created.
%%
%% {
%%     "type": "FlowHubPull",
%%     "name": "[captureio] Mutliple captures",
%%     "notab": false, <<---- (deprecated) used to indicate whether a new tab
%%                         -- should be created or not
%%     "flowid": "f676c708bde42a8d", <<---- flow to retrieve
%%     "flowname": "[captureio] Mutliple captures",
%%     "flowrevision": "", <<<---- revision of flow to use (if any)
%%     "wires": [
%%         [
%%             "9474fed0595c80c8" <<--- node details wires
%%         ],
%%         [
%%             "21e8690ddbda0c61" <<<----- flow data wires
%%         ]
%%     ]
%% },
%%
-import(ered_nodes, [
    jstr/1,
    jstr/2,
    send_msg_on/2,
    get_prop_value_from_map/3
]).

-import(ered_messages, [
    to_bool/1
]).

-import(ered_nodered_comm, [
    node_status/5,
    node_status_clear/2,
    post_exception_or_debug/3,
    ws_from/1
]).

%%
%%
start(NodeDef, WsName) ->
    ered_node:start(?AddWsName(NodeDef), ?MODULE).

%%
%%
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg({incoming, Msg}, NodeDef) ->
    Tkn = obtain_token(),
    {HostName, Token} = ered_http_utils:flowhub_hostname_from_token(Tkn),
    handle_retrieve_and_pass_on_flowdata(HostName, Token, Msg, NodeDef);
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% --------------------- helpers
%%
handle_retrieve_and_pass_on_flowdata(
    HostName,
    Token,
    Msg,
    #{?GetWsName, <<"wires">> := [NodeDetailsWires | FlowDataWires]} = NodeDef
) ->
    {FlowId, Revision} = obtain_flowid_and_revision(Msg, NodeDef),

    case
        json:decode(
            ered_http_flowhub_pull:retrieve_flowdata(
                HostName,
                Token,
                FlowId,
                Revision
            )
        )
    of
        #{<<"flowdata">> := FlowData, <<"nodedetails">> := NodeDetails} ->
            node_status_clear(WsName, NodeDef),
            Msg2 = Msg#{
                ?AddPayload(json:decode(FlowData)),
                ?AddTopic(<<"flowjson">>)
            },
            send_msg_on(FlowDataWires, Msg2),
            Msg3 = Msg#{
                ?AddPayload(json:decode(NodeDetails)),
                ?AddTopic(<<"packages">>)
            },
            send_msg_on(NodeDetailsWires, Msg3);
        Other ->
            access_denied_status(NodeDef, Token, WsName),
            ErrMsg = jstr(
                "Flow id not found: ~p / ~p / ~p",
                [FlowId, Other, Token]
            ),
            post_exception_or_debug(NodeDef, Msg, ErrMsg)
    end,
    {handled, NodeDef, Msg}.

%%
%% Retrieve the flowid and revision from either the Msg or the NodeDef (i.e,
%% the node configuration). Default is what is set in the node configuration,
%% but if the Msg map carries either value (flowid or revision) then those
%% values override the node configuration values.
-spec obtain_flowid_and_revision(
    Msg :: map(), NodeDef :: map()
) -> {FlowId :: binary() | unknown, FlowRevision :: binary() | unknown}.
obtain_flowid_and_revision(Msg, NodeDef) ->
    {
        non_unknown(obtain_flowid(Msg), obtain_flowid(NodeDef)),
        non_unknown(obtain_flowrevision(Msg), obtain_flowrevision(NodeDef))
    }.
%%
obtain_flowid(M) ->
    get_prop_value_from_map(<<"flowid">>, M, unknown).
%%
obtain_flowrevision(M) ->
    get_prop_value_from_map(<<"flowrevision">>, M, unknown).
%%
non_unknown(unknown, unknown) ->
    unknown;
non_unknown(unknown, F) ->
    F;
non_unknown(F, _) ->
    F.

%%
obtain_token() ->
    obtain_token(maps:to_list(ered_credentials_store:retrieve_all())).
%%
obtain_token([]) ->
    <<"">>;
obtain_token([{_NodeId, #{<<"apiToken">> := Token}} | _Rest]) ->
    Token;
obtain_token([_ | Rest]) ->
    obtain_token(Rest).

%%
%%
access_denied_status(NodeDef, Token, WsName) ->
    node_status(
        WsName,
        NodeDef,
        jstr("access denied, for ~p", [truncate(Token)]),
        "red",
        "dot"
    ).

%%
%%
truncate(Bin) when is_binary(Bin) ->
    truncate(binary_to_list(Bin));
truncate(Str) when is_list(Str) ->
    truncate(Str, string:length(Str)).
truncate(Str, Leng) when Leng > 30 ->
    jstr("~s...", [string:slice(Str, 0, 30)]);
truncate(Str, _Leng) ->
    Str.
