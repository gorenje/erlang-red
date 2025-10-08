-module(ered_io_debug_device).

-export([start/2, init/2, loop/1]).

-import(ered_nodered_comm, [
    send_out_debug_msg/4
]).

-import(ered_messages, [
    any_to_binary/1
]).

-record(state, {
    wsname,
    nodedef
}).

start(NodeDef, Wsname) ->
    spawn(?MODULE, init, [NodeDef, Wsname]).

init(NodeDef, Wsname) ->
    ?MODULE:loop(#state{wsname = Wsname, nodedef = NodeDef}).

loop(#state{wsname = Wsname, nodedef = NodeDef} = State) ->
    receive
        %% I/O Protocol messages
        {io_request, From, ReplyAs,
            {put_chars, _Encoding, Module, Function, Args}} ->
            From ! {io_reply, ReplyAs, ok},
            Content = any_to_binary(apply(Module, Function, Args)),
            send_out_debug_msg(NodeDef, #{'_ws' => Wsname}, Content, normal),
            ?MODULE:loop(State);
        {io_request, From, ReplyAs, {put_chars, _Encoding, Content}} ->
            From ! {io_reply, ReplyAs, ok},
            send_out_debug_msg(NodeDef, #{'_ws' => Wsname}, Content, normal),
            ?MODULE:loop(State);
        %% Private message
        stop ->
            done;
        _Unknown ->
            ?MODULE:loop(State)
    end.
