-module(cowboy_nodered_websocket).

-export([init/2]).
-export([websocket_init/1]).
-export([websocket_handle/2]).
-export([websocket_info/2]).
-export([terminate/3]).
-export([ws_send/2]).

init(Req, State) ->
    {cowboy_websocket, Req, State}.

websocket_handle(_Data, State) ->
    {ok, State}.

websocket_init([{stats_interval, SInterval}]) ->
    ws_send(self(), SInterval),
    register(websocket_pid, self()),
    erlang:start_timer(
      1000,
      websocket_pid,
      jiffy:encode([#{ topic => <<"notification/runtime-state">>,
                       data => #{ state => start,
                                  deploy => true
                                }}])
    ),
    {ok, [{stats_interval, SInterval}]}.

websocket_info({timeout, _Ref, Msg}, [{stats_interval, SInterval}]) ->
    ws_send(self(), SInterval),
    {reply, {text, Msg}, [{stats_interval, SInterval}]};

websocket_info({data, Msg}, [{stats_interval, SInterval}]) ->
    {reply, {text, Msg}, [{stats_interval, SInterval}]};

websocket_info({debug, Data}, [{stats_interval, SInterval}]) ->
    Data2 = maps:put( timestamp, erlang:system_time(millisecond), Data),
    Msg = jiffy:encode([#{ topic => debug, data => Data2 } ]),
    {reply, {text, Msg}, [{stats_interval, SInterval}]};

websocket_info({error_debug, Data}, [{stats_interval, SInterval}]) ->
    Data2 = maps:put( timestamp, erlang:system_time(millisecond), Data),
    Data3 = maps:put( level, 20, Data2),
    Msg = jiffy:encode([#{ topic => debug, data => Data3 } ]),
    {reply, {text, Msg}, [{stats_interval, SInterval}]};

websocket_info({warning_debug, Data}, [{stats_interval, SInterval}]) ->
    Data2 = maps:put( timestamp, erlang:system_time(millisecond), Data),
    Data3 = maps:put( level, 30, Data2),
    Msg = jiffy:encode([#{ topic => debug, data => Data3 } ]),
    {reply, {text, Msg}, [{stats_interval, SInterval}]};

websocket_info({notice_debug, Data}, [{stats_interval, SInterval}]) ->
    Data2 = maps:put( timestamp, erlang:system_time(millisecond), Data),
    Data3 = maps:put( level, 40, Data2),
    Msg = jiffy:encode([#{ topic => debug, data => Data3 } ]),
    {reply, {text, Msg}, [{stats_interval, SInterval}]};


%%
%% Here are the details to the possible values of the status
%% elements.
%%
%% From: https://nodered.org/docs/creating-nodes/status
%%
%% Clr: 'red', 'green', 'yellow', 'blue' or 'grey'
%% Shp: 'ring' or 'dot'.
%%
websocket_info({status, NodeId, Txt, Clr, Shp}, [{stats_interval, SInterval}]) ->
    Msg = jiffy:encode([#{ topic => nodes:jstr("status/~s",[NodeId]),
                           data => #{ text => nodes:jstr(Txt),
                                      fill => nodes:jstr(Clr),
                                      shape => nodes:jstr(Shp)
                                    }}]),
    {reply, {text, Msg}, [{stats_interval, SInterval}]};

%%
%% Results of a unit test run. The details are sent via a debug message if
%% there were errors.
%%
websocket_info({unittest_results, FlowId, Status},
               [{stats_interval, SInterval}]) ->
    Msg = jiffy:encode([#{ topic => 'unittesting:testresults',
                           data => #{ flowid => nodes:jstr(FlowId),
                                      status => nodes:jstr(Status)
                                    }}]),
    {reply, {text, Msg}, [{stats_interval, SInterval}]};

websocket_info(_Info, State) ->
    {ok, State}.

ws_send(Pid, SInterval) ->
    Millis = erlang:system_time(millisecond),
    Data_jsonb = jiffy:encode([#{ topic => hb, data => Millis }]),
    erlang:start_timer(SInterval, Pid, Data_jsonb).

terminate(_Reason, _Req, _State) ->
    ok.
