-module(ered_http_nodered_websocket).

-export([init/2]).
-export([websocket_init/1]).
-export([websocket_handle/2]).
-export([websocket_info/2]).
-export([terminate/3]).
-export([ws_send_heartbeat/2]).

-import(ered_nodes, [
    jstr/1,
    jstr/2
]).
-import(ered_nodered_comm, [
    get_websocket_name/0
]).

init(Req, State) ->
    %% runs in a different process so can't send out cookie to sent ws name
    {cowboy_websocket, Req, State, #{idle_timeout => 120000}}.

websocket_handle(_Data, State) ->
    {ok, State}.

websocket_init(State) ->
    %% TODO this won't work for two tabs in the same browser since
    %% TODO the cookie is attached to the host, not the tab. Same server
    %% TODO host, same cookie, same value.

    WsName = get_websocket_name(),
    register(WsName, self()),
    State2 = maps:merge(State, #{wsname => WsName}),

    Millis = erlang:system_time(millisecond),

    erlang:start_timer(
        500,
        WsName,
        json:encode([
            #{topic => hb, data => Millis},
            #{
                topic => <<"notification/runtime-state">>,
                data => #{state => start, deploy => true}
            },
            #{
                topic => <<"cookie/set-wsname">>,
                data => #{name => WsName}
            }
        ])
    ),

    {ok, State2}.

%% This the endpoint that is hit when erlang:start_timer hits the timeout
%% - this causes a loop of sending out heartbeats (hb). node red responds
%% with a 'pong' and that keeps the websocket connected.
websocket_info({timeout, _Ref, Msg}, State) ->
    ws_send_heartbeat(self(), State),
    {reply, {text, Msg}, State};
websocket_info({data, Msg}, State) ->
    {reply, {text, Msg}, State};
%%
%% All the possible debug message that end up in the debug panel.
%% Four types: normal, notice, warning and error, each has a different
%% colour in the debug panel.
websocket_info({debug, Data}, State) ->
    Data2 = maps:put(timestamp, erlang:system_time(millisecond), Data),
    ered_ws_event_exchange:debug_msg(maps:find(wsname, State), normal, Data2),
    Msg = encode_json([#{topic => debug, data => Data2}]),
    {reply, {text, Msg}, State};
websocket_info({notice_debug, Data}, State) ->
    Data2 = maps:put(timestamp, erlang:system_time(millisecond), Data),
    Data3 = maps:put(level, 40, Data2),
    ered_ws_event_exchange:debug_msg(maps:find(wsname, State), notice, Data3),
    Msg = encode_json([#{topic => debug, data => Data3}]),
    {reply, {text, Msg}, State};
websocket_info({warning_debug, Data}, State) ->
    Data2 = maps:put(timestamp, erlang:system_time(millisecond), Data),
    Data3 = maps:put(level, 30, Data2),
    ered_ws_event_exchange:debug_msg(
        maps:find(wsname, State), warning, Data3
    ),
    Msg = encode_json([#{topic => debug, data => Data3}]),
    {reply, {text, Msg}, State};
websocket_info({error_debug, Data}, State) ->
    Data2 = maps:put(timestamp, erlang:system_time(millisecond), Data),
    Data3 = maps:put(level, 20, Data2),
    ered_ws_event_exchange:debug_msg(maps:find(wsname, State), error, Data3),
    Msg = encode_json([#{topic => debug, data => Data3}]),
    {reply, {text, Msg}, State};
%%
%% Clear a previous status
websocket_info({status, NodeId, clear}, State) ->
    Msg = json:encode([
        #{
            topic => jstr("status/~s", [NodeId]),
            data => #{}
        }
    ]),

    %% TODO this isn't sent to the status ered_ws_event_exchange:node because
    %% TODO there does not seem to be a need and there is no API.
    {reply, {text, Msg}, State};
%%
%% Here are the details to the possible values of the status
%% elements.
%%
%% From: https://nodered.org/docs/creating-nodes/status
%%
%% Clr: 'red', 'green', 'yellow', 'blue' or 'grey'
%% Shp: 'ring' or 'dot'.
%%
websocket_info({status, NodeId, Txt, Clr, Shp}, State) ->
    Msg = json:encode([
        #{
            topic => jstr("status/~s", [NodeId]),
            data => #{
                text => jstr(Txt),
                fill => jstr(Clr),
                shape => jstr(Shp)
            }
        }
    ]),

    ered_ws_event_exchange:node_status(
        maps:find(wsname, State),
        NodeId,
        Txt,
        Clr,
        Shp
    ),

    {reply, {text, Msg}, State};
%%
%% Results of a unit test run. The details are sent via a debug message if
%% there were errors.
%%
websocket_info({unittest_results, FlowId, Status}, State) ->
    Msg = json:encode([
        #{
            topic => 'unittesting:testresults',
            data => #{
                flowid => jstr(FlowId),
                status => jstr(Status)
            }
        }
    ]),
    {reply, {text, Msg}, State};
websocket_info(_Info, State) ->
    {ok, State}.

ws_send_heartbeat(Pid, State) ->
    {ok, SInterval} = maps:find(stats_interval, State),
    {ok, WsName} = maps:find(wsname, State),

    Millis = erlang:system_time(millisecond),
    Data_jsonb = json:encode([
        #{topic => hb, data => Millis},
        #{
            topic => <<"cookie/set-wsname">>,
            data => #{name => WsName}
        }
    ]),
    erlang:start_timer(SInterval, Pid, Data_jsonb).

terminate(_Reason, _Req, State) ->
    case maps:find(wsname, State) of
        {ok, WsName} ->
            ered_ws_event_exchange:remove_ws(WsName),
            unregister(WsName);
        _ ->
            ok
    end,
    ok.

%%
%% This is json:encode except that Pids are converted to strings.
%%
encoder([{_, _} | _] = Value, Encode) ->
    json:encode_key_value_list(Value, Encode);
encoder(Other, Encode) when is_pid(Other) ->
    json:encode_value(list_to_binary(pid_to_list(Other)), Encode);
encoder(Other, Encode) ->
    json:encode_value(Other, Encode).

encode_json(Value2) ->
    json:encode(Value2, fun(Value, Encode) -> encoder(Value, Encode) end).
