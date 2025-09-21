-module(ered_nested_maps).

%%
%% Similar to [mapz](https://github.com/eproxus/mapz) but supports indexes into
%% lists. These come from the attribute parser included here.
%%
%% In Node-RED it is possible to use array indicies in addressing nested hashes
%% and mapz does not support lists nested within hashes. So this addresses
%% that and stores remove/updating/finding stuff in a mixture of hashes
%% and lists.
%%

-export([
    find/2,
    update/3,
    delete/2
]).

-import(ered_messages, [
    convert_to_num/1
]).

%%
%%
-spec delete(
    Path :: binary() | string(),
    Msg :: map()
) ->
    Map :: map().
delete(<<>>, Msg) ->
    Msg;
delete("", Msg) ->
    Msg;
delete(Path, Msg) ->
    case erl_attributeparser:attributes_to_array(Path) of
        {ok, KeyNames} ->
            try
                element(2, deep_delete(Msg, KeyNames))
            catch
                throw:made_no_change ->
                    Msg;
                error:_ ->
                    Msg
            end;
        Error ->
            io:format("ERROR get_prop {{{ ~p }}}~n", [Error]),
            Msg
    end.

%%
%%
-spec find(
    Path :: binary() | string(),
    Msg :: map()
) ->
    {ok, Value :: any(), Path :: binary() | string()}
    | {error, Reason :: any()}
    | {undefined, Path :: binary()}.
find(<<>> = P, _Msg) ->
    {undefined, P};
find("" = P, _Msg) ->
    {undefined, P};
find(Path, Msg) ->
    case erl_attributeparser:attributes_to_array(Path) of
        {ok, KeyNames} ->
            case deep_find_with_arrays(KeyNames, {ok, Msg}) of
                {ok, V} ->
                    {ok, V, Path};
                error ->
                    {undefined, Path}
            end;
        Error ->
            io:format("ERROR get_prop {{{ ~p }}}~n", [Error]),
            Error
    end.

%%
%%
-spec update(
    Path :: binary() | string(),
    Msg :: map(),
    NewValue :: any()
) ->
    {ok, Value :: any, Path :: binary() | string()}
    | {error, Reason :: any()}
    | {undefined, Path :: binary(), ErrorTuple :: tuple()}.
update(<<>> = P, Msg, _NewValue) ->
    {ok, Msg, P};
update("" = P, Msg, _NewValue) ->
    {ok, Msg, P};
update(Path, Msg, NewValue) ->
    case erl_attributeparser:attributes_to_array(Path) of
        {ok, [{idx, Idx} | KeyNames]} ->
            case deep_update(Msg, [Idx | KeyNames], NewValue) of
                {ok, V} ->
                    {ok, V, Path};
                {error, ErrorTuple} ->
                    {undefined, Path, ErrorTuple}
            end;
        {ok, KeyNames} ->
            case deep_update(Msg, KeyNames, NewValue) of
                {ok, V} ->
                    {ok, V, Path};
                {error, ErrorTuple} ->
                    {undefined, Path, ErrorTuple}
            end;
        Error ->
            io:format("ERROR get_prop {{{ ~p }}}~n", [Error]),
            Error
    end.

%%
%% Node-RED has array indicies in property names. Need to support those too.
%% Erlang has tuples which can also be indexed, need to support them as lists.
%%
deep_find_with_arrays([], error) ->
    error;
deep_find_with_arrays([], {ok, Value}) ->
    {ok, Value};
deep_find_with_arrays([_Key | _Keys], {ok, []}) ->
    error;
deep_find_with_arrays([_Key | _Keys], error) ->
    error;
%
deep_find_with_arrays([{idx, Idx} | Keys], {ok, Value}) when is_list(Value) ->
    deep_find_with_arrays(Keys, {ok, lists:nth(Idx + 1, Value)});
deep_find_with_arrays([{idx, Idx} | Keys], {ok, Value}) when is_map(Value) ->
    deep_find_with_arrays(Keys, maps:find(integer_to_binary(Idx), Value));
deep_find_with_arrays([{idx, Idx} | Keys], {ok, Value}) when is_tuple(Value) ->
    deep_find_with_arrays(Keys, {ok, element(Idx + 1, Value)});
%
deep_find_with_arrays([Key | Keys], {ok, Value}) when is_map(Value) ->
    deep_find_with_arrays(Keys, maps:find(Key, Value));
deep_find_with_arrays([Key | Keys], {ok, Value}) when is_tuple(Value) ->
    case convert_to_num(Key) of
        {error, _} ->
            error;
        V ->
            deep_find_with_arrays(Keys, {ok, element(V + 1, Value)})
    end;
deep_find_with_arrays([Key | Keys], {ok, Value}) when is_list(Value) ->
    case convert_to_num(Key) of
        {error, _} ->
            error;
        V ->
            deep_find_with_arrays(Keys, {ok, lists:nth(V + 1, Value)})
    end.

%%
%% Deep delete
%%
deep_delete(Container, []) ->
    {ok, Container};
deep_delete(Container, [{idx, Idx} | []]) when is_map(Container) ->
    {ok, maps:remove(integer_to_binary(Idx), Container)};
deep_delete(Container, [Key | []]) when is_map(Container) ->
    {ok, maps:remove(Key, Container)};
deep_delete(Container, [{idx, Idx} | []]) when
    is_list(Container), length(Container) =< Idx
->
    {ok, Container};
deep_delete(Container, [{idx, Idx} | []]) when
    is_list(Container), length(Container) > Idx
->
    {ok, removenth(Idx + 1, Container)};
deep_delete(Container, [Key | []]) when is_list(Container) ->
    case convert_to_num(Key) of
        {error, _} ->
            {ok, Container};
        V ->
            deep_delete(Container, [{idx, V}])
    end;
deep_delete(Container, [{idx, Idx} | _Path]) when
    is_list(Container), length(Container) =< Idx
->
    %% can't continue, list is too short for index - no change to be made.
    throw(made_no_change);
deep_delete(Container, [{idx, Idx} | Path]) when
    is_list(Container), length(Container) > Idx
->
    Result =
        try
            deep_delete(lists:nth(Idx + 1, Container), Path)
        catch
            error:_ ->
                throw(made_no_change)
        end,
    {ok, Value} = Result,
    {ok, setnth(Idx + 1, Container, Value)};
deep_delete(Container, [Key | Path]) when is_map(Container) ->
    Result =
        case maps:find(Key, Container) of
            {ok, Existing} ->
                deep_delete(Existing, Path);
            error ->
                throw(made_no_change)
        end,
    {ok, Value} = Result,
    {ok, Container#{Key => Value}};
deep_delete(_Container, _Path) ->
    % doghouse again, something went horribly wrong with the type of container.
    throw(made_no_change).

%%
%% Deep update understands {idx,Idx} tuples for array/list access.
%% It creates lists for missing index values and maps for missing
%% keynames.
%%
%% Any new lists are filled with empty maps. Any existing lists that are
%% too short of an index value are extended by filling them with empty maps.
%%
deep_update(Map, [], _NewVal) ->
    {ok, Map};
deep_update(Container, [{idx, Idx} | []], NewVal) when is_list(Container) ->
    % NodeJS is zero based indicies, so is Erlang-Red even if Erlang is
    % different there.
    {ok, setnth(Idx + 1, Container, NewVal)};
%% this happens when the list didn't exist and was added as a map, but it should
%% really be an array. This being the last key, it actually remains a hash
%% - this is Node-RED behaviour that a last idx is represented as a hash
%% not array.
deep_update(Container, [{idx, Idx} = Key | []], NewVal) when
    is_map(Container)
->
    Container2 = maps:remove(Key, Container),
    {ok, Container2#{integer_to_binary(Idx) => NewVal}};
deep_update(Container, [Key | []], NewVal) when is_map(Container) ->
    {ok, Container#{Key => NewVal}};
%% list is too short for index, have to extend an existing list
%% keep looping and adding maps to the array until its long enough
deep_update(Container, [{idx, Idx} | _Path] = Loc, NewVal) when
    is_list(Container), length(Container) =< Idx
->
    deep_update(Container ++ [#{}], Loc, NewVal);
deep_update(Container, [{idx, Idx} | Path] = Loc, NewVal) when
    is_list(Container), length(Container) > Idx
->
    Result =
        try
            deep_update(lists:nth(Idx + 1, Container), Path, NewVal)
        catch
            error:Er ->
                {error, {list_error, Loc, Container, NewVal, Er}}
        end,

    case Result of
        {ok, Value} ->
            {ok, setnth(Idx + 1, Container, Value)};
        {error, _} = E ->
            E
    end;
%% this happens when the list didn't exist and was added as a map, but it should
%% really be an array/list.
deep_update(Container, [{idx, Idx} | Path], NewVal) when is_map(Container) ->
    Lst = create_empty_list(Idx + 1),
    case deep_update(Container, Path, NewVal) of
        {ok, V} ->
            {ok, setnth(Idx + 1, Lst, V)};
        {error, _} = E ->
            E
    end;
deep_update(Container, [Key | Path], NewVal) when is_map(Container) ->
    Result =
        case maps:find(Key, Container) of
            {ok, Existing} ->
                deep_update(Existing, Path, NewVal);
            error ->
                deep_update(#{}, Path, NewVal)
        end,

    case Result of
        {ok, Value} ->
            {ok, Container#{Key => Value}};
        {error, _} = E ->
            E
    end;
deep_update(Thing, Loc, NewVal) ->
    % if we got here, then it's not a map nor list ... something went badly
    % wrong and we're in the doghouse now.
    {error, {type_error, Loc, Thing, NewVal}}.

%%
%%
create_empty_list(Sze) -> create_empty_list(Sze, []).
create_empty_list(0, Lst) -> Lst;
create_empty_list(Sze, Lst) -> create_empty_list(Sze - 1, [null | Lst]).

%%
%%
setnth(1, [_ | Rest], New) -> [New | Rest];
setnth(I, [E | Rest], New) -> [E | setnth(I - 1, Rest, New)].

removenth(Idx, Lst) when Idx < 1 -> Lst;
removenth(Idx, Lst) when length(Lst) < Idx -> Lst;
removenth(Idx, Lst) ->
    {Front, [_ | Back]} = lists:split(Idx - 1, Lst),
    Front ++ Back.
