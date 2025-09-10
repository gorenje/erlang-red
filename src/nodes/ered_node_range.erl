-module(ered_node_range).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Range node maps values from one range to another using a set of basic
%% configuration options.
%%
%%
%% "id": "1369cac017806ca4",
%% "type": "range",
%%
%% "minin": "0",  <<-----+-- input range
%% "maxin": "9.5", <<---/
%% "minout": "0",  <<------+-- target range
%% "maxout": "100.5", <<--/
%% "action": "scale",  <<---- various actions
%% "round": true, <<---- round up to the nearest integer value
%% "property": "payload", <<---- property to act on
%%
%% There are four (at time of writing) possible actions:
%%   - (action = 'scale') scale the message property - values can be out of bounds of the target range
%%   - (action = 'clamp') scale and limit to target range - values are bounded to the target range with maximum being max target range and minimum being mini target range
%%   - (action = 'roll') scale and wrap within the target range
%%   - (action = 'drop') scale but drop msg if outside of input range - if the payload is outside of the input range, drop the message.
%%
%% The implementation logic is mostly taken from the Node-RED node:
%%   https://github.com/node-red/node-red/blob/9ad329e5a184cbd749f4cacf30ae775d1205eba6/packages/node_modules/%40node-red/nodes/core/function/16-range.js
%%

-import(ered_messages, [
    convert_to_num/1,
    get_prop/2,
    set_prop_value/3
]).
-import(ered_nodes, [
    send_msg_to_connected_nodes/2,
    within_range/3
]).

start(
    #{
        <<"minin">> := MinIn,
        <<"maxin">> := MaxIn,
        <<"minout">> := MinOut,
        <<"maxout">> := MaxOut
    } = NodeDef,
    _WsName
) ->
    ered_node:start(
        NodeDef#{
            '_inTo' => convert_to_num(MaxIn),
            '_outTo' => convert_to_num(MaxOut),
            '_inFrom' => convert_to_num(MinIn),
            '_outFrom' => convert_to_num(MinOut)
        },
        ?MODULE
    ).

%%
%%
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg(
    {incoming, Msg},
    #{
        <<"action">> := <<"drop">>,
        <<"property">> := PropName,
        '_inTo' := InTo,
        '_inFrom' := InFrom
    } = NodeDef
) ->
    case get_prop(PropName, Msg) of
        {ok, Payload, _} ->
            Value = convert_to_num(Payload),

            case within_range(InFrom, InTo, Value) of
                false ->
                    {handled, NodeDef, Msg};
                true ->
                    NewValue =
                        round_value(
                            scale_value(Value, NodeDef), NodeDef
                        ),
                    send_off_value(NewValue, NodeDef, Msg)
            end;
        _ ->
            %% no payload - pass on message and do nothing.
            send_msg_to_connected_nodes(NodeDef, Msg),
            {handled, NodeDef, dont_send_complete_msg}
    end;
%%
handle_msg(
    {incoming, Msg},
    #{
        <<"action">> := <<"scale">>,
        <<"property">> := PropName
    } = NodeDef
) ->
    case get_prop(PropName, Msg) of
        {ok, Payload, _} ->
            Value = convert_to_num(Payload),

            NewValue = round_value(scale_value(Value, NodeDef), NodeDef),

            send_off_value(NewValue, NodeDef, Msg);
        _ ->
            %% no payload - pass on message and do nothing.
            send_msg_to_connected_nodes(NodeDef, Msg),
            {handled, NodeDef, dont_send_complete_msg}
    end;
%%
handle_msg(
    {incoming, Msg},
    #{
        <<"action">> := <<"clamp">>,
        <<"round">> := false,
        <<"property">> := PropName
    } = NodeDef
) ->
    case get_prop(PropName, Msg) of
        {ok, Payload, _} ->
            Value = convert_to_num(Payload),

            NewValue = clamp_to_target(scale_value(Value, NodeDef), NodeDef),

            send_off_value(NewValue, NodeDef, Msg);
        _ ->
            %% no payload - pass on message and do nothing.
            send_msg_to_connected_nodes(NodeDef, Msg),
            {handled, NodeDef, dont_send_complete_msg}
    end;
