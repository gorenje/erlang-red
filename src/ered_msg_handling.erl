-module(ered_msg_handling).

-export([
    get_prop/2,
    decode_json/1,
    timestamp/0
]).

%%
%% When something is a date type, it gets this value.
timestamp() ->
    erlang:system_time(millisecond).

%%
%% Decode a json string just like we like it, with atoms as keys
decode_json(Val) ->
    AtomizeKeys = fun(Key, Value, Acc) ->
        [{binary_to_atom(Key), Value} | Acc]
    end,
    {Obj, _, _} = json:decode(Val, ok, #{object_push => AtomizeKeys}),
    Obj.

%%
%% Helper for dealing with properties of the form:
%%    payload.value1.value2.value3
get_nested_value(V, []) ->
    {ok, V};
get_nested_value(Map, [H | T]) when is_map(Map) and is_binary(H) ->
    get_nested_value(Map, [binary_to_atom(H) | T]);
get_nested_value(Map, [H | T]) when is_map(Map) and is_list(H) ->
    get_nested_value(Map, [list_to_atom(H) | T]);
get_nested_value(Map, [H | T]) when is_map(Map) and is_atom(H) ->
    case maps:find(H, Map) of
        {ok, Val} ->
            get_nested_value(Val, T);
        _ ->
            undefined
    end;
get_nested_value(_, _) ->
    undefined.

%%
%% get prop can used to retrieve a nestd value from the Msg map, i.e.,
%%    msg.payload.key1.key2.key3
%% from this:
%%    #{ paylad => #{ key1 => #{ key2 => key3 => <<"this is the value">> }}}
%% gives
%%    <<"this is the value">>
%%
%% designed to be used with a maps:find, e.g.
%%
%%    get_prop(maps:find(p,Rule), Msg)
%%
%% retuns
%%
%%    {ok, Value, Prop}
%% or
%%    {undefined, Prop}
%%
get_prop({ok, Prop}, Msg) ->
    case get_nested_value(Msg, string:split(Prop, ".", all)) of
        {ok, V} ->
            {ok, V, Prop};
        undefined ->
            {undefined, Prop}
    end.
