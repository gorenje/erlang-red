-module(ered_http_erlprocesses_process).

%%
%% Backend for the processes sidebar
%%

-behaviour(cowboy_rest).

-export([
    init/2,
    allowed_methods/2,
    handle_get_response/2,
    content_types_provided/2,
    format_error/2
]).

-import(ered_messages,[
    encode_json/1
]).

init(Req, State) ->
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, handle_get_response}], Req, State}.


handle_get_response(Req, State) ->
    ToV = fun
        (false) -> <<>>;
        ({_,V}) when is_list(V) -> list_to_binary(V);
        ({_,V}) -> V
        end,

    ToHash = fun(P, ProcInfo) ->
        #{
            <<"pid">>    => P,
            <<"parent">> => ToV(lists:keyfind(group_leader, 1, ProcInfo)),
            <<"status">> => ToV(lists:keyfind(status, 1, ProcInfo)),
            <<"name">>   => ToV(lists:keyfind(registered_name, 1, ProcInfo))
        }
        end,


    {encode_json(#{ <<"data">> => #{ <<"processes">> => [ToHash(P, process_info(P)) || P <- erlang:processes()] }}),
     Req,
     State}.


format_error(Reason, Req) ->
    {
        [
            {<<"error">>, <<"bad_request">>},
            {<<"reason">>, Reason}
        ],
        Req
    }.
