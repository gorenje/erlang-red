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

%
%%%%% store_config
%
handle_call(
    {store_config, #{<<"id">> := NodeId} = NodeDef},
    _From,
    ConfigStore
) ->
    NewConfigStore =
        case
            merge(
                error_to_none(maps:find(<<"credentials">>, NodeDef)),
                ered_credentials_store:retrieve(NodeId),
                creds_from_store(maps:find(NodeId, ConfigStore))
            )
        of
            {update_stores, Creds} ->
                ered_credentials_store:store(NodeId, Creds),
                maps:put(
                    NodeId,
                    NodeDef#{<<"credentials">> => Creds},
                    ConfigStore
                );
            delete_stores ->
                ered_credentials_store:remove(NodeId),
                maps:put(
                    NodeId,
                    maps:remove(<<"credentials">>, NodeDef),
                    ConfigStore
                );
            no_credentials ->
                maps:put(NodeId, NodeDef, ConfigStore)
        end,

    {reply, ok, NewConfigStore};
%
%%%%% get_config
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
%
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

%%
%%
creds_from_store({ok, #{<<"credentials">> := Creds}}) ->
    Creds;
creds_from_store(_) ->
    none.
%%
%%
error_to_none({ok, Creds}) ->
    Creds;
error_to_none(_) ->
    none.

%%
%% What happen here?
%%
%%    Credentials defined in ...
%%
%%    | this Store | NodeDef | Creds Store |
%%    | -----------+---------+-------------|
%%    |      -     |   Yes   |     -       | --> Update Stores
%%    |     Yes    |   Yes   |     -       | --> Compare NodeDef to store and update both stores
%%    |     Yes    |    -    |     -       | --> update cred store
%%    |     Yes    |    -    |    Yes      | --> update store from cred store (initialisation)
%%    |     Yes    |   Yes   |    Yes      | --> update cred store with nodedef and update both stores
%%    |      -     |   Yes   |    Yes      | --> update the creds store with data from NodeDef and then updatet this store.
%%    |      -     |    -    |    Yes      | --> update this store with credentils from cred store (initialisation)
%%    |      -     |    -    |     -       | --> store nodedef in this store, no change in cred store
%%
%% When the initial load of the flow happens, the creds store has already been
%% filled. What we want to do here is have all the credentials in this store
%% as this store is used by other nodes to configure their services.
%%
%% All updates of the config nodes go through here. All initialisations
%% goes over this. So this is the final point of unity betwee all three
%% sources of credential information.
%%
%% Basically the creds store is used to update this store on initialisation,
%% when something is changed, this store is update and the credentials store.
%% This duplication is useful because the creds store is responsible for
%% maintaining the flows_cred.json file which is used at initialisation to
%% update this store.
%%
merge(none, none, none) ->
    no_credentials;
merge(none, none, _) ->
    delete_stores;
merge(none, CredsFromCredsStore, _) ->
    {update_stores, CredsFromCredsStore};
merge(Creds, none, none) ->
    {update_stores, Creds};
merge(CredsNodeDef, none, CredsFromCfgStore) ->
    {update_stores, maps:merge(CredsFromCfgStore, CredsNodeDef)};
merge(CredsNodeDef, CredsStore, _CredsFromCfgStore) ->
    {update_stores, maps:merge(CredsStore, CredsNodeDef)}.
