-module(ered_messages).

-include("ered_nodes.hrl").

-export([
    convert_to_num/1,
    convert_to_integer/1,
    convert_units_to_milliseconds/2,
    create_outgoing_msg/1,
    decode_json/1,
    delete_prop/2,
    encode_json/1,
    escape_specials/1,
    get_prop/2,
    is_same/2,
    is_not_same/2,
    jsbuffer_to_binary/1,
    jsonata_eval_or_error_msg/2,
    map_keys_to_binary/1,
    map_keys_to_lists/1,
    retrieve_prop_value/2,
    set_prop_value/3,
    timestamp/0,
    to_bool/1
]).

%%
%% Helper functions for dealing with messages and their electic needs.
%%

-import(ered_nodes, [
    generate_id/0,
    jstr/2
]).

%%
%% Slim down the Jsonata call for clients.
jsonata_eval_or_error_msg(Jsonata, Msg) ->
    case erlang_red_jsonata:execute(Jsonata, Msg) of
        {ok, Result} ->
            Result;
        {error, Error} ->
            %% TODO replace with proper logging
            io:format(
                "JSONATA ERROR: [~p] ==> [~p]~n",
                [Jsonata, Error]
            ),
            jstr("jsonata error: ~p", [Jsonata]);
        {unsupported, Error} ->
            %% TODO replace with proper logging
            io:format(
                "JSONATA Unsupported: ~p ==> [~p]~n",
                [Jsonata, Error]
            ),
            jstr("jsonata unsupported: ~p", [Error]);
        {exception, {E, M, S}} ->
            %% TODO replace with proper logging
            io:format(
                "JSONATA EXCEP:~n~n~p~n~nCaused:~n~n~p~n~n~p~n~n~p~n",
                [Jsonata, E, M, S]
            ),
            jstr("jsonata exception: ~p", [M])
    end.

%%
%% Used by switch and assert values nodes.
is_same(Same, Diff) when is_list(Same) and is_binary(Diff) ->
    is_same(Same, binary_to_list(Diff));
is_same(Same, Diff) when is_binary(Same) and is_list(Diff) ->
    is_same(binary_to_list(Same), Diff);
is_same(Same, Same) ->
    true;
is_same(_, _) ->
    false.

is_not_same(Same, Diff) when is_list(Same) and is_binary(Diff) ->
    is_not_same(Same, binary_to_list(Diff));
is_not_same(Same, Diff) when is_binary(Same) and is_list(Diff) ->
    is_not_same(binary_to_list(Same), Diff);
is_not_same(Same, Same) ->
    false;
is_not_same(_, _) ->
    true.

%%
%% convert to num - a num can be a integer or float, so to convert a string
%% to one of these inluding the negativity that is minus.
%% It can also contain hexadecimal or binary values.
convert_to_num(V) when is_binary(V) ->
    convert_to_num(binary_to_list(V));
convert_to_num(V) when is_number(V) ->
    V;
convert_to_num(V) when is_integer(V) ->
    V;
convert_to_num(V) when is_list(V) ->
    case erl_numparser:to_number(V) of
        {error, Reason} ->
            {error, jstr("Value '~p' not number: ~p", [V, Reason])};
        {ok, Number} ->
            Number
    end.

%%
%% Used by Buffer fields that convert integerst to binary values.
convert_to_integer(V) when is_binary(V) ->
    convert_to_integer(binary_to_list(V));
convert_to_integer(V) when is_float(V) ->
    element(1, string:to_integer(lists:nth(1, io_lib:format("~p", [V]))));
convert_to_integer(V) when is_list(V) ->
    case erl_numparser:to_number(V) of
        {error, Reason} ->
            {error, jstr("Value '~p' not number: ~p", [V, Reason])};
        {ok, Number} ->
            convert_to_integer(Number)
    end;
convert_to_integer(V) ->
    convert_to_num(V).

