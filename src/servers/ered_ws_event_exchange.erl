-module(ered_ws_event_exchange).

-behaviour(gen_server).

%%
%% This service distributes websocket events to listeners. These listeners are
%% unit test assertors that ensure that specific things happen that specific
%% nodes promised to do. This is not a store of events, rather a bus that
%% passes events on to listeners - these listeners check the events and
%% potentially cause unit tests to fail.
%%
%% Listeners are scoped by websocket name, with each event (debug and status)
%% store being a map of lists of callbacks. The map is indexed by NodeId, i.e
%% the target node that is expected to generate an event (or not generate an
%% websocket event). The two main users of this are assert_debug and
%% assert_status testing nodes.
%%
%% Assert status and debug subscribe to this server with the NodeId of the
%% node that they are checking. Hence the data structure here.
%%
%% Assert nodes subscribe with a Cb - callback but not a callback, In fact
%% that is the named process id of their process. It is an atom of the form
%% `node_pid_ws<name>_<nodeid>` - this is used to handle the unsubscribe
%% call. It removes the Cb from all lists.
%%
-export([init/1, handle_call/3, handle_cast/2]).
-export([handle_info/2, terminate/2, code_change/3]).
-export([stop/0, start/0]).

%% subscribe to specific events
-export([subscribe/4]).
-export([subscribe/5]).

%% generate events as websocket calls are made
-export([node_status/5]).
-export([debug_msg/3]).

%% unscribe the listeners
-export([unsubscribe/2]).
-export([remove_ws/1]).
-export([clear/0]).

%% for testing
-export([getstore/0]).

%%
%%%%%
%%%
start() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

