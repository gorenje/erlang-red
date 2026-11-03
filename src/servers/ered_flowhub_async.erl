-module(ered_flowhub_async).

-behaviour(gen_server).

%% gen_server interface
-export([
    init/1,
    code_change/3,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    stop/0,
    start_link/0
]).

%% actually functionality
-export([
    push_flow/2
]).

%%
%% This makes the push to FlowHub interactions async. Communications is done
%% using the websocket to the client.
%%

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%
%%
init([]) ->
    {ok, #{}}.

%%
%% API implementaion
-spec push_flow(WsName :: atom(), PushDetails :: map()) -> ok.
push_flow(none, _PushDetails) ->
    {error, <<"No websocket name">>};
push_flow(WsName, PushDetails) ->
    gen_server:cast(?MODULE, {push_off_flow, WsName, PushDetails}),
    {ok, <<"queued">>}.

%%
handle_call(_Msg, _From, Store) ->
    {reply, ok, Store}.

stop() ->
    gen_server:cast(?MODULE, stop).

%%
%%
terminate(normal, _State) ->
    ok;
terminate(Event, _State) ->
    io:format("Config Store Terminated with {{{ ~p }}}~n", [Event]),
    ok.

handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast({push_off_flow, WsName, PushDetails}, Store) ->
    push_off_flowdata(WsName, PushDetails),
    {noreply, Store};
handle_cast(_Msg, Store) ->
    {noreply, Store}.

%%
handle_info(stop, Store) ->
    gen_server:cast(?MODULE, stop),
    {noreply, Store}.

code_change(_OldVersion, Store, _Extra) ->
    {ok, Store}.

%%
%% --------------------- helpers
%%
push_off_flowdata(WsName, SubmitData) ->
    {FlowId, FlowData, FlowLabel, SvgData, NodeDetails, CfgNode, FlwDataB64} =
        case SubmitData of
            #{
                <<"flowid">> := FId,
                <<"flowlabel">> := Flbl,
                <<"flowdata">> := FDta,
                <<"svgdata">> := Svg,
                <<"cfgnode">> := Cfg,
                <<"nodedetails">> := ND,
                <<"c64fd">> := FlowDataAsBase64
            } ->
                {FId, FDta, Flbl, Svg, ND, Cfg, FlowDataAsBase64};
            _ ->
                io:format("Missing data in: ~p~n", [SubmitData]),
                {error, <<"">>, <<"">>, <<"">>, <<"">>}
        end,

    %% Create the submit body for the server side
    {PushComment, ForcePush, CreateNewFlow} =
        case CfgNode of
            #{
                <<"pushcomment">> := PCmt,
                <<"pushnewflows">> := CreateNew,
                <<"forcepush">> := FP
            } ->
                {PCmt, FP, CreateNew};
            _ ->
                io:format("Missing config in: ~p~n", [CfgNode]),
                {<<"">>, <<"false">>, <<"false">>}
        end,

    Revision =
        case CfgNode of
            #{<<"flowrevisions">> := #{FlowId := R}} -> R;
            _ -> <<"">>
        end,

    CommitDate =
        case SubmitData of
            #{<<"commit_date">> := CDt} -> CDt;
            _ -> <<"">>
        end,

    {HostName, Token} =
        case CfgNode of
            #{<<"apiToken">> := T} ->
                ered_http_utils:flowhub_hostname_from_token(T)
        end,

    PostBody = #{
        <<"flowid">> => FlowId,
        <<"flowdata">> => FlowData,
        <<"flowlabel">> => FlowLabel,
        <<"svgdata">> => SvgData,
        <<"nodedetails">> => NodeDetails,
        <<"flowrevision">> => Revision,
        <<"pushcomment">> => PushComment,
        <<"pushnewflows">> => CreateNewFlow,
        <<"forcepush">> => ForcePush,
        <<"commit_date">> => CommitDate,
        <<"base64flowdata">> => FlwDataB64
    },

    ResponseBody =
        case
            httpc:request(
                post,
                {
                    list_to_binary(io_lib:format("~s/v1/flows", [HostName])),
                    [
                        {"FlowHub-API-Version", "Redeel"},
                        {"Authorization",
                            list_to_binary(io_lib:format("Bearer ~s", [Token]))},
                        {"X-FHB-TOKEN", Token}
                    ],
                    "application/json; charset=utf-8",
                    ered_messages:encode_json(PostBody)
                },
                [{timeout, 25000}, {ssl, [{verify, verify_none}]}],
                []
            )
        of
            {ok, {_StatusLine, _Headers, RespBody}} ->
                RespBody;
            Res ->
                io:format("Error checking token: ~p~n", [Res]),
                <<"{ \"status\": \"error\", \"msg\": \"nope\" }">>
        end,

    case Obj = json:decode(list_to_binary(ResponseBody)) of
        #{<<"status">> := <<"failed">>, <<"msg">> := Msg} ->
            WsName ! flowhub_submit_result(error, Msg, Obj);
        #{<<"status">> := <<"nochange">>} ->
            Msg = <<"succeed but no change">>,
            WsName ! flowhub_submit_result(warning, Msg, Obj);
        #{<<"status">> := <<"ok">>} ->
            Msg = <<"flow submission succeed">>,
            WsName ! flowhub_submit_result(success, Msg, Obj);
        _ ->
            io:format("FlowHubPush: Unknown response: ~p~n", [Obj]),
            Msg = <<"unknown response">>,
            WsName ! flowhub_submit_result(error, Msg, Obj)
    end.

%%
%% Before sending the response obj, rename the revision value to flowrevision
%%
flowhub_submit_result(Type, Msg, Obj = #{<<"revision">> := Rev}) ->
    {flowhub_submit_result, Type, Msg, Obj#{<<"flowrevision">> => Rev}};
flowhub_submit_result(Type, Msg, Obj) ->
    {flowhub_submit_result, Type, Msg, Obj}.
