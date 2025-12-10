-module(ered_webserver).

-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2]).
-export([handle_info/2, terminate/2, code_change/3]).
-export([stop/0]).
-export([start/0]).

-export([
    register_http_in/3,
    unregister_http_in/3
]).

start() ->
    InitialState = handle_disable_floweditor(os:getenv("DISABLE_FLOWEDITOR")),
    State = maps:put(http_in_routes, [], InitialState),
    herd_up_the_cattle(State),
    gen_server:start_link({local, ?MODULE}, ?MODULE, State, []).

init(State) ->
    {ok, State}.

%%
%%
register_http_in(Path, Method, {Pid, WsName}) ->
    gen_server:call(?MODULE, {add_route, Path, Method, {Pid, WsName}}).

unregister_http_in(Path, Method, WsName) ->
    gen_server:call(?MODULE, {del_route, Path, Method, WsName}).

%%
%% remove a route for the http in handler
%%
handle_call({del_route, Path, Method, WsName}, _From, State) ->
    NwR =
        case lists:keyfind(Path, 1, maps:get(http_in_routes, State)) of
            false ->
                maps:get(http_in_routes, State);
            {Path, Handler, Ary} ->
                % remove any existing handler for the method & websocket name
                Ary2 = lists:filter(
                    fun({M, _P, W}) ->
                        M =/= Method orelse W =/= WsName
                    end,
                    Ary
                ),
                lists:keyreplace(
                    Path,
                    1,
                    maps:get(http_in_routes, State),
                    {Path, Handler, Ary2}
                )
        end,

    restart_dispatcher(NwR ++ maps:get(floweditor_routes, State)),
    {reply, ok, State#{http_in_routes => NwR}};
%%
%% add a route for the http_in handler
%%
handle_call({add_route, Path, Method, {Pid, WsName}}, _From, State) ->
    ExtraRoutes =
        case lists:keyfind(Path, 1, maps:get(http_in_routes, State)) of
            false ->
                [
                    {
                        Path,
                        ered_http_node_http_in_handler,
                        [{Method, Pid, WsName}]
                    }
                    | maps:get(http_in_routes, State)
                ];
            {Path, Handler, Ary} ->
                Ary2 = lists:filter(
                    fun({M, _P, W}) ->
                        M =/= Method orelse W =/= WsName
                    end,
                    Ary
                ),
                lists:keyreplace(
                    Path,
                    1,
                    maps:get(http_in_routes, State),
                    {Path, Handler, [{Method, Pid, WsName} | Ary2]}
                )
        end,

    restart_dispatcher(ExtraRoutes ++ maps:get(floweditor_routes, State)),
    {reply, ok, maps:put(http_in_routes, ExtraRoutes, State)};
%%
%%
handle_call(_Msg, _From, State) ->
    {reply, State, State}.

%%
%%
handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Msg, Store) ->
    {noreply, Store}.

%%
%%
handle_info(_Msg, ErrorStore) ->
    {noreply, ErrorStore}.

code_change(_OldVersion, ErrorStore, _Extra) ->
    {ok, ErrorStore}.

stop() ->
    gen_server:cast(?MODULE, stop).

terminate(normal, _State) ->
    ok;
terminate(Event, _State) ->
    io:format("Webserver Terminated with {{{ ~p }}}~n", [Event]),
    ok.

%%
%% --------------------- helpers
%%

handle_disable_floweditor(V) when is_binary(V) ->
    handle_disable_floweditor(binary_to_list(V));
handle_disable_floweditor(V) when V =:= false; V =:= "false"; V =:= "NO" ->
    #{floweditor_routes => flow_editor_routes()};
handle_disable_floweditor(_) ->
    io:format("Disabling FlowEditor Frontend~n", []),
    #{floweditor_routes => []}.

herd_up_the_cattle(State) ->
    %% heroku likes to provide port numbers to docker images running
    %% on its platform - so support that
    Port =
        case os:getenv("PORT") of
            false ->
                8080;
            PortNum ->
                list_to_integer(PortNum)
        end,

    Dispatch =
        cowboy_router:compile([
            {'_',
                maps:get(floweditor_routes, State) ++
                    maps:get(http_in_routes, State)}
        ]),

    persistent_term:put(my_app_dispatch, Dispatch),

    {ok, _} = cowboy:start_clear(
        erlang_red_listener,
        [{port, Port}],
        #{
            env => #{dispatch => {persistent_term, my_app_dispatch}},
            middlewares => [ered_http_auth, cowboy_router, cowboy_handler]
        }
    ).

