-module(ered_node_i2c_out).

-include("ered_nodes.hrl").
-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%% Very simple I2C bus output node and one designed specifically for the
%% scrollPhat board.
%%
%% {
%%     "id": "4f324856fd1d8f40",
%%     "type": "i2c out",
%%     "z": "ea246f68766c8632",
%%     "name": "pixel",
%%     "busno": "1", <<<---- "/dev/i2c-1"
%%     "address": "96",
%%     "command": "1", <<---- first byte for the scrollPhat.
%%     "payload": "payload",
%%     "payloadType": "msg",
%%     "count": "12",
%%     "x": 778,
%%     "y": 263.5,
%%     "wires": [
%%         []
%%     ]
%% }
%%

-import(ered_nodes, [
    check_node_config/3,
    jstr/2,
    send_msg_to_connected_nodes/2
]).

-import(ered_nodered_comm, [
    node_status/5,
    post_exception_or_debug/3,
    send_out_debug_msg/4,
    unsupported/3
]).

-import(ered_messages, [
    convert_to_num/1,
    create_outgoing_msg/1
]).

start(
    #{
        <<"payloadType">> := <<"msg">>,
        <<"busno">> := BusNo,
        <<"address">> := Address,
        <<"command">> := Command,
        <<"count">> := Count
    } = NodeDef,
    WsName
) ->
    case
        'Elixir.Circuits.I2C':open(
            list_to_binary(io_lib:format("i2c-~s", [BusNo]))
        )
    of
        {ok, Ref} ->
            ered_node:start(
                NodeDef#{
                    '_device' => Ref,
                    '_cmdbyte' => convert_to_num(Command),
                    '_address' => convert_to_num(Address),
                    '_bytecount' => convert_to_num(Count)
                },
                ?MODULE
            );
        {error, Msg} ->
            post_exception_or_debug(NodeDef, #{?SetWsName}, Msg),
            ered_node:start(NodeDef, ered_node_ignore)
    end;
start(NodeDef, WsName) ->
    unsupported(NodeDef, {websocket, WsName}, "payload type"),
    ered_node:start(NodeDef, ered_node_ignore).

%%
%%
handle_event(_, NodeDef) ->
    NodeDef.

handle_msg(
    {incoming,
        #{
            ?GetPayload,
            <<"command">> := MsgCmdByte
        } = Msg},
    #{
        '_device' := Ref,
        '_cmdbyte' := _CmdByte,
        '_address' := Addr
    } = NodeDef
) when is_integer(MsgCmdByte) ->
    write_payload(Ref, Addr, MsgCmdByte, Payload),
    {handled, NodeDef, Msg};
handle_msg(
    {incoming, #{?GetPayload} = Msg},
    #{
        '_device' := Ref,
        '_cmdbyte' := CmdByte,
        '_address' := Addr
    } = NodeDef
) ->
    write_payload(Ref, Addr, CmdByte, Payload),
    {handled, NodeDef, Msg};
handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.

%%
%%
write_payload(Ref, Addr, CmdByte, Payload) when is_integer(Payload) ->
    'Elixir.Circuits.I2C':write(Ref, Addr, [CmdByte] ++ [Payload]);
write_payload(Ref, Addr, CmdByte, Payload) when is_list(Payload) ->
    'Elixir.Circuits.I2C':write(Ref, Addr, [CmdByte] ++ Payload).
