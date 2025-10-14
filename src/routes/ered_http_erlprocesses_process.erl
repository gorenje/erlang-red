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

-import(ered_messages, [
    encode_json/1
]).

init(Req, State) ->
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, handle_get_response}], Req, State}.

handle_get_response(Req, State) ->
    Data =
        case lists:keyfind(<<"by">>, 1, cowboy_req:parse_qs(Req)) of
            {_, <<"links">>} ->
                process_list_by_links();
            _ ->
                process_list_by_group_leader()
        end,

    {encode_json(Data), Req, State}.

format_error(Reason, Req) ->
    {
        [
            {<<"error">>, <<"bad_request">>},
            {<<"reason">>, Reason}
        ],
        Req
    }.

%%
%% ------------------ helpers
%%
process_list_by_group_leader() ->
    ToV = fun
        (false) -> <<>>;
        ({_, V}) when is_list(V) -> list_to_binary(V);
        ({_, V}) -> V
    end,

    ToHash = fun(P, ProcInfo) ->
        #{
            <<"pid">> => P,
            <<"parent">> => ToV(lists:keyfind(group_leader, 1, ProcInfo)),
            <<"status">> => ToV(lists:keyfind(status, 1, ProcInfo)),
            <<"name">> => ToV(lists:keyfind(registered_name, 1, ProcInfo))
        }
    end,

    #{
        <<"data">> => #{
            <<"processes">> => [
                ToHash(P, process_info(P))
             || P <- erlang:processes()
            ]
        }
    }.

process_list_by_links() ->
    ToV = fun
        (false) -> <<>>;
        (V) when is_port(V) -> <<>>;
        (V) when is_pid(V) -> list_to_binary(pid_to_list(V));
        ({_, V}) when is_list(V) -> list_to_binary(V);
        ({_, V}) -> V
    end,

    AllProcesss = erlang:processes(),

    ParentFor = fun
        (_Pid, undefined) -> [];
        (Pid, {links, Lst}) -> [{P, Pid} || P <- Lst]
    end,

    Parents = lists:flatten(
        [ParentFor(Pid, process_info(Pid, links)) || Pid <- AllProcesss]
    ),

    ChefPd = list_to_pid("<0.0.0>"),

    ToHash = fun(P, ProcInfo) ->
        Parent =
            case lists:keyfind(P, 1, Parents) of
                {ChefPd, _} -> ChefPd;
                {P, P2} -> P2;
                _ -> P
            end,
        #{
            <<"pid">> => P,
            <<"parent">> => ToV(Parent),
            <<"status">> => ToV(lists:keyfind(status, 1, ProcInfo)),
            <<"name">> => ToV(lists:keyfind(registered_name, 1, ProcInfo))
        }
    end,

    #{
        <<"data">> => #{
            <<"processes">> => [ToHash(P, process_info(P)) || P <- AllProcesss]
        }
    }.
