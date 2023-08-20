pmclock
=======

This repository implements some functions from the pmclock as described in [G.7710 : Common equipment management function requirements](https://www.itu.int/rec/T-REC-G.7710-202010-I/en).

![pmclock functions](/pmclock_function.png)

How it works is described below, but the src/pmclock_statem.erl just implements the itens 3 and 4.

![pmclock functions](/pmclock_process.png)

The pmclock_statem was design to receive registration from any process and sends pmclocks for 15-min and/or 24-hour to all registered process.

A gen_statem has chosen for the implementation because it manages timeouts using [generic time-outs](https://www.erlang.org/doc/design_principles/statem#generic-time-outs) which is very handy. Rather than using [erlang:send_after/4](https://www.erlang.org/doc/man/erlang#send_after-4).

Build
-----

    $ rebar3 compile

Run
---

```
erl +c true +C multi_time_warp -pa _build/default/lib/pmclock/ebin/
1> pmclock_statem:start().

=NOTICE REPORT==== 19-Aug-2023::22:52:45.779958 ===
    info: #{time_correction => true,time_warp_mode => multi_time_warp,
            os_system_time_source =>
                [{function,clock_gettime},
                 {clock_id,'CLOCK_REALTIME'},
                 {resolution,1000000000},
                 {parallel,yes},
                 {time,1692485565779934398}],
            os_monotonic_time_source =>
                [{function,clock_gettime},
                 {clock_id,'CLOCK_MONOTONIC'},
                 {resolution,1000000000},
                 {extended,no},
                 {parallel,yes},
                 {time,2466151075548}]}
    msg: periods
    '15m': {{timeout,'15m'},
            -576460315844,
            {pmclock,-576460315844,#{period => '15m',period_t => 900}},
            [{abs,true}]}
    '24h': {{timeout,'24h'},
            -576456716623,
            {pmclock,-576456716623,#{period => '24h',period_t => 86400}},
            [{abs,true}]}
    start_period_15m: -576460315844
    start_period_24h: -576456716623
{ok,<0.88.0>}
```

References
----------

* [Periodic sending a message based on clock wall time](https://erlangforums.com/t/periodic-sending-a-message-based-on-clock-wall-time/2800)