-module(ered_node_trigger).

-include("ered_nodes.hrl").

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%% Trigger nodes generates messages in specific intervals.
%%
%%       "op1": "1",
%%       "op2": "0",
%%       "op1type": "str",
%%       "op2type": "str",
%%       "duration": "250",
%%       "extend": false,
%%       "overrideDelay": false,
%%       "units": "ms",  --> s, min, hr
%%       "reset": "",
%%       "bytopic": "all",
%%       "topic": "topic",
%%       "outputs": 1,  --> 1 or 2 --> second messages either goes out on 1 or 2
%%

-import(ered_messages, [
    convert_to_num/1,
    create_outgoing_msg/1,
    convert_units_to_milliseconds/2
]).
-import(ered_nodes, [
    jstr/2,
    send_msg_on/2
]).
-import(ered_nodered_comm, [
    node_status/5,
    node_status_clear/2,
    unsupported/3
]).

start(NodeDef, _WsName) ->
    ered_node:start(NodeDef, ?MODULE).

%%
%%
handle_event({registered, WsName, Pid}, #{<<"extend">> := true} = NodeDef) ->
    ConversionResult = convert_units_to_milliseconds(
        maps:find(<<"units">>, NodeDef),
        maps:find(<<"duration">>, NodeDef)
    ),

    case ConversionResult of
        {ok, ExtendDelay} when ExtendDelay > 0 ->
            Fun = fun() ->
                gen_server:cast(Pid, create_outgoing_msg(WsName))
            end,
            {ok, TRef} = timer:apply_after(ExtendDelay, Fun),
            NodeDef#{'_extenddelay' => ExtendDelay, '_extendref' => TRef};
        {ok, _V} ->
            unsupported(NodeDef, {websocket, WsName}, "Zero or negative time"),
            NodeDef#{<<"extend">> := false};
        {error, ErrMsg} ->
            unsupported(NodeDef, {websocket, WsName}, ErrMsg),
            NodeDef#{<<"extend">> := false}
    end;
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
handle_msg(
    {incoming, #{?GetWsName} = _Msg},
    #{
        <<"extend">> := true,
        '_extenddelay' := ExtendDelay,
        '_extendref' := TRef
    } = NodeDef
) ->
    timer:cancel(TRef),
    ThisPid = self(),
    Fun = fun() ->
        gen_server:cast(ThisPid, create_outgoing_msg(WsName))
    end,
    {ok, NewTRef} = timer:apply_after(ExtendDelay, Fun),
    {handled, NodeDef#{'_extendref' => NewTRef}, dont_send_complete_msg};
handle_msg(
    {incoming, #{?GetWsName} = Msg},
    #{<<"wires">> := Wires, <<"outputs">> := Outputs} = NodeDef
) ->
    case
        opx_to_payload(
            maps:find(<<"op1">>, NodeDef),
            maps:find(<<"op1type">>, NodeDef)
        )
    of
        {dontsend, _} ->
            node_status(WsName, NodeDef, "", "blue", "dot"),
            Delay = compute_delay(NodeDef, Msg),
            ThisPid = self(),
            Fun = fun() -> gen_server:cast(ThisPid, {outgoing, Msg}) end,
            timer:apply_after(Delay, Fun),
            {handled, NodeDef, Msg};
        {ok, Value} ->
            Msg2 = Msg#{?AddPayload(Value)},
            node_status(WsName, NodeDef, "", "blue", "dot"),
            send_msg_based_on_output_count(
                Msg2, Wires, send_first_msg, Outputs
            ),
            Delay = compute_delay(NodeDef, Msg2),
            ThisPid = self(),
            Fun = fun() -> gen_server:cast(ThisPid, {outgoing, Msg2}) end,
            timer:apply_after(Delay, Fun),
            {handled, NodeDef, Msg2};
        {error, ErrMsg} ->
            unsupported(NodeDef, Msg, ErrMsg),
            {handled, NodeDef, Msg}
    end;
%%
%% outgoing triggers the second message
handle_msg(
    {outgoing, #{?GetWsName} = Msg},
    #{<<"wires">> := Wires, <<"outputs">> := Outputs} = NodeDef
) ->
    node_status_clear(WsName, NodeDef),
    case
        opx_to_payload(
            maps:find(<<"op2">>, NodeDef),
            maps:find(<<"op2type">>, NodeDef)
        )
    of
        {dontsend, _} ->
            {handled, NodeDef, Msg};
        {ok, Value} ->
            Msg2 = Msg#{?AddPayload(Value)},
            send_msg_based_on_output_count(
                Msg2, Wires, send_second_msg, Outputs
            ),
            {handled, NodeDef, Msg2};
        {error, ErrMsg} ->
            unsupported(NodeDef, Msg, ErrMsg),
            {handled, NodeDef, Msg}
    end;
%%
%% Most import to define this, else this node will crash with any
%% unrecognised message.
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%% ------------------ Helpers
%%
compute_delay(NodeDef, Msg, {ok, true}) ->
    case maps:find(<<"delay">>, Msg) of
        {ok, Delay} ->
            %% msg.delay is assumed to be milliseconds --> RTFM.
            convert_to_num(Delay);
        _ ->
            compute_delay(NodeDef, Msg, {ok, false})
    end;
compute_delay(NodeDef, Msg, {ok, false}) ->
    ConversionResult = convert_units_to_milliseconds(
        maps:find(<<"units">>, NodeDef),
        maps:find(<<"duration">>, NodeDef)
    ),
    case ConversionResult of
        {ok, V} ->
            V;
        {error, ErrMsg} ->
            unsupported(NodeDef, Msg, ErrMsg),
            0
    end.

compute_delay(NodeDef, Msg) ->
    compute_delay(NodeDef, Msg, maps:find(<<"overrideDelay">>, NodeDef)).

%%
%% payload value for opX
opx_to_payload({ok, V}, {ok, <<"str">>}) ->
    {ok, V};
opx_to_payload({ok, V}, {ok, <<"num">>}) ->
    {ok, convert_to_num(V)};
opx_to_payload({ok, _}, {ok, <<"nul">>}) ->
    {dontsend, ignore};
opx_to_payload(V, T) ->
    {error, jstr("WARNING: trigger unsupported type for ~p & ~p~n", [V, T])}.

%%
%% Because the trigger node can either have one to two ouptut ports, depending
%% on its configuration, we have to check which wires there are.
%% wires can be [ [ WiresOp1&Op2 ] ] or [ [WiresOp1], [WiresOp2] ]
%%
%% the last value is the outputs count
send_msg_based_on_output_count(Msg, [Wires], send_first_msg, 1) ->
    send_msg_on(Wires, Msg);
send_msg_based_on_output_count(Msg, [Wires | _], send_first_msg, 1) ->
    send_msg_on(Wires, Msg);
send_msg_based_on_output_count(Msg, [Wires], send_first_msg, 2) ->
    send_msg_on(Wires, Msg);
send_msg_based_on_output_count(Msg, [Wires | _], send_first_msg, 2) ->
    send_msg_on(Wires, Msg);
%%
%%
send_msg_based_on_output_count(Msg, [Wires], send_second_msg, 1) ->
    send_msg_on(Wires, Msg);
send_msg_based_on_output_count(Msg, [_ | MoreWires], send_second_msg, 2) ->
    send_msg_on(MoreWires, Msg);
send_msg_based_on_output_count(Msg, [Wires | _], send_second_msg, 1) ->
    send_msg_on(Wires, Msg).
