-module(ered_user_settings_store).

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
%% This store manages the settings/user.json file.
%%

-export([
    store/1,
    retrieve/0
]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, load_initial_settings()}.

%%
%%
-spec store(Settings :: map()) -> ok.
store(Settings) ->
    gen_server:call(?MODULE, {store, Settings}).

%%
-spec retrieve() -> map() | none.
retrieve() ->
    gen_server:call(?MODULE, {retrieve}).

%%
%%
handle_call({store, Settings}, _From, State) ->
    {reply, ok, State#{store => Settings}, {continue, store_file}};
%
handle_call({retrieve}, _From, #{store := Settings} = State) ->
    {reply, Settings, State};
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
    store_settings_to_disk(State),
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
    io:format("User Settings Store Terminated with {{{ ~p }}}~n", [Event]),
    ok.

%%
%% ----------------- helpers
%%
load_initial_settings() ->
    DefaultFilename =
        filename:join(
            code:priv_dir(erlang_red),
            "node-red-frontend/settings/user.json"
        ),

    FileName = filename:join(ered_flow_store:store_flow(), "user.json"),

    case filelib:is_regular(FileName) of
        false ->
            case filelib:is_regular(DefaultFilename) of
                false ->
                    #{store => #{}};
                true ->
                    {ok, JsonString} = file:read_file(DefaultFilename),
                    #{store => json:decode(JsonString)}
            end;
        true ->
            {ok, JsonString} = file:read_file(FileName),
            #{store => json:decode(JsonString)}
    end.

store_settings_to_disk(#{store := Settings} = _State) ->
    FileName = filename:join(ered_flow_store:store_flow(), "user.json"),

    case file:write_file(FileName, json:encode(Settings)) of
        ok ->
            done;
        R ->
            %% depending on the error, apply some retry logic here
            io:format("FILE SAVING FAILED: ~s --> ~p~n", [FileName, R])
    end.
