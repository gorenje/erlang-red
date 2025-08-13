-module(ered_node_template).

-behaviour(ered_node).

-export([start/2]).
-export([handle_msg/2]).
-export([handle_event/2]).

%%
%%
%% Attributes of importance:
%%
%%    "field": "payload",
%%    "fieldType": "msg",
%%    "format": "handlebars", <<---- ignored since this is for the frontend
%%    "syntax": "plain", <<---- (can be "mustache template")
%%    "output": "str",   <<---- (can be "parse the content as json")
%%    "template": "This is the payload: {{payload}} !",
%%

-import(ered_nodered_comm, [
    debug/3,
    debug_string/2,
    ws_from/1,
    unsupported/3
]).

-import(ered_nodes, [
    jstr/2,
    send_msg_to_connected_nodes/2,
    this_should_not_happen/2
]).

-import(ered_messages, [
    decode_json/1,
    set_prop_value/3,
    map_keys_to_lists/1
]).

doit(Prop, <<"msg">>, Template, <<"plain">>, <<"base64">>, Msg) ->
    {ok, set_prop_value(Prop, base64:decode(binary_to_list(Template)), Msg)};
doit(Prop, <<"msg">>, Template, <<"mustache">>, <<"base64">>, Msg) ->
    MustachedRendered = bbmustache:render(Template, map_keys_to_lists(Msg)),
    {ok,
        set_prop_value(
            Prop,
            base64:decode(binary_to_list(MustachedRendered)),
            Msg
        )};
doit(Prop, <<"msg">>, Template, <<"plain">>, <<"str">>, Msg) ->
    {ok, set_prop_value(Prop, Template, Msg)};
doit(Prop, <<"msg">>, Template, <<"mustache">>, <<"str">>, Msg) ->
    MustachedRendered = bbmustache:render(Template, map_keys_to_lists(Msg)),
    {ok, set_prop_value(Prop, MustachedRendered, Msg)};
doit(Prop, <<"msg">>, Template, <<"plain">>, <<"json">>, Msg) ->
    {ok, set_prop_value(Prop, decode_json(Template), Msg)};
doit(Prop, <<"msg">>, Template, <<"mustache">>, <<"json">>, Msg) ->
    MustachedRendered = bbmustache:render(Template, map_keys_to_lists(Msg)),
    {ok, set_prop_value(Prop, decode_json(MustachedRendered), Msg)};
doit(_, _, _, _, _, _) ->
    unsupported.

%%
%%
start(NodeDef, _WsName) ->
    ered_node:start(NodeDef, ?MODULE).

%%
%%
handle_event(_, NodeDef) ->
    NodeDef.

%%
%%
% erlfmt:ignore - alginment
handle_msg(
  {incoming, Msg},
  #{
    <<"field">>     := Prop,
    <<"fieldType">> := PropType,
    <<"syntax">>    := Syntax,
    <<"template">>  := Template,
    <<"output">>    := Output
   } = NodeDef
) ->
    {NewNodeDef, NewMsg} =
        case doit(Prop, PropType, Template, Syntax, Output, Msg) of
            {ok, Msg2} ->
                send_msg_to_connected_nodes(NodeDef, Msg2),
                {NodeDef, Msg2};
            unsupported ->
                ErrMsg = jstr("Unsupported configuration: ~p", [NodeDef]),
                unsupported(NodeDef, Msg, ErrMsg),

                %% Ok, we push the content into the msg object but warn as
                %% well. Not modifying the message and sending it on would
                %% be an error but not supporting formatting is kind of ...
                %% an error really but since I don't raise an error here, set
                %% the content in the msg.
                Msg2 = set_prop_value(Prop, Template, Msg),
                send_msg_to_connected_nodes(NodeDef, Msg2),
                {NodeDef, Msg2}
        end,
    {handled, NewNodeDef, NewMsg};

handle_msg(_, NodeDef) ->
    {unhandled, NodeDef}.
