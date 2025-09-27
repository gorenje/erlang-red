-module(erlang_red_sup).

-behaviour(supervisor).
-export([init/1, start_link/0]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok,
        {
            {one_for_one, 1000, 3600},
            [
                #{
                    id => ered_ch1_pg_kernel,
                    start => {pg, start_link, []},
                    restart => permanent,
                    type => supervisor,
                    module => [pg]
                },
                #{
                    id => ered_ch2_flow_store,
                    start => {ered_flow_store_server, start, []},
                    restart => permanent,
                    type => worker,
                    module => [ered_flow_store_server]
                },
                #{
                    id => ered_ch3_ws_event_exchange,
                    start => {ered_ws_event_exchange, start, []},
                    restart => permanent,
                    type => worker,
                    module => [ered_ws_event_exchange]
                },
                #{
                    id => ered_ch4_error_store,
                    start => {ered_error_store, start_link, []},
                    restart => permanent,
                    type => worker,
                    module => [ered_error_store]
                },
                #{
                    id => ered_ch5_unittest_engine,
                    start => {ered_unittest_engine, start, []},
                    restart => permanent,
                    type => worker,
                    module => [ered_unittest_engine]
                },
                #{
                    id => ered_ch6_config_store,
                    start => {ered_config_store, start, []},
                    restart => permanent,
                    type => worker,
                    module => [ered_config_store]
                },
                #{
                    id => ered_ch9_csv_parser_store,
                    start => {ered_csv_parser_store, start, []},
                    restart => permanent,
                    type => worker,
                    module => [ered_csv_parser_store]
                },
                #{
                    id => ered_ch7_compute_engine,
                    start => {ered_compute_engine, start_link, []},
                    restart => permanent,
                    type => worker,
                    module => [ered_compute_engine]
                },
                #{
                    id => ered_ch8_msg_tracer,
                    start => {ered_msgtracer_manager, start_link, []},
                    restart => permanent,
                    type => worker,
                    module => [ered_msgtracer_manager]
                },
                #{
                    id => ered_ch9_erlmodule_exchange,
                    start => {ered_erlmodule_exchange, start_link, []},
                    restart => permanent,
                    type => worker,
                    module => [ered_erlmodule_exchange]
                },
                #{
                    id => ered_ch10_tcp_manager,
                    start => {ered_tcp_manager, start_link, []},
                    restart => permanent,
                    type => worker,
                    module => [ered_tcp_manager]
                },
                #{
                    id => ered_ch11_runtime_manager,
                    start => {ered_runtime_manager, start_link, []},
                    restart => permanent,
                    type => worker,
                    module => [ered_runtime_manager]
                },
                #{
                    id => ered_ch12_red_web,
                    start => {ered_webserver, start, []},
                    restart => permanent,
                    type => worker,
                    module => [ered_webserver]
                }
            ]
        }}.
