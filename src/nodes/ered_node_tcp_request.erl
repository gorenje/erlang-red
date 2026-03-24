-module(ered_node_tcp_request).

-include("ered_nodes.hrl").
-include("ered_tcpnodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Create a tcp request node
%%

%% {
%%         "id": "1e2a217f2ba03c2f",
%%         "type": "tcp request",
%%         "z": "1c1d2cb981cf9f01",
%%         "name": "",
%%         "server": "localhost",
%%         "port": "1001",
%%         "out": "immed", <<-+- "immed" = fire & forget mode,
%%                             \- "time" timeout after splitc milliseconds
%%         "ret": "string",
%%         "splitc": " ", <<-- timeout in milliseconds
%%         "newline": "",
%%         "trim": false,
%%         "tls": "",
%%         "x": 776.666748046875,
%%         "y": 681.9166870117188,
%%         "wires": [
%%             [
%%                 "18383a17a3db3322"
%%             ]
%%         ]
%% }
%%
%%

-import(ered_nodes, [
    check_node_config/3,
    jstr/2,
    send_msg_to_connected_nodes/2
]).

-import(ered_nodered_comm, [
    node_status/5,
    post_exception_or_debug/3,
    send_out_debug_msg/4,
    unsupported/3
]).

-import(ered_messages, [
    any_to_list/1,
    convert_to_num/1,
    create_outgoing_msg/1
]).

% erlfmt:ignore - alignment
start(
  #{<<"out">> := <<"sit">>, <<"ret">> := RetType} = NodeDef, WsName
) when RetType =:= <<"buffer">>; RetType =:= <<"string">> ->
    ered_node:start(NodeDef#{?SetWsName}, ?MODULE);
%
start(#{ <<"out">> := <<"char">> } = NodeDef, WsName) ->
    unsupported(NodeDef, {websocket, WsName}, "when is seen connection"),
    ered_node:start(NodeDef, ered_node_ignore);
start(#{ <<"out">> := <<"count">> } = NodeDef, WsName) ->
    unsupported(NodeDef, {websocket, WsName}, "char count connection"),
    ered_node:start(NodeDef, ered_node_ignore);
start(#{ <<"out">> := <<"sit">> } = NodeDef, WsName) ->
    unsupported(NodeDef, {websocket, WsName}, "keep connection open"),
    ered_node:start(NodeDef, ered_node_ignore);
%
start(NodeDef, WsName) ->
    case check_node_config([
          {<<"ret">>,     <<"string">>},
          {<<"newline">>, <<"">>},
          {<<"trim">>,    false},
          {<<"tls">>,     <<"">>}
    ], NodeDef, WsName) of
        ok ->
            ered_node:start(NodeDef#{?SetWsName, ?EmptyBacklog}, ?MODULE);
        _ ->
            ered_node:start(NodeDef, ered_node_ignore)
    end.

%%
%%
%erlfmt:ignore - alignment
handle_event(
  {registered, WsName, _MyPid},
  #{
     <<"out">> := <<"sit">>,
     ?GetPort,
     ?GetServer
   } = NodeDef
) ->
    case
        gen_tcp:connect(
          binary_to_list(Server),
          convert_to_num(Port),
          [binary, {active, true}]
         )
    of
        {ok, Socket} ->
            ?NodeStatus("connected", "green", "dot"),
            NodeDef#{socket => Socket};
        {error, Reason} ->
            ?NodeStatus("not connected", "red", "ring"),
            io:format("tcp_request: error happened connecting ~p~n",[Reason]),
            NodeDef
    end;

handle_event(
  {registered, WsName, _MyPid},
  #{
     <<"out">>    := <<"time">>,
     <<"splitc">> := TimeoutMS,
     ?GetPort,
     ?GetServer
   } = NodeDef
) ->
    case
        ered_tcp_manager:register_connector(Server, convert_to_num(Port), self())
    of
        {connected, SessionId} ->
            erlang:start_timer(
              convert_to_num(TimeoutMS), self(), treq_disconnect
            ),
            ?NodeStatus("connected", "green", "dot"),
            NodeDef#{?SetSessionId};
        connecting ->
            ?NodeStatus("connecting", "grey", "ring"),
            NodeDef
    end;

handle_event(
  {tcpc_initiated, {SessionId, _Host, _Port}},
  #{
     ?GetWsName,
     ?GetBacklog,
     <<"splitc">> := TimeoutMS
   } = NodeDef
) ->
    ?NodeStatus("connected", "green", "dot"),
    erlang:start_timer(convert_to_num(TimeoutMS), self(), treq_disconnect),
    [ered_tcp_manager:send(SessionId, P) || P <- Backlog],
    NodeDef#{?SetSessionId, ?EmptyBacklog};

handle_event(
  {tcpc_data, {Data, _SessionID, _Host, _Port}},
  #{?GetWsName, <<"ret">> := <<"string">> } = NodeDef
) when is_list(Data) ->
    {outgoing, Msg} = create_outgoing_msg(WsName),
    send_msg_to_connected_nodes(
      NodeDef,
      Msg#{<<"payload">> => list_to_binary(Data)}
    ),
    NodeDef;

handle_event(
  {tcpc_data, {Data, _SessionID, _Host, _Port}},
  #{?GetWsName} = NodeDef
) ->
    {outgoing, Msg} = create_outgoing_msg(WsName),
    send_msg_to_connected_nodes(NodeDef, Msg#{ <<"payload">> => Data }),
    NodeDef;

handle_event(
  {tcpr_data, Socket, Data},
  #{?GetWsName,
    socket := Socket,
    <<"ret">> := <<"string">>
   } = NodeDef
) ->
    {outgoing, Msg} = create_outgoing_msg(WsName),
    send_msg_to_connected_nodes(NodeDef, Msg#{ <<"payload">> => binary_to_list(Data) }),
    NodeDef;

handle_event(
  {tcpr_data, Socket, Data},
  #{?GetWsName,
    socket := Socket
   } = NodeDef
) ->
    {outgoing, Msg} = create_outgoing_msg(WsName),
    send_msg_to_connected_nodes(NodeDef, Msg#{ <<"payload">> => Data }),
    NodeDef;


handle_event(
  {tcp_closed, Socket},
  #{?GetWsName, socket := Socket} = NodeDef
) ->
    ?NodeStatus("disconnected", "grey", "ring"),
    maps:remove(socket, NodeDef);

handle_event(
  treq_disconnect,
  #{ ?GetWsName,
     ?GetSessionId,
     ?GetBacklog,
     ?GetPort,
     ?GetServer
   } = NodeDef
) ->
    [ered_tcp_manager:send(SessionId, P) || P <- Backlog],
    ered_tcp_manager:unregister_connector(Server, convert_to_num(Port), self()),
    ered_tcp_manager:close(SessionId),
    ?NodeStatus("disconnected", "grey", "ring"),
    maps:remove('_sessionid', NodeDef#{?EmptyBacklog});

handle_event(
  {stop, WsName},
  #{ ?GetSessionId,
     ?GetPort,
     ?GetServer
   } = NodeDef
) ->
    ered_tcp_manager:unregister_connector(Server, convert_to_num(Port), self()),
    ered_tcp_manager:close(SessionId),
    ?NodeStatus("disconnected", "grey", "ring"),
    maps:remove('_sessionid', NodeDef#{?EmptyBacklog});


%% fall through
handle_event(_Event, NodeDef) ->
    NodeDef.

%%
%%
%% --> send & forget --> immediately close connection after sending data
handle_msg(
    {incoming, #{?GetWsName, ?GetPayload} = Msg},
    #{
        <<"out">> := <<"sit">>,
        socket := Socket
    } = NodeDef
) ->
    gen_tcp:send(Socket, Payload),
    {handled, NodeDef, Msg};

handle_msg(
    {incoming, #{?GetWsName, ?GetPayload} = Msg},
    #{
      <<"out">> := <<"sit">>,
      ?GetPort,
      ?GetServer
    } = NodeDef
) ->
    %% this is a tcp request node that holds the connection but that has
    %% been disconnected from the server. It now receives a new message that
    %% it's meant to send on. So it has to reconnect and send.
    case
        gen_tcp:connect(
          binary_to_list(Server),
          convert_to_num(Port),
          [binary, {active, true}]
         )
    of
        {ok, Socket} ->
            ?NodeStatus("connected", "green", "dot"),
            gen_tcp:send(Socket, Payload),
            {handled, NodeDef#{socket => Socket}, Msg};
        {error, Reason} ->
            ?NodeStatus("not connected", "red", "ring"),
            post_exception_or_debug(NodeDef, Msg, Reason),
            {handled, NodeDef, Msg}
    end;
%
handle_msg(
    {incoming, #{?GetWsName, ?GetPayload} = Msg},
    #{
        <<"out">> := <<"immed">>,
        ?GetPort,
        ?GetServer
    } = NodeDef
) ->
    case tcp_connect(Server, Port) of
        {ok, Sock} ->
            gen_tcp:send(Sock, Payload),
            inet:close(Sock),
            ?NodeStatus("disconnected", "grey", "ring");
        {error, _Error} ->
            ?NodeStatus("error connecting", "grey", "ring")
    end,

    {handled, NodeDef, Msg};
%% --> connect and disconnet after timeout of milliseconds
handle_msg(
    {incoming, #{?GetPayload} = Msg},
    #{
        <<"out">> := <<"time">>,
        ?GetSessionId,
        ?GetBacklog
    } = NodeDef
) ->
    %% TODO here we ignore send errors, such as that the process is no longer
    %% TODO running - living dangerously in the year of the dragon.
    [ered_tcp_manager:send(SessionId, P) || P <- [Payload | Backlog]],
    {handled, NodeDef#{?EmptyBacklog}, Msg};
handle_msg(
    {incoming, #{?GetPayload} = Msg},
    #{
        <<"out">> := <<"time">>,
        ?GetBacklog
    } = NodeDef
) ->
    {handled, NodeDef#{?DefineBacklog([Payload | Backlog])}, Msg};
handle_msg(_Msg, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% ----------------- Helpers
%%
tcp_connect(HostName, PortNum) ->
    gen_tcp:connect(
        binary_to_list(HostName),
        convert_to_num(PortNum),
        [{active, false}]
    ).
