-module(ered_cfg_storage).

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
    start_link/1
]).

%% actually functionality. This is used internally by ered_config_store
%% which calls handle_call(..) directly.
-export([]).

%%
%% Store for maintaining a collection of config nodes. These can be referenced
%% by those nodes that need them.
%%
%% Config nodes are used in Node-RED to share configuration of services
%% amongst many nodes. For example external network protocols (e.g. MQTT,
%% websocket) have a single configuration node and many nodes that use that
%% configuration.
%%
%% This store only has a store and retrieve API, there is no update and a
%% store call will overwrite any existing config node.
%%
-import(ered_nodes, [
    jstr/2
]).

start_link(WsName) ->
    gen_server:start_link(?MODULE, WsName, []).

%%
%%
init(WsName) ->
    erlang:register(binary_to_atom(jstr("cfg_storage_~s", [WsName])), self()),
    {ok, #{}}.

%%
handle_call(
    {store_config, NodeId, <<"mqtt-broker">>,
        #{<<"credentials">> := Creds} = NodeDef},
    _From,
    ConfigStore
) ->
    %% mqtt brokers have a <<"credentials">> hash that might or might not be
    %% set. If its not set but we have something stored, then no change. If
    %% the <<"user">> is set, then we update the user in our store.
    %% If <<"password">> is set, then we update the password in our store.
    %% Is either empty, we remove them from our store.
    %% Is there no value set for the config node, then just store what we
    %% get.
    case maps:find(NodeId, ConfigStore) of
        {ok, #{<<"credentials">> := OldCreds}} ->
            NodeDef2 = NodeDef#{
                <<"credentials">> => merge_creds(OldCreds, Creds)
            },
            {reply, ok, maps:put(NodeId, NodeDef2, ConfigStore)};
        _ ->
            {reply, ok, maps:put(NodeId, NodeDef, ConfigStore)}
    end;
%
handle_call(
    {store_config, NodeId, <<"mqtt-broker">>, NodeDef},
    _From,
    ConfigStore
) ->
    %% This the case that no credentials were provided, that means we do
    %% no update to an existing credentials hash, if there is an existing
    %% entry in our store.
    case maps:find(NodeId, ConfigStore) of
        {ok, #{<<"credentials">> := OldCreds}} ->
            NodeDef2 = NodeDef#{<<"credentials">> => OldCreds},
            {reply, ok, maps:put(NodeId, NodeDef2, ConfigStore)};
        _ ->
            {reply, ok, maps:put(NodeId, NodeDef, ConfigStore)}
    end;
%
handle_call({store_config, NodeId, _NodeType, NodeDef}, _From, ConfigStore) ->
    ConfigStoreNew = maps:put(NodeId, NodeDef, ConfigStore),
    {reply, ok, ConfigStoreNew};
%
handle_call({get_config, NodeId}, _From, ConfigStore) ->
    Reply =
        case maps:find(NodeId, ConfigStore) of
            {ok, Cfg} ->
                {ok, Cfg};
            _ ->
                unavailble
        end,
    {reply, Reply, ConfigStore};
handle_call(_Msg, _From, Store) ->
    {reply, Store, Store}.

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
handle_cast(_Msg, Store) ->
    {noreply, Store}.

%%
handle_info(stop, Store) ->
    gen_server:cast(?MODULE, stop),
    {noreply, Store}.

code_change(_OldVersion, Store, _Extra) ->
    {ok, Store}.

%%
%% ----------------- helpers
%%
merge_creds(
    _OldCreds,
    #{<<"user">> := <<>>, <<"password">> := <<>>} = _NewCreds
) ->
    #{};
merge_creds(
    _OldCreds,
    #{<<"user">> := User, <<"password">> := <<>>} = _NewCreds
) ->
    #{<<"user">> => User};
merge_creds(
    _OldCreds,
    #{<<"user">> := _User, <<"password">> := _Password} = NewCreds
) ->
    NewCreds;
merge_creds(
    #{<<"user">> := _, <<"password">> := Password} = _OldCreds,
    #{<<"user">> := User} = _NewCreds
) ->
    #{<<"user">> => User, <<"password">> => Password};
merge_creds(
    #{<<"user">> := User, <<"password">> := _} = _OldCreds,
    #{<<"password">> := Password} = _NewCreds
) ->
    #{<<"user">> => User, <<"password">> => Password};
merge_creds(
    OldCreds,
    #{} = _NewCreds
) ->
    OldCreds.