%%
%% handle a Buffer "bin" type and convert it to a binary list.
-spec jsbuffer_to_binary(
    String :: binary()
) -> {ok, Bin :: binary()} | {error, Error :: tuple()}.
jsbuffer_to_binary(Value) ->
    case erl_binarytypeparser:to_list(Value) of
        {ok, Lst} ->
            {ok, list_to_binary([floor(abs(V)) rem 256 || V <- Lst])};
        {error, {_LineNum, _Module, Error}, _} ->
            {error, Error}
    end.

%%
%% these are from the trigger node
convert_units_to_milliseconds({ok, <<"hr">>}, {ok, Val}) ->
    {ok, element(1, string:to_integer(Val)) * 1000 * 60 * 60};
convert_units_to_milliseconds({ok, <<"min">>}, {ok, Val}) ->
    {ok, element(1, string:to_integer(Val)) * 1000 * 60};
convert_units_to_milliseconds({ok, <<"s">>}, {ok, Val}) ->
    {ok, element(1, string:to_integer(Val)) * 1000};
convert_units_to_milliseconds({ok, <<"ms">>}, {ok, Val}) ->
    {ok, element(1, string:to_integer(Val))};
%%
%% these are from the delay node
convert_units_to_milliseconds({ok, <<"days">>}, {ok, Val}) ->
    {ok, element(1, string:to_integer(Val)) * 1000 * 60 * 60 * 24};
convert_units_to_milliseconds({ok, <<"hours">>}, {ok, Val}) ->
    {ok, element(1, string:to_integer(Val)) * 1000 * 60 * 60};
convert_units_to_milliseconds({ok, <<"minutes">>}, {ok, Val}) ->
    {ok, element(1, string:to_integer(Val)) * 1000 * 60};
convert_units_to_milliseconds({ok, <<"seconds">>}, {ok, Val}) ->
    {ok, element(1, string:to_integer(Val)) * 1000};
convert_units_to_milliseconds({ok, <<"milliseconds">>}, {ok, Val}) ->
    {ok, element(1, string:to_integer(Val))};
convert_units_to_milliseconds(A, B) ->
    {error, jstr("WARNING: convert to ms: nomatch for ~p & ~p~n", [A, B])}.

%%
%% When something is a date type, it gets this value.
timestamp() ->
    erlang:system_time(millisecond).

%%
%% Decode a json string just like we like it, with atoms as keys
decode_json(Val) when is_list(Val) ->
    decode_json(list_to_binary(Val));
decode_json(Val) ->
    json:decode(Val).

%%
%%
%% This is json:encode except that Pids are converted to strings. Used for
%% the contents of debug messages - that may certainly contain a Pid or two.
%% Tuples are also a foe of JSON - convert them to lists.
%%
encoder({K, V}, Encode) ->
    json:encode_value([K, V], Encode);
encoder([{_, _} | _] = Value, Encode) ->
    json:encode_key_value_list(Value, Encode);
encoder(Other, Encode) when is_tuple(Other) ->
    json:encode_value(tuple_to_list(Other), Encode);
encoder(Other, Encode) when is_reference(Other) ->
    json:encode_value(list_to_binary(ref_to_list(Other)), Encode);
encoder(Other, Encode) when is_pid(Other) ->
    json:encode_value(list_to_binary(pid_to_list(Other)), Encode);
encoder(Other, Encode) when is_binary(Other) ->
    %% if not then: exception error: {invalid_byte,130}
    %% can prevent encoding - binary data which doesn't fit is converted
    %% to a list.
    try
        json:encode_value(Other, Encode)
    catch
        error:E:S ->
            io:format("Json Encoding Error ~p ~p~n", [E, S]),
            json:encode_value(binary_to_list(Other), Encode)
    end;
encoder(Other, Encode) ->
    json:encode_value(Other, Encode).

