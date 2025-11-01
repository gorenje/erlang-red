-module(ered_flow_store_server).

-behaviour(gen_server).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3,
    stop/0,
    start/0
]).

-export([
    all_flow_ids/0,
    get_filename/1,
    get_flow_data/0,
    retrieve_main_flow/0,
    update_all_flows/0,
    update_flow/2
]).

%%
%% Manage the collection of test flows in the priv/testflows directory.
%% This manages the retrieval but not storage - which is an inconsistency.
%% Storage is handled directlty in the http request.
%%
-import(ered_flows, [
    parse_flow_file/1,
    compute_timeout/1,
    tab_name_or_filename/2
]).
-import(ered_nodes, [
    jstr/1
]).
-import(ered_messages, [
    encode_json/1
]).

start() ->
    {ok, Pid} = gen_server:start_link({local, ?MODULE}, ?MODULE, [], []),
    %% do an initial load of all flows, after that it should be maintained
    %% by itself.
    erlang:start_timer(200, Pid, initial_load_of_flow_files),
    {ok, Pid}.

init([]) ->
    {ok, #{}}.

%%
%%
get_flow_data() ->
    gen_server:call(?MODULE, {get_store}).

update_all_flows() ->
    gen_server:call(?MODULE, {update_all}).

update_flow(FlowId, Filename) ->
    gen_server:call(?MODULE, {update_one, FlowId, Filename}).

get_filename(FlowId) when is_list(FlowId) ->
    get_filename(list_to_binary(FlowId));
get_filename(FlowId) ->
    gen_server:call(?MODULE, {filename, FlowId}).

all_flow_ids() ->
    gen_server:call(?MODULE, {all_flow_ids}).

retrieve_main_flow() ->
    gen_server:call(?MODULE, {retrieve_main_flow}).

%%
%% Specific implementation for the flow store
%%
handle_call({all_flow_ids}, _From, FlowStore) ->
    %% sort flow ids by timeout
    AllFlowIds =
        lists:map(
            fun({V, _}) -> V end,
            lists:sort(
                fun(
                    {_, #{timeout := V1}},
                    {_, #{timeout := V2}}
                ) ->
                    V1 > V2
                end,
                maps:to_list(FlowStore)
            )
        ),

    {reply, AllFlowIds, FlowStore};
handle_call({update_all}, _From, _FlowStore) ->
    {reply, true, compile_file_store(compile_file_list(), #{})};
handle_call({update_one, FlowId, Filename}, _From, FlowStore) ->
    FlowDetails = compile_file_store([{FlowId, Filename}], #{}),
    {reply, true, maps:merge(FlowStore, FlowDetails)};
handle_call({get_store}, _From, FlowStore) ->
    %% beacuse the path attribute exposes internal pathways, strip it
    %% off before responding - this call is used for the frontend, i.e.
    %% it's going beyond the bounds of the four walls of the application.
    List = maps:to_list(FlowStore),
    RemoveDir = fun({ok, Path}) ->
        filename:basename(Path)
    end,
    ListStriped = [
        {Key, maps:put(path, RemoveDir(maps:find(path, M)), M)}
     || {Key, M} <- List
    ],
    {reply, maps:from_list(ListStriped), FlowStore};
handle_call({filename, FlowId}, _From, FlowStore) ->
    case maps:find(FlowId, FlowStore) of
        {ok, Val} ->
            case maps:find(path, Val) of
                {ok, Path} ->
                    {reply, Path, FlowStore};
                _ ->
                    {reply, error, FlowStore}
            end;
        _ ->
            {reply, error, FlowStore}
    end;
handle_call({retrieve_main_flow}, _From, FlowStore) ->
    SrcFileName = io_lib:format(
        "~s/flows.json",
        [code:priv_dir(erlang_red)]
    ),

    {reply, file:read_file(SrcFileName), FlowStore};
handle_call(_Msg, _From, FlowStore) ->
    {reply, FlowStore, FlowStore}.

%%
%%
handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Msg, Store) ->
    {noreply, Store}.

%%
%%
handle_info({store_main_flow, FlowData}, State) ->
    {ok, NodeAryWithCreds} = maps:find(<<"flows">>, json:decode(FlowData)),

    %% remove any reference to <<"credentials">>
    NodeAry = remove_credentials(NodeAryWithCreds),

    DestFileName = io_lib:format(
        "~s/flows.json",
        [code:priv_dir(erlang_red)]
    ),

    filelib:ensure_dir(DestFileName),
    case file:write_file(DestFileName, encode_json(NodeAry)) of
        ok ->
            ignore_all_went_well;
        R ->
            io:format(
                "FILE SAVING FAILED: ~s --> ~p~n",
                [DestFileName, R]
            )
    end,

    {noreply, State};
handle_info({store_flow, FlowId, JsonText}, FlowStore) ->
    FlowMap = json:decode(JsonText),
    {ok, NodeAryWithCreds} = maps:find(<<"flow">>, FlowMap),

    %% remove any reference to <<"credentials">>
    NodeAry = remove_credentials(json:decode(NodeAryWithCreds)),

    DestFileName = io_lib:format(
        "~s/testflows/~s/flows.json",
        [code:priv_dir(erlang_red), FlowId]
    ),

    filelib:ensure_dir(DestFileName),
    case file:write_file(DestFileName, encode_json(NodeAry)) of
        ok ->
            ignore_all_went_well;
        R ->
            io:format(
                "FILE SAVING FAILED: ~s --> ~p~n",
                [DestFileName, R]
            )
    end,

    FlowDetails = compile_file_store(
        [{binary_to_list(FlowId), lists:flatten(DestFileName)}], #{}
    ),

    {noreply, maps:merge(FlowStore, FlowDetails)};
handle_info({timeout, _From, initial_load_of_flow_files}, _FlowStore) ->
    {noreply, compile_file_store(compile_file_list(), #{})};
handle_info(stop, FlowStore) ->
    gen_server:cast(?MODULE, stop),
    {noreply, FlowStore}.

%%
%%
code_change(_OldVersion, ErrorStore, _Extra) ->
    {ok, ErrorStore}.

stop() ->
    gen_server:cast(?MODULE, stop).

%%
%%
terminate(normal, _State) ->
    ok;
terminate(Event, _State) ->
    io:format("Flow Store Terminated with {{{ ~p }}}~n", [Event]),
    ok.

%%
%% --------------- helpers
%%
remove_credentials(NodeAry) ->
    remove_credentials(NodeAry, []).

remove_credentials([], S) ->
    lists:reverse(S);
remove_credentials(
    [#{<<"type">> := <<"FlowHubCfg">>} = NodeDef | Rest], Store
) ->
    remove_credentials(
        Rest,
        [
            NodeDef#{<<"apiToken">> => <<>>, <<"tokens">> => []} | Store
        ]
    );
remove_credentials([NodeDef | Rest], Store) ->
    remove_credentials(Rest, [maps:remove(<<"credentials">>, NodeDef) | Store]).

%%
compile_file_list() ->
    {ok, MP} = re:compile("([A-Z0-9]{16})/flows.json", [caseless]),

    TestFlowDir = io_lib:format("~s/testflows/", [code:priv_dir(erlang_red)]),

    FileNames = filelib:fold_files(
        TestFlowDir,
        "flows.json",
        true,
        fun(Fname, Acc) ->
            case re:run(Fname, MP) of
                {match, [{_, _}, {S, L}]} ->
                    [{string:substr(Fname, S + 1, L), Fname} | Acc];
                _ ->
                    Acc
            end
        end,
        []
    ),
    FileNames.

%% erlfmt:ignore lining stuff up
compile_file_store([], FileStore) ->
    FileStore;
compile_file_store([FileDetails | MoreFileNames], FileStore) ->
    FlowId   = element(1, FileDetails),
    FileName = element(2, FileDetails),
    Ary      = parse_flow_file(FileName),
    TestName = tab_name_or_filename(Ary, FlowId),

    compile_file_store(
        MoreFileNames,
        FileStore#{jstr(FlowId) => #{
            path    => jstr(FileName),
            id      => jstr(FlowId),
            name    => jstr(TestName),
            timeout => compute_timeout(Ary)
        }}
     ).
