-module(ensure_universal_unique_nodeids).

%%
%% A test to ensure that all node ids are unique across all flow tests.
%% If not, then bad things will happen when doing tests.
%%
%% To recectify the problem, load the corresponding classhes into NodeRED
%% and "import copy" will replaced dupicate NodeIds with new Ids. The export
%% the test case again.
%%
-include_lib("eunit/include/eunit.hrl").

push_nodeid_onto_stack([], Stack, _FileName) ->
    Stack;
push_nodeid_onto_stack(
  [#{<<"id">> := NodeId} = _NodeDef | T], Stack, FileName
) ->
    Stack2 =
        case maps:find(NodeId, Stack) of
            {ok, Val} ->
                Stack#{NodeId => [FileName | Val]};
            _ ->
                Stack#{NodeId => [FileName]}
        end,
    push_nodeid_onto_stack(T, Stack2, FileName).

map_of_nodeids([], Map) ->
    Map;
map_of_nodeids([FileName | FileNames], Stack) ->
    Ary = ered_flows:parse_flow_file(FileName),
    Stack2 = push_nodeid_onto_stack(Ary, Stack, FileName),
    map_of_nodeids(FileNames, Stack2).

%%
%% Any array with two or more entries is a duplicate, so match for arrays
%% that contain exactly one filename.
is_duplicate({_, [_SingleFileName | []]}) ->
    false;
is_duplicate({_, _}) ->
    true.

duplicates([], Acc) ->
    Acc;
duplicates([H | T], Acc) ->
    case is_duplicate(H) of
        true -> duplicates(T, [H | Acc]);
        _ -> duplicates(T, Acc)
    end.


%%
%% Scan each file and collect all IDs. Each ID should only appear in one
%% filename, if that is not the case, then this test fails.
ensure_universally_unique_nodeids_test() ->
    {_Cnt, FileNames} = filelib:fold_files(
        code:priv_dir(erlang_red) ++ "/testflows/",
        "",
        true,
        fun(Fname, Acc) ->
            {element(1, Acc) + 1, [Fname | element(2, Acc)]}
        end,
        {0, []}
    ),

    MapOfNodeIds = map_of_nodeids(FileNames, #{}),

    ?assertNotEqual(#{}, MapOfNodeIds),

    List = duplicates(maps:to_list(MapOfNodeIds), []),

    ?assertEqual([], List).
