-module(ered_http_node_http_in_handler).

-behaviour(cowboy_loop).

-export([
    init/2,
    info/3
]).

%%
%% This is the http handler if a http in node registers a http endpoint.
%% All this does is send the http in node a message and wait for
%% messages back from other nodes to send back to the client.
%%
%% Here we have a handler per path, so this instance has potentially
%% many http in nodes that it respresents and each of those nodes
%% has potentially a different HTTP method and a different websocket
%% so when this instance sends a reply, it must ensure that the method
%% and the websocket match the requirements.
%%

-import(ered_nodered_comm, [
    websocket_name_from_request/1
]).
-import(ered_messages, [
    create_outgoing_msg/1
]).

-define(FATALERROR(M, P, C),
    io:format(
        "FATAL ERROR: No handler ~p {{{ ~p }}} to {{{ ~p }}} C: {{{ ~p }}}~n",
        [self(), M, P, C]
    )
).

init(Req, State) ->
    %%
    %% Interestingly the websocket concept that I was/am using to separate
    %% clients using the floweditor completely falls apart here...
    %%
    %% The idea is to have multiple users connected to the same ErlangRED
    %% server be differentiated by their websocket id (WsName) - why
    %% the websocket? Because the flow editor uses a websocket to communicate
    %% updates to the client - most of everything the user does goes over this
    %% websocket, it defines the user.
    %%
    %% So this WsName has become the scope of running process - each node is
    %% a process but there are multiple processes for each node because each
    %% websocket gets its own process for a node. This allows multiple users
    %% access to the one and same flow.
    %%
    %% So what happens here? This is the entry point for a http in node
    %% that represents some random path and method for which the http in
    %% node is the recipient. Here's the problem: the initial request to
    %% this endpoint has no websocket cookie so it's impossible to know
    %% which node should receive the request. The reply below actually
    %% sets the wsname cookie so that any subsequent request contains a
    %% wsname but that's the second request, not the first request.
    %%
    %% The good news is that in fact, this isn't a problem since anyone
    %% accessing the server and creating a http in node that is meant to run
    %% in production aren't going to leave their browsers open, i.e. there
    %% won't be a websocket. So in most case there will be a single http in
    %% process (or one per method) but not one per WsName & Method.
    %%
    %% Why bother with this websocket scoping in the first place?
    %% Well its good for running tests and having multiple users try out
    %% Erlang-Red without having connections interfere with one another.
    %%
    %% This isn't a production solution especially since in production you
    %% want the same people to access the same code - i.e. multiuser edits
    %% work on the same and single instance of the flow code. So in that
    %% setup this websocket stuff can be completely be ignored or rather
    %% needs re-thinking how to do this better.
    %%

    #{method := Method} = Req,
    #{path := Path} = Req,

    CookieWsName = websocket_name_from_request(Req),

    %% If the WsName cookies is set then try to find an exact match, if
    %% cookie isn't set then take the first http in node that matches both
    %% path and method.
    %% If the cookie is set but there is no handler, then we make the assumption
    %% that the cookie is stale and we use the first available http in node
    %% that matches the method.
    case CookieWsName of
        none ->
            case lists:keyfind(Method, 1, State) of
                false ->
                    ?FATALERROR(Method, Path, "None"),
                    {cowboy_loop, Req, State, hibernate};
                {_, HttpInPid, WsName} ->
                    {cowboy_loop, push_out_msg(Req, HttpInPid, WsName), State,
                        hibernate}
            end;
        _ ->
            case lists:filter(fun({M, _, _}) -> M =:= Method end, State) of
                [] ->
                    ?FATALERROR(Method, Path, CookieWsName),
                    {cowboy_loop, Req, State, hibernate};
                [{_, HttpInPid, CookieWsName}] ->
                    %% a single process that also happens to have the right
                    %% Websocket name.
                    {cowboy_loop, push_out_msg(Req, HttpInPid, CookieWsName),
                        State, hibernate};
                All = [{_, HttpInPid, WsName} | _] ->
                    %% multiple receives for a method and potentially multiple
                    %% web socket names, take the first.
                    case lists:keyfind(CookieWsName, 3, All) of
                        false ->
                            %% This is basically a stale cookie, no handler
                            %% but the client has an old websocket cookie
                            %% set - ignore cookie value.
                            %% ?FATALERROR(Method, Path, "Stale Cookie"),
                            {cowboy_loop,
                                push_out_msg(
                                    Req, HttpInPid, WsName
                                ),
                                State, hibernate};
                        {_, HttpInPidForCookie, CookieWsName} ->
                            {cowboy_loop,
                                push_out_msg(
                                    Req, HttpInPidForCookie, CookieWsName
                                ),
                                State, hibernate}
                    end
            end
    end.

%%
%% This is called from the http response node. There is little we can do
%% to ensure that this the right response for the right connection since
%% the initial routing is done when the process is initiated. Routing here
%% means to the correct node process that should be handling this
%% request - by Method & WsName & Path
info({reply, StatusCode, Headers, WsName, Body}, Req, State) ->
    Req2 = cowboy_req:set_resp_cookie(
        <<"wsname">>,
        atom_to_list(WsName),
        Req
    ),

    cowboy_req:reply(StatusCode, Headers#{
        <<"x-powered-by">> => <<"Erlang-Red, github.com/gorenje/erlang-red">>
    }, Body, Req2),

    {stop, Req2, State};