debug_msg({ok, WsName}, Type, #{<<"id">> := NodeId} = Data) ->
    gen_server:call(?MODULE, {debug_event, WsName, NodeId, Type, Data});
debug_msg(_, _, _) ->
    ignore.

node_status({ok, WsName}, NodeId, Txt, Clr, Shp) ->
    gen_server:call(?MODULE, {status_event, WsName, NodeId, Txt, Clr, Shp});
node_status(_, _, _, _, _) ->
    ignore.

%%
%%
subscribe(WsName, NodeId, debug, any, Cb) ->
    %% any type is used by an inverse, i.e. the assert debug expects no
    %% debug messages, so it has to listen to all debug message types.
    gen_server:call(?MODULE, {subscribe_to_debug, WsName, NodeId, normal, Cb}),
    gen_server:call(?MODULE, {subscribe_to_debug, WsName, NodeId, warning, Cb}),
    gen_server:call(?MODULE, {subscribe_to_debug, WsName, NodeId, error, Cb});
subscribe(WsName, NodeId, debug, Type, Cb) when is_atom(Type) ->
    gen_server:call(?MODULE, {subscribe_to_debug, WsName, NodeId, Type, Cb});
subscribe(WsName, NodeId, debug, Type, Cb) when is_binary(Type) ->
    gen_server:call(
        ?MODULE, {subscribe_to_debug, WsName, NodeId, binary_to_atom(Type), Cb}
    );
subscribe(_, _, _, _, _) ->
    ignore.

subscribe(WsName, NodeId, status, Cb) ->
    gen_server:call(?MODULE, {subscribe_to_status, WsName, NodeId, Cb});
subscribe(_, _, _, _) ->
    ignore.

unsubscribe(WsName, Cb) ->
    gen_server:call(?MODULE, {unsubscribe, WsName, Cb}).

remove_ws(WsName) ->
    gen_server:call(?MODULE, {remove_ws, WsName}).

clear() ->
    gen_server:call(?MODULE, {clear}).

getstore() ->
    gen_server:call(?MODULE, {get}).

%%
%%
init([]) ->
    {ok, #{status => #{}, debug => #{}}}.

%%
%%
handle_call({debug_event, WsName, NodeId, Type, Data}, _From, SubscriberStore) ->
    {ok, DebugStore} = maps:find(debug, SubscriberStore),
    case maps:find(WsName, DebugStore) of
        {ok, Map} ->
            case maps:find(NodeId, Map) of
                {ok, CbAry} ->
                    List = lists:filter(fun({A, _}) -> A =:= Type end, CbAry),
                    [
                        gen_server:cast(
                            cb_to_pid(Cb),
                            {ws_event, {debug, WsName, NodeId, Type, Data}}
                        )
                     || {_, Cb} <- List
                    ];
                _ ->
                    ignore
            end;
        _ ->
            ignore
    end,

    {reply, ok, SubscriberStore};
handle_call(
    {status_event, WsName, NodeId, Txt, Clr, Shp}, _From, SubscriberStore
) ->
    {ok, StatusStore} = maps:find(status, SubscriberStore),
    case maps:find(WsName, StatusStore) of
        {ok, Map} ->
            case maps:find(NodeId, Map) of
                {ok, CbAry} ->
                    [
                        gen_server:cast(
                            cb_to_pid(Cb),
                            {ws_event, {status, WsName, NodeId, Txt, Clr, Shp}}
                        )
                     || Cb <- CbAry
                    ];
                _ ->
                    ignore
            end;
        _ ->
            ignore
    end,

    {reply, ok, SubscriberStore};
handle_call({subscribe_to_status, WsName, NodeId, Cb}, _From, SubscriberStore) ->
    {ok, StatusStore} = maps:find(status, SubscriberStore),

    case maps:find(WsName, StatusStore) of
        {ok, Map} ->
            case maps:find(NodeId, Map) of
                {ok, Ary} ->
                    %%
                    %% Avoid duplication in the callbacks
                    case lists:member(Cb, Ary) of
                        false ->
                            SStore2 = maps:put(
                                WsName,
                                maps:put(
                                    NodeId,
                                    [Cb | Ary],
                                    Map
                                ),
                                StatusStore
                            );
                        _ ->
                            SStore2 = maps:put(
                                WsName,
                                maps:put(NodeId, Ary, Map),
                                StatusStore
                            )
                    end;
                _ ->
                    SStore2 = maps:put(
                        WsName,
                        maps:put(NodeId, [Cb], Map),
                        StatusStore
                    )
            end;
        _ ->
            SStore2 = maps:put(WsName, maps:put(NodeId, [Cb], #{}), StatusStore)
    end,

    {reply, ok, maps:put(status, SStore2, SubscriberStore)};
handle_call(
    {subscribe_to_debug, WsName, NodeId, Type, Cb}, _From, SubscriberStore
) ->
    {ok, DebugStore} = maps:find(debug, SubscriberStore),

    case maps:find(WsName, DebugStore) of
        {ok, Map} ->
            case maps:find(NodeId, Map) of
                {ok, Ary} ->
                    %%
                    %% Avoid duplication of {Type,Cb} pairs. A callback can
                    %% be registered for the different types but not multiple
                    %% times for the same type.
                    case lists:search(fun(A) -> A == {Type, Cb} end, Ary) of
                        false ->
                            DStore2 = maps:put(
                                WsName,
                                maps:put(
                                    NodeId,
                                    [{Type, Cb} | Ary],
                                    Map
                                ),
                                DebugStore
                            );
                        _ ->
                            DStore2 = maps:put(
                                WsName,
                                maps:put(NodeId, Ary, Map),
                                DebugStore
                            )
                    end;
                _ ->
                    DStore2 = maps:put(
                        WsName,
                        maps:put(NodeId, [{Type, Cb}], Map),
                        DebugStore
                    )
            end;
        _ ->
            DStore2 = maps:put(
                WsName,
                maps:put(NodeId, [{Type, Cb}], #{}),
                DebugStore
            )
    end,

    {reply, ok, maps:put(debug, DStore2, SubscriberStore)};
handle_call({unsubscribe, WsName, Cb}, _From, SubscriberStore) ->
    {ok, DebugStore} = maps:find(debug, SubscriberStore),
    case maps:find(WsName, DebugStore) of
        {ok, Map} ->
            RemoveCb = fun(Ary) ->
                lists:filter(fun({_, V}) -> V /= Cb end, Ary)
            end,
            Map4 = maps:from_list([
                {Key, RemoveCb(Ary)}
             || {Key, Ary} <- maps:to_list(Map)
            ]),
            DebugStore2 = maps:put(WsName, Map4, DebugStore);
        _ ->
            DebugStore2 = DebugStore
    end,
    SubStore2 = maps:put(debug, DebugStore2, SubscriberStore),

    {ok, StatusStore} = maps:find(status, SubscriberStore),
    case maps:find(WsName, StatusStore) of
        {ok, Map2} ->
            RemoveCb2 = fun(Ary) ->
                lists:filter(fun(V) -> V /= Cb end, Ary)
            end,
            Map3 = maps:from_list([
                {Key, RemoveCb2(Ary)}
             || {Key, Ary} <- maps:to_list(Map2)
            ]),

            StatusStore2 = maps:put(WsName, Map3, StatusStore);
        _ ->
            StatusStore2 = StatusStore
    end,
    SubStore3 = maps:put(status, StatusStore2, SubStore2),

    {reply, ok, SubStore3};
handle_call({remove_ws, WsName}, _From, SubscriberStore) ->
    {ok, StatusStore} = maps:find(status, SubscriberStore),
    {ok, DebugStore} = maps:find(debug, SubscriberStore),

    {reply, ok, #{
        status => maps:remove(WsName, StatusStore),
        debug => maps:remove(WsName, DebugStore)
    }};
handle_call({clear}, _From, _SubscriberStore) ->
    {reply, ok, #{status => #{}, debug => #{}}};
handle_call({get}, _From, SubscriberStore) ->
    {reply, SubscriberStore, SubscriberStore};
handle_call(_Msg, _From, SubscriberStore) ->
    {reply, ok, SubscriberStore}.

%%
handle_cast(_Msg, Store) ->
    {noreply, Store}.

%%
handle_info(stop, SubscriberStore) ->
    gen_server:cast(?MODULE, stop),
    {noreply, SubscriberStore};

handle_info(_, SubscriberStore) ->
    {noreply, SubscriberStore}.

code_change(_OldVersion, SubscriberStore, _Extra) ->
    {ok, SubscriberStore}.

stop() ->
    gen_server:cast(?MODULE, stop).

%%
%%
terminate(normal, _State) ->
    ok;
terminate(Event, _State) ->
    io:format("WS event exchange terminated with {{{ ~p }}}~n", [Event]),
    ok.

%%
%%
cb_to_pid(Cb) ->
    case pg:get_members(Cb) of
        [] ->
            spawn(fun() ->
                receive
                    _ -> self()
                end
            end);
        [Pid | []] ->
            Pid;
        [H | _T] ->
            H
    end.
