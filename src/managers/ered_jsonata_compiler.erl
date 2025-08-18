-module(ered_jsonata_compiler).

-export([
    compile_stanzas/1,
    find_function_for_stanza/2
]).

%%
%% Collection of helpers for compiling JSONata stanzas before they
%% are executed.
%%
compile_stanzas(JSONataStanzas) ->
    compile_stanzas(JSONataStanzas, #{}, []).

compile_stanzas([], Cache, Errors) ->
    {Errors, Cache};
compile_stanzas([JSONata | Rest], Cache, Errors) ->
    case erlang_red_jsonata:compile_to_function(JSONata) of
        {ok, Func} ->
            compile_stanzas(
                Rest,
                Cache#{
                    %% MD5 because a) small set of stanzas, b) each node
                    %% maintains its own list, this is not a global collection.
                    crypto:hash(md5, JSONata) => Func
                },
                Errors
            );
        R ->
            compile_stanzas(Rest, Cache, [R | Errors])
    end.
%%
%%
find_function_for_stanza(JSONata, Cache) ->
    Hash = crypto:hash(md5, JSONata),
    case maps:find(Hash, Cache) of
        {ok, Func} ->
            Func;
        _ ->
            {ok, Func2} = erlang_red_jsonata:compile_to_function(JSONata),
            Func2
    end.
