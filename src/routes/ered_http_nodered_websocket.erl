-module(ered_http_nodered_websocket).

-export([
    init/2,
    websocket_init/1,
    websocket_handle/2,
    websocket_info/2,
    terminate/3
]).

-import(ered_nodes, [
    jstr/1,
    jstr/2
]).

-import(ered_nodered_comm, [
    get_websocket_name/0
]).

-import(ered_messages, [
    encode_json/1,
    encode_json_loud/1
]).

-define(AppendToBulkdata(Message),
    maps:put(bulkdata, [Message | maps:get(bulkdata, State)], State)
).

%erlfmt:ignore - alignment
-define(CreateClientCodeMsg,
    #{
          topic => <<"introspect:client-code-perform">>,
          data => #{
              msg     => <<"execfunc">>,
              payload => Payload,
              topic   => jstr(Topic),
              func    => jstr(ClientCode),
              nodeid  => NodeId,
              '_msg'  => Msg
          }
     }
).

%%
%% Websocket connection to the flow editor.
%%
%% This starts two timers: one for sending a heartbeat at regular intervals
%% and the other for send status updates in bulk.
%%
%% Node-REDs flow editor can handle status messages (any websocket message
%% in fact) in bulk, so we do that. By buffering data in the `bulkdata`
%% attribute of the state and a timer that triggers sending out that content.
%%
%% The intervals of these two timers is set in the ered_webserver.erl.
%%

init(Req, State) ->
    %% runs in a different process so can't send out cookie to set ws name
    {cowboy_websocket, Req, State, #{idle_timeout => 120000}}.

websocket_init(State) ->
    WsName = get_websocket_name(),
    register(WsName, self()),

    % heartbeat timer
    erlang:start_timer(
        500,
        WsName,
        encode_json([
            #{
                topic => hb,
                data => erlang:system_time(millisecond)
            },
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

    % bulk data push out timer
    erlang:start_timer(501, WsName, push_out_bulk_data),

    {ok, maps:merge(State, #{wsname => WsName, bulkdata => []})}.

%% -------------------- incoming messages from flow editor
%%
%% the only one we handle is the pong message (which is a Erlang-Red special).
%% What also comes in are subscribe/ messages but that isn't supported by
%% Erlang-Red.
%%
%% Put a try/catch here since any garbage could trash the websocket - when
%% parsing the assumed JSON content.
websocket_handle({text, JsonData}, State) ->
    try
        DecodeData = json:decode(JsonData),
        case maps:find(<<"topic">>, DecodeData) of
            {ok, <<"pong">>} ->
                {reply,
                    {text,
                        encode_json([
                            #{
                                topic => ping,
                                data => erlang:system_time(millisecond)
                            }
                        ])},
                    State};
            _ ->
                {ok, State}
        end
    catch
        _E:_F:_S ->
            {ok, State}
    end;
websocket_handle(_Data, State) ->
    {ok, State}.

%% -------------------- start_timer handlers
%%
%% timeout endpoint for the two timers started to send out bulkdata
%% and to send out a heartbeat
websocket_info({timeout, _Ref, push_out_bulk_data}, State) ->
    BulkData = maps:get(bulkdata, State),

    RestartTimer = fun() ->
        erlang:start_timer(
            maps:get(bulk_send_interval, State),
            self(),
            push_out_bulk_data
        )
    end,

    case length(BulkData) of
        0 ->
            RestartTimer(),
            {ok, State};
        _ ->
            TxtData = encode_json(lists:reverse(BulkData)),
            RestartTimer(),
            {reply, {text, TxtData}, maps:put(bulkdata, [], State)}
    end;
websocket_info({timeout, _Ref, Msg}, State) ->
    ws_send_heartbeat(self(), State),
    {reply, {text, Msg}, State};
%%
%%
websocket_info({data, Msg}, State) ->
    {reply, {text, Msg}, State};
%% -------------------- Debug panel messages
%%
%% All the possible debug message that end up in the debug panel.
%% Four types: normal, notice, warning and error, each has a different
%% colour in the debug panel.
%%
%% Debug messages are sent immediately since they - might be - are important
%% while status and unittest results can be bulked up.
websocket_info({debug, Data, notice}, State) ->
    send_debug_down_the_pipe(maps:put(level, 40, Data), State, notice);
websocket_info({debug, Data, warning}, State) ->
    send_debug_down_the_pipe(maps:put(level, 30, Data), State, warning);
websocket_info({debug, Data, error}, State) ->
    send_debug_down_the_pipe(maps:put(level, 20, Data), State, error);
websocket_info({debug, Data, Level}, State) ->
    send_debug_down_the_pipe(Data, State, Level);
%% -------------------- Node status updates
%%
%% Clear a previous status update for a node
websocket_info({status, NodeId, clear}, State) ->
    Msg = #{
        topic => jstr("status/~s", [NodeId]),
        data => #{}
    },
    %
    % Note: not sent to the websocket event exchange - feature not bug.
    %
    {ok, ?AppendToBulkdata(Msg)};
%%
%% Here are the details to the possible values of the status
%% elements.
%%
%% From: https://nodered.org/docs/creating-nodes/status
%%
%% Clr: 'red', 'green', 'yellow', 'blue' or 'grey'
%% Shp: 'ring' or 'dot'.
%%
websocket_info({status, NodeId, Txt, "", ""}, State) ->
    Msg = #{
        topic => jstr("status/~s", [NodeId]),
        data => #{
            text => jstr(Txt)
        }
    },
    ered_ws_event_exchange:node_status(
        maps:find(wsname, State),
        NodeId,
        Txt,
        "",
        ""
    ),
    {ok, ?AppendToBulkdata(Msg)};
websocket_info({status, NodeId, Txt, Clr, Shp}, State) ->
    Msg = #{
        topic => jstr("status/~s", [NodeId]),
        data => #{
            text => jstr(Txt),
            fill => jstr(Clr),
            shape => jstr(Shp)
        }
    },

    ered_ws_event_exchange:node_status(
        maps:find(wsname, State),
        NodeId,
        Txt,
        Clr,
        Shp
    ),

    {ok, ?AppendToBulkdata(Msg)};