handle_msg(
    {incoming, Msg},
    #{
        <<"action">> := <<"clamp">>,
        <<"round">> := true,
        <<"property">> := PropName,
        '_outTo' := OutTo,
        '_outFrom' := OutFrom
    } = NodeDef
) ->
    case get_prop(PropName, Msg) of
        {ok, Payload, _} ->
            Value = convert_to_num(Payload),

            NewValue =
                push_into_range(
                    OutFrom,
                    OutTo,
                    round_value(
                        clamp_to_target(
                            scale_value(Value, NodeDef), NodeDef
                        ),
                        NodeDef
                    )
                ),
            %% Argh. A target range of 0.3 to 0.9 has no valid value since
            %% both zero and one aren't within the range ... so we need to
            %% do one final "within_range" check.
            case within_range(OutFrom, OutTo, NewValue) of
                true ->
                    send_off_value(NewValue, NodeDef, Msg);
                false ->
                    {handled, NodeDef, dont_send_complete_msg}
            end;
        _ ->
            %% no payload - pass on message and do nothing.
            send_msg_to_connected_nodes(NodeDef, Msg),
            {handled, NodeDef, dont_send_complete_msg}
    end;
%%
handle_msg(
    {incoming, Msg},
    #{
        <<"action">> := <<"roll">>,
        <<"property">> := PropName
    } = NodeDef
) ->
    case get_prop(PropName, Msg) of
        {ok, Payload, _} ->
            Value = convert_to_num(Payload),

            NewValue =
                round_value(
                    scale_value(
                        roll_around(Value, NodeDef), NodeDef
                    ),
                    NodeDef
                ),

            send_off_value(NewValue, NodeDef, Msg);
        _ ->
            %% no payload - pass on message and do nothing.
            send_msg_to_connected_nodes(NodeDef, Msg),
            {handled, NodeDef, dont_send_complete_msg}
    end;
%%
%% fall through onto the other side
%%
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% ------------------ helpers
%%

%% push_into_range gets called with integer values, so doing a +1 or -1 is
%% perfectly safe and also correct. This assumes what the Value has already
%% been clamped to a specific range is off by one.
push_into_range(From, To, Value) when
    Value >= 0, From > To, Value > From;
    Value >= 0, To > From, Value > To
->
    Value - 1;
push_into_range(From, To, Value) when
    Value =< 0, From < To, Value < From;
    Value =< 0, To < From, Value < To
->
    Value + 1;
push_into_range(_, _, Value) ->
    Value.

%%
%%
send_off_value(Value, #{<<"property">> := PropName} = NodeDef, Msg) ->
    send_msg_to_connected_nodes(NodeDef, set_prop_value(PropName, Value, Msg)),
    {handled, NodeDef, Msg}.

%%
%%
scale_value(
    Value,
    #{
        '_inTo' := InTo,
        '_outTo' := OutTo,
        '_inFrom' := InFrom,
        '_outFrom' := OutFrom
    } = _NodeDef
) ->
    ((Value - InFrom) / (InTo - InFrom) * (OutTo - OutFrom)) + OutFrom.

%%
%%
round_value(Value, #{<<"round">> := true}) ->
    erlang:round(Value);
round_value(Value, _) ->
    Value.

%%
%%
clamp_to_target(
    Value,
    #{
        '_outTo' := OutTo,
        '_outFrom' := OutFrom
    } = _NodeDef
) when
    OutFrom < OutTo, Value > OutTo;
    OutFrom > OutTo, Value < OutTo
->
    OutTo;
clamp_to_target(
    Value,
    #{
        '_outTo' := OutTo,
        '_outFrom' := OutFrom
    } = _NodeDef
) when
    OutFrom < OutTo, Value < OutFrom;
    OutFrom > OutTo, Value > OutFrom
->
    OutFrom;
clamp_to_target(Value, _) ->
    Value.

%%
%%
roll_around(
    Value,
    #{
        '_inTo' := InTo,
        '_inFrom' := InFrom
    } = _NodeDef
) ->
    Divisor = InTo - InFrom,
    math:fmod(math:fmod(Value - InFrom, Divisor) + Divisor, Divisor) + InFrom.
