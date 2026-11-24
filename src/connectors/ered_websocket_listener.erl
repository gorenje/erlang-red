-module(ered_websocket_listener).

-import(ered_nodes, [
    jstr/2
]).

-export([
    upgrade/3,
    start/2
]).

start(#{host := Host} = UriMap, Router) when is_binary(Host) ->
    start(UriMap#{host => binary_to_list(Host)}, Router);
start(#{port := Port, path := Path, host := Host}, Router) when is_list(Host) ->
    case gun:open(Host, Port) of
        {ok, ConnPid} ->
            spawn(?MODULE, upgrade, [ConnPid, Path, Router]),
            {ok, ConnPid};
        Reason ->
            {error, Reason}
    end;
start(#{scheme := <<"ws">>} = UriMap, Router) ->
    start(UriMap#{port => 80}, Router);
start(#{scheme := <<"wss">>} = UriMap, Router) ->
    start(UriMap#{port => 443}, Router);
start(FailedMap, _Router) ->
    {error, jstr("websocket failed map: ~p", [FailedMap])}.

%%
%%
upgrade(ConnPid, Path, Router) ->
    gun:ws_upgrade(ConnPid, Path),
    handler(ConnPid, Router).

%%
%%
handler(ConnPid, Router) ->
    receive
        {gun_upgrade, ConnPid, _StreamRef, [<<"websocket">>], _Headers} ->
            Router ! {websocket_connect, ConnPid},
            handler(ConnPid, Router);
        {gun_response, ConnPid, _, _, Status, _Headers} ->
            Router ! {websocket_disconnect, ConnPid, Status};
        {gun_error, ConnPid, _StreamRef, Reason} ->
            Router ! {websocket_disconnect, ConnPid, Reason};
        {gun_ws, ConnPid, _StreamRef, Frame} ->
            Router ! {websocket_frame, ConnPid, Frame},
            handler(ConnPid, Router);
        {gun_up, ConnPid, _Protocol} ->
            handler(ConnPid, Router);
        Unhandled ->
            io:format("Unhandled Websocket Msg (Gun) : ~p~n",[Unhandled]),
            Router ! {websocket_disconnect, ConnPid}
    end.