%% -------------------- Unittests results
%%
%% Results of a unit test run. The details are sent via a debug message if
%% there were errors.
%%
websocket_info({unittest_results, FlowId, Status}, State) ->
    Msg = #{
        topic => 'unittesting:testresults',
        data => #{
            flowid => jstr(FlowId),
            status => jstr(Status)
        }
    },

    {ok, ?AppendToBulkdata(Msg)};
%% -------------------- Message tracing
%%
%% these are msgtracing details and are important enough to be sent
%% immediately. Separately the status updates for the nodes is sent
%% and are bulked up.
websocket_info({msgtracing, NodeId}, State) ->
    Msg = encode_json([
        #{
            topic => 'msgtracer:node-received',
            data => #{
                nodeid => NodeId
            }
        }
    ]),
    {reply, {text, Msg}, State};
%% -------------- Client Code node
%%
%% ClientCode node execute function in browser
websocket_info({client_code_exec, NodeDef, Msg}, State) ->
    {ok, ?AppendToBulkdata(client_code_exec(NodeDef, Msg))};
%%
%%
websocket_info(_Info, State) ->
    {ok, State}.

%%
%%
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
%%  ---------------- Our friends and helpers in Green.
%%

%%
%%
send_debug_down_the_pipe(Data, State, Level) ->
    Data2 = Data#{<<"timestamp">> => erlang:system_time(millisecond)},
    ered_ws_event_exchange:debug_msg(maps:find(wsname, State), Level, Data2),
    try
        {reply, {text, encode_json_loud([#{topic => debug, data => Data2}])},
            State}
    catch
        error:E:S ->
            io:format("JSON ENCODING ERROR (WebSocket) [~p] [~p]~n", [E, Data2]),
            io:format("Stack (Websocket) [~p]~n", [S]),

            #{<<"msg">> := OrigMsg} = Data2,
            %% we assume that the encoding error was in the payload and replace
            %% that and add a string with the original data object as an Erlang
            %% object.
            {reply,
                {text,
                    encode_json(
                        [
                            #{
                                topic => debug,
                                data =>
                                    Data2#{
                                        <<"msg">> => OrigMsg#{
                                            <<"payload">> =>
                                                list_to_binary(io_lib:format("~p", [Data2]))
                                        }
                                    }
                            }
                        ]
                    )},
                State}
    end.

%%
%% HAHAHA the Millis is off by the timer time - since the message is created
%% and then the timer is set. Why I did this this way remains a mystery, lets
%% just say the tea leafs aren't helping.
ws_send_heartbeat(Pid, State) ->
    {ok, SInterval} = maps:find(stats_interval, State),
    {ok, WsName} = maps:find(wsname, State),

    Millis = erlang:system_time(millisecond),
    Data_jsonb = encode_json([
        #{
            topic => hb,
            data => Millis
        },
        #{
            topic => <<"cookie/set-wsname">>,
            data => #{name => WsName}
        }
    ]),

    erlang:start_timer(SInterval, Pid, Data_jsonb).

%%
%%
%% code taken from message object
client_code_exec(
    #{
        <<"id">> := NodeId,
        <<"clientcode">> := _ClientCode
    },
    #{
        <<"topic">> := Topic,
        <<"clientcode">> := ClientCode,
        <<"payload">> := Payload
    } = Msg
) ->
    ?CreateClientCodeMsg;
%% code taken from node defintion
client_code_exec(
    #{
        <<"id">> := NodeId,
        <<"clientcode">> := ClientCode
    },
    #{
        <<"topic">> := Topic,
        <<"payload">> := Payload
    } = Msg
) ->
    ?CreateClientCodeMsg;
%% no topic.
client_code_exec(
    #{
        <<"id">> := NodeId,
        <<"clientcode">> := ClientCode
    },
    #{
        <<"payload">> := Payload
    } = Msg
) ->
    Topic = <<>>,
    ?CreateClientCodeMsg;
%% no topic and no payload
client_code_exec(
    #{
        <<"id">> := NodeId,
        <<"clientcode">> := ClientCode
    },
    Msg
) ->
    Topic = <<>>,
    Payload = <<>>,
    ?CreateClientCodeMsg.
