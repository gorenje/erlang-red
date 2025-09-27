-module(ered_runtime_manager).

-behaviour(gen_server).

%%
%% Manage the runtime status updates sent to clients. This is done to allow
%% support for single user mode.
%%
%% What this implements is single single user mode whereby any changes made
%% are stored to a flows.json file and all clients are updated with the changes.
%% This is basically Node-RED behaviour with one-server being one-flow being
%% one-user.
%%
%% Erlang-RED can support multiple flows and multiple users running in parallel
%% but that feature is deactivated in favour of single-user mode. To reactivate
%% mutliple user mode, revert the commit that added this file.
%%

-export([
    start_link/0,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    code_change/3,
    terminate/2,
    stop/0
]).

%%
%% Externer exports
-export([
    deploy_complete/1,
    deploy_start/2,
    get_flow_data/0,
    new_websocket/1,
    state/0
]).

%%
%%
-import(ered_messages, [
    encode_json/1,
    decode_json/1
]).

%%
%%
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, #{}, []).

init(Args) ->
    {ok, Args#{
        flowdata => get_initial_flow(),
        websockets => sets:from_list([])
    }}.

%%
%% External APIs
deploy_start(FlowData, WsName) ->
    gen_server:call(?MODULE, {deploy_start, FlowData, WsName}).

deploy_complete(WsName) ->
    gen_server:call(?MODULE, {deploy_complete, WsName}).

new_websocket(WsName) ->
    gen_server:call(?MODULE, {new_websocket, WsName}).

get_flow_data() ->
    gen_server:call(?MODULE, {get_flow_data}).

state() ->
    gen_server:call(?MODULE, {state}).

%%
%%
stop() ->
    gen_server:cast(?MODULE, stop).

terminate(normal, _State) ->
    ok;
terminate(_Event, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%%
%%
handle_call(
    {new_websocket, WsName},
    _From,
    #{websockets := WebSockets} = State
) ->
    {reply, ok, State#{websockets => sets:add_element(WsName, WebSockets)}};
%%
handle_call(
    {deploy_start, FlowData, WsName},
    _From,
    #{websockets := WebSockets} = State
) ->
    %% create hard copy of the flows.
    ered_flow_store_server ! {store_main_flow, FlowData},

    Notifications = fun(W) ->
        W ! {runtime_state, stop, true}
    end,

    notify_clients(sets:del_element(WsName, WebSockets), Notifications),
    {reply, ok, State#{flowdata => FlowData}};
%%
handle_call(
    {deploy_complete, WsName},
    _From,
    #{websockets := WebSockets, flowdata := FlowData} = State
) ->
    Revision = flow_revision(FlowData),

    Notifications = fun(W) ->
        W ! {runtime_state, start, true},
        W ! {runtime_deploy, Revision}
    end,

    notify_clients(sets:del_element(WsName, WebSockets), Notifications),
    {reply, Revision, State};
%%
handle_call({get_flow_data}, _From, #{flowdata := FlowData} = State) ->
    {reply, FlowData, State};
%%
handle_call({state}, _From, State) ->
    {reply, State, State};
%%
handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

%%
%%
handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%
%%
handle_info(_, State) ->
    {noreply, State}.

%%
%% -------------------------- helpers
notify_clients(WebSockets, Fun) ->
    SendIfConnected = fun(W) ->
        case whereis(W) of
            undefined ->
                ignore;
            _ ->
                Fun(W)
        end
    end,
    [SendIfConnected(WsName) || WsName <- sets:to_list(WebSockets)].

flow_revision(FlowData) ->
    <<SHA256:256/big-unsigned-integer>> = crypto:hash(sha256, FlowData),
    list_to_binary(io_lib:format("~64.16.0b", [SHA256])).

get_initial_flow() ->
    FlowData =
        case ered_flow_store_server:retrieve_main_flow() of
            {ok, Content} ->
                decode_json(Content);
            _ ->
                [
                    #{
                        id => ered_nodes:generate_id(),
                        type => <<"tab">>,
                        label => <<"Flow 1">>,
                        disabled => false,
                        info => <<>>,
                        env => []
                    }
                ]
        end,

    encode_json(
        #{
            rev => ered_nodes:generate_id(64),
            flows => FlowData
        }
    ).