%%
%% Naming convention is that anything with 'nodered' in the name is part
%% of the orignal NodeRED API that links the flow editor with the server.
%% Other calls are extensions to support ErlangRED functionality or node
%% functionality (e.g., FlowCompare, FlowHubLib, ...)
%%
flow_editor_routes() ->
    [
        %%
        %% Sock'em in the eye websockets
        %%
        {"/node-red/comms", ered_http_redirect,
            {permanently, "/erlang-red/comms"}},

        {"/erlang-red/comms", ered_http_nodered_websocket, #{
            stats_interval => 30000,
            % milliseconds
            bulk_send_interval => 127
        }},

        %%
        %% POST handlers
        %%

        %% ClientCode node backend
        {"/ClientCode/:nodeid", ered_http_clientcode_node, []},
        {"/ClientCode/:nodeid/:task", ered_http_clientcode_node, []},

        %% Message tracer API endpoint
        {"/MsgTracer/:task/:state", ered_http_msgtracer_plugin, []},

        %% API for storing test cases to disk.
        {"/testcase/:workspaceid/create", ered_http_testcase_post_handler, []},

        %%
        %% APIs for the unit testing nodes
        {"/UnitTesting/tests.json", ered_http_unittesting_tests_get_handler,
            []},
        {"/UnitTesting/:flowid/runtest",
            ered_http_unittesting_runtests_get_handler, []},
        {"/UnitTesting/:flowid/retrieve",
            ered_http_unittesting_retrieve_flow_handler, []},
        {"/flows.test.json", ered_http_unittesting_retrieve_flow_handler, []},
        {"/UnitTesting/halt", ered_http_unittesting_halt_handler, []},

        %%
        %% these APIS are required by Node-RED
        {"/settings/user", ered_http_nodered_empty_json, []},
        {"/nodes", ered_http_nodered_empty_json, []},
        {"/flows", ered_http_nodered_flow_deploy_handler, []},
        {"/inject/:nodeid", ered_http_nodered_inject_node_button_handler, []},

        {"/debug/view/debug-utils.js", cowboy_static,
            {priv_file, erlang_red,
                "node-red-frontend/debug/view/debug-utils.js"}},

        {"/debug/:nodeid/:action", ered_http_nodered_debug_node_active, []},

        {"/credentials/:nodetype/:nodeid", ered_http_nodered_credentials, []},

        %%
        %% GET handlers for delivery of the static content
        %%

        %%
        %% Flow Compare node allows comparing the flow data in the browser
        %% with what is stored on the server. Good for knowing the in-browser
        %% changes made to installed test cases.
        {"/FlowCompare/jslib/diff.min.js", cowboy_static,
            {priv_file, erlang_red, "vendor/diff.min.js"}},

        {"/ScratchPad/jslib/diff.min.js", cowboy_static,
            {priv_file, erlang_red, "vendor/diff.min.js"}},

        {"/FlowHubLib/jslib/diff.min.js", cowboy_static,
            {priv_file, erlang_red, "vendor/flowhub.diff.min.js"}},

        {"/FlowCompare/jslib/flowviewer.min.js", cowboy_static,
            {priv_file, erlang_red, "vendor/flowviewer.min.js"}},

        {"/vendor/monaco-tokenizer.js", cowboy_static,
            {priv_file, erlang_red, "vendor/monaco-tokenizer.js"}},
        {"/vendor/erlang.js", cowboy_static,
            {priv_file, erlang_red, "vendor/erlang.js"}},
        {"/vendor/dagre.min.js", cowboy_static,
            {priv_file, erlang_red, "vendor/dagre.min.js"}},

        {"/auto_layout_config/lib/elkjs", cowboy_static,
            {priv_file, erlang_red, "vendor/elkjs"}},
        {"/auto_layout_config/lib/dagrejs", cowboy_static,
            {priv_file, erlang_red, "vendor/dagrejs"}},

        %% flow editor stuff that isn't supported yet
        {"/library/local/flows/", ered_http_nodered_empty_json, []},
        {"/context/[...]", ered_http_nodered_empty_json, []},

        {"/erlang-reddebug/view/view.html", ered_http_redirect,
            {permanently, "/erlang-red/debug/view/view.html"}},
        {"/erlang-red/red/red.min.js", ered_http_redirect,
            {permanently, "/erlang-red/red/red.js"}},
        {"/node-red", ered_http_redirect, {permanently, "/erlang-red"}},

        {"/erlang-red", cowboy_static,
            {priv_file, erlang_red, "node-red-frontend/index.html"}},

        {"/erlprocess/processes", ered_http_erlprocesses_process, []},

        %%% Wrapper site on '/' - flow editor is on '/erlang-red'
        {"/", ered_http_release_status, []},

        {"/media/[...]", cowboy_static,
            {priv_dir, erlang_red, "wrapper_site/media", []}},

        {"/styles/[...]", cowboy_static,
            {priv_dir, erlang_red, "wrapper_site/styles", []}},

        %% This was added because of the debug panel detachment window
        %% debug/view/view.html does not use absolute paths.
        {"/erlang-red/[...]", cowboy_static,
            {priv_dir, erlang_red, "node-red-frontend", [
                {mimetypes, ered_http_nodered_mimetypes, mt}
            ]}},
        {"/[...]", cowboy_static,
            {priv_dir, erlang_red, "node-red-frontend", [
                {mimetypes, ered_http_nodered_mimetypes, mt}
            ]}}
    ].

%%
%%
restart_dispatcher(Routes) ->
    Dispatch = cowboy_router:compile([{'_', Routes}]),
    persistent_term:put(my_app_dispatch, Dispatch).
