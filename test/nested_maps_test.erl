-module(nested_maps_test).

-include_lib("eunit/include/eunit.hrl").

find_edgecases_test() ->
    ?assertEqual(
        {undefined, <<>>},
        ered_nested_maps:find(<<"">>, #{})
    ),
    ?assertEqual(
        {undefined, ""},
        ered_nested_maps:find("", #{})
    ).

find_tuples_in_lists_of_hashes_test() ->
    ?assertEqual(
        {ok, p, <<"f[0][1].a[2]">>},
        ered_nested_maps:find(
            <<"f[0][1].a[2]">>,
            #{
                <<"f">> =>
                    [[undefined, #{<<"a">> => {t, u, p, l, e}}]]
            }
        )
    ),
    ?assertEqual(
        {ok, p, <<"f[0][1].a[2]">>},
        ered_nested_maps:find(
            <<"f[0][1].a[2]">>,
            #{
                <<"f">> =>
                    {{undefined, #{<<"a">> => {t, u, p, l, e}}}}
            }
        )
    ),
    ?assertEqual(
        {ok, 3, <<"f[0][1].a[2][2]">>},
        ered_nested_maps:find(
            <<"f[0][1].a[2][2]">>,
            #{
                <<"f">> =>
                    {{undefined, #{<<"a">> => {t, u, [1, 2, 3], l, e}}}}
            }
        )
    ),
    ?assertEqual(
        {ok, 2, <<"f[1]">>},
        ered_nested_maps:find(
            <<"f[1]">>,
            #{
                <<"f">> => {1,2,3}
            }
        )
    ).

update_existing_test() ->
    TestData = json:decode(
        <<"{\"array\":[0,1,{\"object\":[2,3,4,{\"object\":[1,\"value\"]}]}]}">>
    ),

    Key = "payload.array.2.object.3.object[1]",

    {ok, Result, _Path} = ered_nested_maps:update(
        Key,
        #{<<"payload">> => TestData},
        <<"another value">>
    ),

    ?assertEqual(
        {ok, <<"value">>, Key},
        ered_nested_maps:find(Key, #{<<"payload">> => TestData})
    ),

    ?assertEqual(
        {ok, <<"another value">>, Key},
        ered_nested_maps:find(Key, Result)
    ).

update_non_existing_test() ->
    Key = "payload.array.2.object.3.object[1]",

    {ok, Result, _Path} = ered_nested_maps:update(
        Key,
        #{},
        <<"a value">>
    ),

    ?assertEqual(
        {ok, <<"a value">>, Key},
        ered_nested_maps:find(Key, Result)
    ).

update_extend_existing_test() ->
    % first create a structre and then add another "branch" in the middle.
    R = ered_nested_maps:update(
        "a.0.b.0.c.1.10.d.e.1",
        element(2, ered_nested_maps:update("a.0.b.0.c.0.0.d.e", #{}, v)),
        new_value
    ),

    Result = element(2, R),

    ?assertEqual(
        new_value,
        element(2, ered_nested_maps:find("a.0.b.0.c.1.10.d.e.1", Result))
    ),
    ?assertEqual(
        v,
        element(2, ered_nested_maps:find("a.0.b.0.c.0.0.d.e", Result))
    ).

edgecases_that_i_thought_of_test() ->
    ?assertEqual(
        new_value,
        maps:get(
            1,
            element(
                2,
                ered_nested_maps:update(
                    "1",
                    #{},
                    new_value
                )
            )
        )
    ),

    ?assertEqual(
        new_value,
        maps:get(
            <<"a">>,
            element(
                2,
                ered_nested_maps:update(
                    "a",
                    #{},
                    new_value
                )
            )
        )
    ),

    ?assertEqual(
        new_value,
        maps:get(
            atom,
            element(
                2,
                ered_nested_maps:update(
                    "'atom'",
                    #{},
                    new_value
                )
            )
        )
    ),

    ?assertEqual(
        #{atom => [null, #{<<"what">> => new_value}]},
        element(
            2,
            ered_nested_maps:update(
                "'atom'.1[\"what\"]",
                #{},
                new_value
            )
        )
    ),

    ?assertEqual(
        #{atom => [null, #{<<"what">> => new_value}]},
        element(
            2,
            ered_nested_maps:update(
                "'atom'[1][\"what\"]",
                #{},
                new_value
            )
        )
    ),

    ?assertEqual(
        #{hello => world},
        element(
            2,
            ered_nested_maps:update(
                "",
                #{hello => world},
                new_value
            )
        )
    ).

delete_test() ->
    ?assertEqual(#{}, ered_nested_maps:delete("d", #{<<"d">> => "ddd"})),

    % remove the first element of the list at 'b'
    ?assertEqual(
        #{<<"a">> => [#{<<"b">> => []}]},
        ered_nested_maps:delete(
            "a.0.b.0",
            element(2, ered_nested_maps:update("a.0.b.0.c.0.0.d.e", #{}, v))
        )
    ),

    %% list too short for index
    Same = ered_nested_maps:update("a.0.b.0.c.0.0.d.e", #{}, v),
    ?assertEqual(
        element(2, Same),
        ered_nested_maps:delete(
            "a.0.b.1",
            element(2, Same)
        )
    ),

    ?assertEqual(
        #{<<"d">> => "ddd"},
        ered_nested_maps:delete("d.1.2", #{<<"d">> => "ddd"})
    ).

delete_strings_are_lists_test() ->
    %%
    %% Ouch: strings are lists, "ddd" is a list and d[1] is remove the third
    %% 'd' from the list!
    ?assertEqual(
        #{<<"d">> => "dd"},
        ered_nested_maps:delete("d[1]", #{<<"d">> => "ddd"})
    ),
    ?assertEqual(
        #{<<"d">> => "dd"},
        ered_nested_maps:delete("d.1", #{<<"d">> => "ddd"})
    ).

delete_elemete_from_last_array_test() ->
    {ok, Same, _} = ered_nested_maps:update("a.0.b.0.c.0.0.d.e.1", #{}, v),

    {ok, NewSame, _} = ered_nested_maps:update("a.0.b.0.c.0.0.d.e", Same, #{}),

    ?assertEqual(
        NewSame,
        ered_nested_maps:delete(
            "a.0.b.0.c.0.0.d.e.1",
            element(
                2,
                ered_nested_maps:update(
                    "a.0.b.0.c.0.0.d.e.1", #{}, v
                )
            )
        )
    ).
