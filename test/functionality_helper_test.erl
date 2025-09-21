-module(functionality_helper_test).

-include_lib("eunit/include/eunit.hrl").

-import(ered_nodes, [
    is_improper_list/1,
    within_range/3
]).

-import(ered_messages, [
    convert_to_num/1
]).

convert_to_num_test() ->
    ?assertEqual(1.1, convert_to_num("1.1")),
    ?assertEqual(1.1, convert_to_num(<<"1.1">>)),
    ?assertEqual(1.1, convert_to_num(1.1)),
    ?assertEqual(2, convert_to_num(<<2:4>>)),
    ?assertEqual(1000000, convert_to_num(<<"1_00_000_0">>)).

within_range_test() ->
    ?assert(within_range(1, 1, 1)),
    ?assert(within_range(1, 0, 0.5)),
    ?assert(within_range(0, 1, 0.5)),
    ?assert(within_range(-1, 1, 1)),
    ?assert(within_range(1, -1, -1)),

    ?assert(within_range(1, -10, 1)),

    ?assertNot(within_range(1, -10, 2)),
    ?assertNot(within_range(1, -10, -10.1)),
    ?assert(within_range(1, -10, -1.1)),
    ?assertNot(within_range(1, -10, 1.1)),

    ?assert(within_range(2, 3, 2.1)),
    ?assert(within_range(3, 2, 2.1)),

    ?assertNot(within_range(10, 100, 1)),
    ?assert(within_range(-1, 1, 0)).

not_improper_list_test_() ->
    CreateTest = fun(V) ->
        {
            list_to_binary(
                io_lib:format(
                    "not improper list testing ~p", [V]
                )
            ),
            fun() ->
                ?assert(not is_improper_list(V)),
                ?assert(is_list(V))
            end
        }
    end,
    Lists = [
        [],
        "",
        [[] | []],
        [1 | []],
        [atom | [atom]],
        [1, 2, 3],
        [atom | []],
        [#{}, #{}]
    ],

    {inparallel, 100, [CreateTest(V) || V <- Lists]}.

improper_list_test_() ->
    CreateTest = fun(V) ->
        {
            list_to_binary(io_lib:format("improper list testing ~p", [V])),
            fun() ->
                ?assert(is_improper_list(V)),
                ?assert(is_list(V))
            end
        }
    end,

    ImproperList = [
        [#{} | #{}],
        [1 | #{}],
        [1, 2 | #{}],
        [1, 2 | 3],
        [1, 2 | atom],
        [1, 2, 3 | atom],
        [1 | atom],
        [atom | atom]
    ],

    {inparallel, 100, [CreateTest(V) || V <- ImproperList]}.
