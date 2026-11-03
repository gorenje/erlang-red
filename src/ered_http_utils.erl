-module(ered_http_utils).

-export([
    read_body/2,
    flowhub_hostname_from_token/1
]).

read_body(Req0, Acc) ->
    case cowboy_req:read_body(Req0) of
        {ok, Data, Req} -> {ok, <<Acc/binary, Data/binary>>, Req};
        {more, Data, Req} -> read_body(Req, <<Acc/binary, Data/binary>>)
    end.

flowhub_hostname_from_token(Token) ->
    case Token of
        <<"local://", HostAndMore/binary>> = T ->
            Hst =
                case string:split(HostAndMore, "?") of
                    [Host, _] -> Host;
                    [Host] -> Host
                end,
            {Hst, T};
        T ->
            {<<"https://api.flowhub.org">>, T}
    end.
