-module(ered_websocket_manager).

-behaviour(gen_server).

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

-export([
    listen_to/2
]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #{}}.

%%
%%
stop() ->
    gen_server:cast(?MODULE, stop).

terminate(normal, _State) ->
    ok;
terminate(Event, _State) ->
    io:format("Websocket Manager Terminated with {{{ ~p }}}~n", [Event]),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%%
%%
-spec listen_to(
    UriMap :: uri_string:uri_map(),
    NodePid :: pid()
) ->
    ok | {error, Reason :: atom()}.
listen_to(UriMap, NodePid) ->
    gen_server:call(?MODULE, {listen_and_send_to, UriMap, NodePid}).

%%
%%
handle_call({listen_and_send_to, UriMap, NodePid}, _From, State) ->
    %% TODO here existing connections should be reused by checking the UriMap
    %% TODO details and maintaining a lookup table.
    NewState =
        case ered_websocket_listener:start(UriMap, self()) of
            {ok, ConnPid} ->
                State#{ConnPid => NodePid};
            {error, _Reason} ->
                State;
            _ ->
                State
        end,
    {reply, ok, NewState};
handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

%%
%% Catch all.
handle_cast(_Msg, State) ->
    {noreply, State}.

%%
%%
handle_info({websocket_connect, ConnPid}, State) ->
    case State of
        #{ConnPid := NodePid} -> NodePid ! {websocket, connected};
        _ -> ignore
    end,
    {noreply, State};
handle_info({websocket_disconnect, ConnPid}, State) ->
    case State of
        #{ConnPid := NodePid} -> NodePid ! {websocket, disconnected};
        _ -> ignore
    end,
    {noreply, State};
handle_info({websocket_frame, ConnPid, {text, Text}}, State) ->
    #{ConnPid := NodePid} = State,
    NodePid ! {websocket, {frame, Text}},
    {noreply, State};
handle_info({gun_up, ConnPid, _Protocol}, State) ->
    %% this is sent because the gun:open happens before the spawn in the
    %% ered_websocket_listener:start call. The mapping is probably not set
    %% yet but if it happens to be, then pass up the message.
    case State of
        #{ConnPid := NodePid} -> NodePid ! {websocket, connecting};
        _ -> ignore
    end,
    {noreply, State};
handle_info({gun_down, ConnPid, _Protocol, _Reason, _SomethingElse}, State) ->
    case State of
        #{ConnPid := NodePid} -> NodePid ! {websocket, disconnected};
        _ -> ignore
    end,
    {noreply, State};
handle_info(E, State) ->
    io:format("Websocket Manager: Unhandled ~p~n", [E]),
    {noreply, State}.