info(_Msg, Req, State) ->
    {ok, Req, State, hibernate}.

%%
%%
read_entire_body(Req) ->
    read_body(Req, <<"">>).

read_body(Req0, Acc) ->
    case cowboy_req:read_body(Req0) of
        {ok, Data, Req} -> {ok, <<Acc/binary, Data/binary>>, Req};
        {more, Data, Req} -> read_body(Req, <<Acc/binary, Data/binary>>)
    end.

%%
%% Taken from https://ninenines.eu/docs/en/cowboy/2.13/guide/multipart/
multipart(Req0, Files) ->
    case {cowboy_req:read_part(Req0), Files} of
        {{ok, Headers, Req1}, _} ->
            {Req, Files1} =
                case cow_multipart:form_data(Headers) of
                    {data, FieldName} ->
                        io:format(
                            "UNSUPPORTED: Found data: [~p]~n",
                            [FieldName]
                        ),
                        {ok, _Body, Req2} = cowboy_req:read_part_body(Req1),
                        {Req2, Files};
                    {file, FieldName, Filename, CType} ->
                        {Req2, Buffer} = stream_file(Req1, []),
                        File = #{
                            <<"fieldname">> => FieldName,
                            <<"originalname">> => Filename,
                            %% ignore - encoding is not reliable
                            <<"encoding">> => <<"7bit">>,
                            <<"mimetype">> => CType,
                            <<"buffer">> => Buffer,
                            <<"size">> => byte_size(Buffer)
                        },
                        {Req2, [File | Files]}
                end,
            multipart(Req, Files1);
        {{done, Req}, []} ->
            {no_files, Req};
        {{done, Req}, _Files} ->
            {files, Req, Files}
    end.

stream_file(Req0, Chunks) ->
    case cowboy_req:read_part_body(Req0) of
        {ok, LastBodyChunk, Req} ->
            {Req, list_to_binary(lists:reverse([LastBodyChunk | Chunks]))};
        {more, BodyChunk, Req} ->
            stream_file(Req, [BodyChunk | Chunks])
    end.

%%
%%
to_binary_keys(Map) ->
    to_binary_keys(maps:to_list(Map), []).
to_binary_keys([], NewList) ->
    maps:from_list(NewList);
to_binary_keys([H | T], Lst) ->
    to_binary_keys(T, [{atom_to_binary(element(1, H)), element(2, H)} | Lst]).

% erlfmt:ignore - alignment
push_out_msg(Req, HttpInPid, WsName) ->
    BaseReqObj = #{
        <<"url">>         => cowboy_req:path(Req),
        <<"uri">>         => iolist_to_binary(cowboy_req:uri(Req)),
        <<"hostname">>    => cowboy_req:host(Req),
        <<"originalUrl">> => cowboy_req:path(Req),
        <<"method">>      => cowboy_req:method(Req),
        <<"headers">>     => cowboy_req:headers(Req),
        <<"params">>      => to_binary_keys(cowboy_req:bindings(Req)),
        <<"cookies">>     => cowboy_req:parse_cookies(Req),
        <<"query">>       => maps:from_list(cowboy_req:parse_qs(Req))
    },

    push_out_msg(
      Req,
      HttpInPid,
      WsName,
      cowboy_req:parse_header(<<"content-type">>, Req),
      BaseReqObj
     ).

%%
%%
push_out_msg(
    Req,
    HttpInPid,
    WsName,
    {<<"multipart">>, <<"form-data">>, _},
    BaseReqObj
) ->
    case multipart(Req, []) of
        {files, Req2, LstOfFiles} ->
            %% create a base Msg with _msgid and _ws as attributes
            {outgoing, Msg} = create_outgoing_msg(WsName),

            %% add the this pid so that a reply can be sent to the client
            Msg2 = Msg#{
                <<"reqpid">> => self(),
                <<"req">> => BaseReqObj#{
                    <<"files">> => LstOfFiles,
                    <<"body">> => #{}
                },
                <<"payload">> => #{}
            },
            gen_server:cast(HttpInPid, {outgoing, Msg2}),
            Req2;
        {_, Req2} ->
            Req2
    end;
%%
%%
push_out_msg(
    Req,
    HttpInPid,
    WsName,
    _ContentType,
    BaseReqObj
) ->
    %% add the bindings of any parameters in the path plus other stuff
    %% into the req object
    {ok, Body, Req2} = read_entire_body(Req),

    %% create a base Msg with _msgid and _ws as attributes
    {outgoing, Msg} = create_outgoing_msg(WsName),

    %% add the this pid so that a reply can be sent to the client
    Msg2 = Msg#{
        <<"reqpid">> => self(),
        <<"req">> => BaseReqObj#{<<"body">> => Body},
        <<"payload">> => Body
    },

    gen_server:cast(HttpInPid, {outgoing, Msg2}),

    Req2.
