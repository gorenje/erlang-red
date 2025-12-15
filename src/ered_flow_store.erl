-module(ered_flow_store).

-export([store_flow/0, store_flow_id/1, store_main_flow/0]).

store_flow_id(FlowId) when is_binary(FlowId) ->
    store_flow_id(binary_to_list(FlowId));
store_flow_id(FlowId) when is_list(FlowId) ->
    filename:join([get_store_flow(), FlowId, "flows.json"]).

store_flow() ->
    get_store_flow().

store_main_flow() ->
    filename:join([get_store_flow(), "flows.json"]).

get_store_flow() ->
    application:get_env(
        erlang_red, flow_store, filename:basedir(user_data, "erlang-red")
    ).