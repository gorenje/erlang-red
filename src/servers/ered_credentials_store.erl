-module(ered_credentials_store).

-behaviour(gen_server).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    handle_continue/2,
    terminate/2,
    code_change/3,
    stop/0,
    start_link/0
]).

%%
%% This service maintains and manages the 'flows_cred.json' file that contains
%% credential information for config nodes. This is sensitive data such as
%% logins and passwords. Each config node has it's own collection of
%% credentials. This service stores all of them.
%%
%% This service uses a non-password, human friendly storage mechanism - similar
%% to what Node-RED 3.x used to do. This is done out of pure laziness and not
%% stupidity - storing sensitive credentinals in non-encrypt form is stupid but
%% also lazy.
%%
%% There is a credentials secret in the settings.js but since Erlang-Red does
%% not - yet - support a settings.js, there is no way to set a secret so
%% that's why this initial implementation does not encryptian. That will remain
%% like that until this comment is removed (and encryptian got implemented!)
%%
%% flows_cred.json is stored in the form:
%% ```
%% {
%%     <confignodeid>: {
%%           <credentails hash contents>
%%     }
%% }
%% ```
%%
%% TODO WARNING this isn't websocket save, this will leak credentials across
%% TODO WARNING connections. This is really a local feature, not a global
%% TODO WARNING supportable feature.
%%

-export([
    store/2,
    retrieve/1,
    retrieve/2,
    remove/1
]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, load_initial_credentials()}.

%%
%%
-spec store(NodeId :: binary(), Creds :: map()) -> ok.
store(NodeId, Creds) ->
    gen_server:call(?MODULE, {store, NodeId, Creds}).

remove(NodeId) ->
    gen_server:call(?MODULE, {remove, NodeId}).

%%
%% TODO: ignore WsName here, should fix that but there is only
%% TODO: only one flows_cred.json file.
-spec retrieve(NodeId :: binary(), WsName :: atom()) -> map() | none.
retrieve(NodeId, _WsName) ->
    gen_server:call(?MODULE, {retrieve, NodeId}).

-spec retrieve(NodeId :: binary()) -> map() | none.
retrieve(NodeId) ->
    gen_server:call(?MODULE, {retrieve, NodeId}).

%%
%%
handle_call({remove, NodeId}, _From, #{store := Store} = State) ->
    {reply, ok, State#{store => maps:remove(NodeId, Store)},
        {continue, store_file}};
handle_call({store, NodeId, Creds}, _From, #{store := Store} = State) ->
    {reply, ok, State#{store => Store#{NodeId => Creds}},
        {continue, store_file}};
%
handle_call({retrieve, NodeId}, _From, #{store := Store} = State) ->
    case maps:find(NodeId, Store) of
        {ok, Creds} ->
            {reply, Creds, State};
        _ ->
            {reply, none, State}
    end;
%
handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

%%
%%
handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Msg, Store) ->
    {noreply, Store}.

%%
%%
handle_info(_, State) ->
    {noreply, State}.

%%
%%
handle_continue(store_file, State) ->
    store_credentials_to_disk(State),
    {noreply, State}.
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
%% ----------------- helpers
%%
load_initial_credentials() ->
    FileName = filename:join(ered_flow_store:store_flow(), "flows_cred.json"),

    case filelib:is_regular(FileName) of
        false ->
            #{store => #{}};
        true ->
            {ok, JsonString} = file:read_file(FileName),
            #{store => json:decode(JsonString)}
    end.

store_credentials_to_disk(#{store := Hsh} = _State) ->
    FileName = filename:join(ered_flow_store:store_flow(), "flows_cred.json"),

    case file:write_file(FileName, json:encode(Hsh)) of
        ok ->
            done;
        R ->
            %% depending on the error, apply some retry logic here
            io:format("FILE SAVING FAILED: ~s --> ~p~n", [FileName, R])
    end.
