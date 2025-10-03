-module(ered_node_http_in).

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Node for creating a http endpoint for a request. This must in conjunction
%% with a http response node somewhere in the flow.
%%
%% The flow of this node is:
%%
%%    - start/2 called here
%%    - registered event received and this node setups up a path for the
%%      cowboy router using the ered_webserver server
%%    - the ered_webserver server adds the route using the
%%      ered_http_node_http_in_handler handler that is also given a Pid of
%%      this node
%%    - once a request comes in, the ered_http_node_http_in_handler handler
%%      sends this node an outgoung message with the websocket id and its
%%      pid in the message (reqpid)
%%    - the outgoing message is propagated to all the nodes connected to this
%%      http in node.
%%    - once the message hits a http response node, the response is sent to the
%%      client using the {reply, Body} event (that's what the http response
%%      node uses).
%%
%% So there are many moving parts in getting a http in node to work but it
%% does work well even if it requires a websocket id to execute the correct
%% flow.
%%
-import(ered_nodes, [
    send_msg_to_connected_nodes/2
]).

%%
%%
start(NodeDef, _WsName) ->
    ered_node:start(NodeDef, ?MODULE).

%%
%%
handle_event({registered, WsName, Pid}, NodeDef) ->
    {ok, Path} = maps:find(<<"url">>, NodeDef),
    {ok, Method} = maps:find(<<"method">>, NodeDef),
    ered_webserver:register_http_in(
        Path,
        string:uppercase(Method),
        {Pid, WsName}
    ),
    NodeDef;
handle_event({stop, WsName}, NodeDef) ->
    {ok, Path} = maps:find(<<"url">>, NodeDef),
    {ok, Method} = maps:find(<<"method">>, NodeDef),
    ered_webserver:unregister_http_in(Path, string:uppercase(Method), WsName),
    NodeDef;
handle_event(_, NodeDef) ->
    NodeDef.

%%
%% outgoing message is triggered by the ered_http_node_http_in_handler module
handle_msg(
    {outgoing, #{<<"req">> := #{<<"query">> := Query}} = Msg},
    #{<<"method">> := <<"get">>} = NodeDef
) ->
    send_msg_to_connected_nodes(NodeDef, Msg#{<<"payload">> => Query}),
    {handled, NodeDef, Msg#{<<"payload">> => Query}};
handle_msg({outgoing, Msg}, NodeDef) ->
    send_msg_to_connected_nodes(NodeDef, Msg),
    {handled, NodeDef, Msg};
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.
