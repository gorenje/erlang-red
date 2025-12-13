-module(websocket_event_exchange_test).

-include_lib("eunit/include/eunit.hrl").

ensure_unsubscribe_is_working_test() ->
    ered_ws_event_exchange:start_link(),
    ered_ws_event_exchange:clear(),

    ered_ws_event_exchange:subscribe(wsname, nodeid, status, cb1234),

    ?assertEqual(
        #{status => #{wsname => #{nodeid => [cb1234]}}, debug => #{}},
        ered_ws_event_exchange:getstore()
    ),

    %%
    %% first subscribe to status updates.
    ered_ws_event_exchange:subscribe(wsname, anothernodeid, status, cb1234),
    ?assertEqual(
        #{
            status =>
                #{
                    wsname =>
                        #{nodeid => [cb1234], anothernodeid => [cb1234]}
                },
            debug => #{}
        },
        ered_ws_event_exchange:getstore()
    ),

    ered_ws_event_exchange:subscribe(anotherwsname, nodeid, status, cb1234),
    ?assertEqual(
        #{
            status =>
                #{
                    wsname =>
                        #{nodeid => [cb1234], anothernodeid => [cb1234]},
                    anotherwsname => #{nodeid => [cb1234]}
                },
            debug => #{}
        },
        ered_ws_event_exchange:getstore()
    ),

    ered_ws_event_exchange:subscribe(anotherwsname, nodeid, status, cb4321),
    ?assertEqual(
        #{
            status =>
                #{
                    wsname =>
                        #{nodeid => [cb1234], anothernodeid => [cb1234]},
                    anotherwsname => #{nodeid => [cb4321, cb1234]}
                },
            debug => #{}
        },
        ered_ws_event_exchange:getstore()
    ),

    ered_ws_event_exchange:subscribe(wsname, nodeid, status, cb4321),
    ?assertEqual(
        #{
            status =>
                #{
                    wsname =>
                        #{
                            nodeid => [cb4321, cb1234],
                            anothernodeid => [cb1234]
                        },
                    anotherwsname => #{nodeid => [cb4321, cb1234]}
                },
            debug => #{}
        },
        ered_ws_event_exchange:getstore()
    ),

    ered_ws_event_exchange:subscribe(wsname, nodeid, debug, normal, cb1234),
    ered_ws_event_exchange:subscribe(wsname, nodeid, debug, warning, cb1234),
    ered_ws_event_exchange:subscribe(
        wsname,
        anothernodeid,
        debug,
        warning,
        cb1234
    ),
    ered_ws_event_exchange:subscribe(
        anotherwsname,
        anothernodeid,
        debug,
        warning,
        cb1234
    ),

    ered_ws_event_exchange:subscribe(wsname, nodeid, debug, normal, cb4321),
    ered_ws_event_exchange:subscribe(wsname, nodeid, debug, normal, cb4321),
    ered_ws_event_exchange:subscribe(wsname, nodeid, debug, warning, cd4321),
    ered_ws_event_exchange:subscribe(wsname, nodeid, debug, warning, cd4321),
    ered_ws_event_exchange:subscribe(
        wsname,
        anothernodeid,
        debug,
        warning,
        cd4321
    ),
    ered_ws_event_exchange:subscribe(
        anotherwsname,
        anothernodeid,
        debug,
        warning,
        cd4321
    ),

    ?assertEqual(
        #{
            status =>
                #{
                    wsname =>
                        #{
                            nodeid => [cb4321, cb1234],
                            anothernodeid => [cb1234]
                        },
                    anotherwsname => #{nodeid => [cb4321, cb1234]}
                },
            debug =>
                #{
                    wsname =>
                        #{
                            nodeid =>
                                [
                                    {warning, cd4321},
                                    {normal, cb4321},
                                    {warning, cb1234},
                                    {normal, cb1234}
                                ],
                            anothernodeid =>
                                [{warning, cd4321}, {warning, cb1234}]
                        },
                    anotherwsname =>
                        #{
                            anothernodeid =>
                                [{warning, cd4321}, {warning, cb1234}]
                        }
                }
        },
        ered_ws_event_exchange:getstore()
    ),

    ered_ws_event_exchange:unsubscribe(missingwsname, cd4321),

    ?assertEqual(
        #{
            status =>
                #{
                    wsname =>
                        #{
                            nodeid => [cb4321, cb1234],
                            anothernodeid => [cb1234]
                        },
                    anotherwsname => #{nodeid => [cb4321, cb1234]}
                },
            debug =>
                #{
                    wsname =>
                        #{
                            nodeid =>
                                [
                                    {warning, cd4321},
                                    {normal, cb4321},
                                    {warning, cb1234},
                                    {normal, cb1234}
                                ],
                            anothernodeid =>
                                [{warning, cd4321}, {warning, cb1234}]
                        },
                    anotherwsname =>
                        #{
                            anothernodeid =>
                                [{warning, cd4321}, {warning, cb1234}]
                        }
                }
        },
        ered_ws_event_exchange:getstore()
    ),

    ered_ws_event_exchange:unsubscribe(wsname, cd4321),
    ?assertEqual(
        #{
            status =>
                #{
                    wsname =>
                        #{
                            nodeid => [cb4321, cb1234],
                            anothernodeid => [cb1234]
                        },
                    anotherwsname => #{nodeid => [cb4321, cb1234]}
                },
            debug =>
                #{
                    wsname =>
                        #{
                            nodeid => [
                                {normal, cb4321},
                                {warning, cb1234},
                                {normal, cb1234}
                            ],
                            anothernodeid => [{warning, cb1234}]
                        },
                    anotherwsname =>
                        #{
                            anothernodeid =>
                                [{warning, cd4321}, {warning, cb1234}]
                        }
                }
        },
        ered_ws_event_exchange:getstore()
    ),

    ered_ws_event_exchange:unsubscribe(wsname, not_existent_cb),
    ?assertEqual(
        #{
            status =>
                #{
                    wsname =>
                        #{
                            nodeid => [cb4321, cb1234],
                            anothernodeid => [cb1234]
                        },
                    anotherwsname => #{nodeid => [cb4321, cb1234]}
                },
            debug =>
                #{
                    wsname =>
                        #{
                            nodeid => [
                                {normal, cb4321},
                                {warning, cb1234},
                                {normal, cb1234}
                            ],
                            anothernodeid => [{warning, cb1234}]
                        },
                    anotherwsname =>
                        #{
                            anothernodeid =>
                                [{warning, cd4321}, {warning, cb1234}]
                        }
                }
        },
        ered_ws_event_exchange:getstore()
    ),

    ered_ws_event_exchange:unsubscribe(wsname, cb4321),
    ?assertEqual(
        #{
            status =>
                #{
                    wsname =>
                        #{nodeid => [cb1234], anothernodeid => [cb1234]},
                    anotherwsname => #{nodeid => [cb4321, cb1234]}
                },
            debug =>
                #{
                    wsname =>
                        #{
                            nodeid => [{warning, cb1234}, {normal, cb1234}],
                            anothernodeid => [{warning, cb1234}]
                        },
                    anotherwsname =>
                        #{
                            anothernodeid =>
                                [{warning, cd4321}, {warning, cb1234}]
                        }
                }
        },
        ered_ws_event_exchange:getstore()
    ),

    %% repeated calls make no change
    ered_ws_event_exchange:unsubscribe(wsname, cb4321),
    ?assertEqual(
        #{
            status =>
                #{
                    wsname =>
                        #{nodeid => [cb1234], anothernodeid => [cb1234]},
                    anotherwsname => #{nodeid => [cb4321, cb1234]}
                },
            debug =>
                #{
                    wsname =>
                        #{
                            nodeid => [{warning, cb1234}, {normal, cb1234}],
                            anothernodeid => [{warning, cb1234}]
                        },
                    anotherwsname =>
                        #{
                            anothernodeid =>
                                [{warning, cd4321}, {warning, cb1234}]
                        }
                }
        },
        ered_ws_event_exchange:getstore()
    ),

    ered_ws_event_exchange:unsubscribe(wsname, cb1234),
    ?assertEqual(
        #{
            status =>
                #{
                    wsname => #{nodeid => [], anothernodeid => []},
                    anotherwsname => #{nodeid => [cb4321, cb1234]}
                },
            debug =>
                #{
                    wsname => #{nodeid => [], anothernodeid => []},
                    anotherwsname =>
                        #{
                            anothernodeid =>
                                [{warning, cd4321}, {warning, cb1234}]
                        }
                }
        },
        ered_ws_event_exchange:getstore()
    ),

    ered_ws_event_exchange:remove_ws(wsname),
    ?assertEqual(
        #{
            status => #{anotherwsname => #{nodeid => [cb4321, cb1234]}},
            debug =>
                #{
                    anotherwsname =>
                        #{
                            anothernodeid =>
                                [{warning, cd4321}, {warning, cb1234}]
                        }
                }
        },
        ered_ws_event_exchange:getstore()
    ),

    ered_ws_event_exchange:remove_ws(noneexisting),
    ?assertEqual(
        #{
            status => #{anotherwsname => #{nodeid => [cb4321, cb1234]}},
            debug =>
                #{
                    anotherwsname =>
                        #{
                            anothernodeid =>
                                [{warning, cd4321}, {warning, cb1234}]
                        }
                }
        },
        ered_ws_event_exchange:getstore()
    ),

    ered_ws_event_exchange:remove_ws(anotherwsname),
    ?assertEqual(
        #{status => #{}, debug => #{}},
        ered_ws_event_exchange:getstore()
    ),

    ered_ws_event_exchange:stop().