%%
encode_json(Value) ->
    try
        json:encode(Value, fun encoder/2)
    catch
        error:E:S ->
            io:format("JSON ENCODING ERROR [~p] [~p]~n", [E, Value]),
            io:format("Stack [~p]~n", [S]),
            json:encode(#{payload => "encoding error, check logs"})
    end.

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
%% or
%%    {error, ErrorMsg}
%%
get_prop({ok, Prop}, Msg) ->
    ered_nested_maps:find(Prop, Msg);
get_prop(Prop, Msg) ->
    ered_nested_maps:find(Prop, Msg).

%%
%% Retrieve a nested parameters from the Msg map.
-spec retrieve_prop_value(PropName :: string(), Msg :: map()) -> any().
retrieve_prop_value(PropName, Msg) ->
    case get_prop({ok, PropName}, Msg) of
        {ok, V, _} ->
            V;
        _ ->
            ""
    end.

%% Set a value in a nested map. This supports using nesting parameters to
%% set a value somewhere in a map.
-spec set_prop_value(
    PropName :: string() | binary(),
    Value :: any(),
    Msg :: map()
) -> map().
set_prop_value(PropName, Value, Msg) ->
    case ered_nested_maps:update(PropName, Msg, Value) of
        {ok, NewMsg, _Path} ->
            NewMsg;
        R ->
            io:format(
                "ERROR setting value: ~p =.=> ~p~n",
                [PropName, R]
            ),
            %% silently ignore errors
            Msg
    end.

%%
%% remove an property that happens to match the nested path provided.
-spec delete_prop(
    PropName ::
        string()
        | binary()
        | {ok, PropName :: string()}
        | {ok, PropName :: binary()},
    Msg :: map()
) -> Map :: map().
delete_prop({ok, PropName}, Msg) ->
    delete_prop(PropName, Msg);
delete_prop(PropName, Msg) ->
    ered_nested_maps:delete(PropName, Msg).

%%
%% Generate an empty message map with just an _msgid
create_outgoing_msg(WsName) ->
    {outgoing, ?AddWsName(#{'_msgid' => generate_id()})}.

%%
%%
key_to_binary(V) when is_binary(V) ->
    V;
key_to_binary(V) when is_atom(V) ->
    erlang:atom_to_binary(V);
key_to_binary(V) when is_list(V) ->
    erlang:list_to_binary(V);
key_to_binary(V) ->
    V.

%%
%%
map_keys_to_binary(Map) ->
    maps:from_list(
        lists:map(
            fun({D, E}) -> {key_to_binary(D), E} end,
            maps:to_list(Map)
        )
    ).

%%
%%
key_to_list(V) when is_binary(V) ->
    erlang:binary_to_list(V);
key_to_list(V) when is_atom(V) ->
    erlang:atom_to_list(V);
key_to_list(V) when is_list(V) ->
    V;
key_to_list(V) ->
    V.

%%
%%
map_keys_to_lists(Map) ->
    maps:from_list(
        lists:map(
            fun({D, E}) -> {key_to_list(D), E} end,
            maps:to_list(Map)
        )
    ).

%%
%%
%% erlfmt:ignore alignment
to_bool(<<"">>)      -> false;
to_bool("")          -> false;
to_bool(<<"false">>) -> false;
to_bool(false)       -> false;
to_bool("false")     -> false;
to_bool(_) -> true.

%%
%% From a string value, escape all occurance of \r \t \n to be replaced
%% by \\r \\t \\n - this allows for test definitions that include \r and
%% not a "return" or "tab" value.
%%
escape_specials(Str) when is_integer(Str) ->
    escape_specials(integer_to_binary(Str));
escape_specials(Str) when is_atom(Str) ->
    escape_specials(atom_to_binary(Str));
escape_specials(Str) when is_tuple(Str) ->
    [escape_specials(A) || A <- tuple_to_list(Str)];
escape_specials(Str) ->
    re:replace(
        re:replace(
            re:replace(
                Str,
                "\r",
                "\\\\r",
                [{return, binary}, global]
            ),
            "\n",
            "\\\\n",
            [{return, binary}, global]
        ),
        "\t",
        "\\\\t",
        [{return, binary}, global]
    ).
