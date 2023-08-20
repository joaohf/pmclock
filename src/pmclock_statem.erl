%% @doc This module implements some of the requirements for
%% Performance Monitoring Clock function as described in G.7710.
%%
%% Mainly the pmclock for each 15 minutes and 24 hour.
%% 
%% References:
%% <ul>
%%   <li>https://www.itu.int/rec/T-REC-G.7710-202010-I/en</li>
%%   <li>https://www.erlang.org/doc/apps/erts/time_correction</li>
%%   <li>https://learnyousomeerlang.com/time</li>
%%   <li>https://erlangforums.com/t/periodic-sending-a-message-based-on-clock-wall-time/2800</li>
%%   <li>https://www.erlang.org/doc/design_principles/statem#generic-time-outs</li>
%% </ul>
%% @end
-module(pmclock_statem).

-behavior(gen_statem).

% API
-export([
    start/0,
    start/1,
    stop/1,
    start_link/1,
    register_monitors/2,
    unregister_monitors/1
]).

% Callbacks
-export([init/1, callback_mode/0]).
-export([pmclock/3]).

-record(state, {
    clock_service_ref :: reference(),
    monitors :: map(),
    period_15m :: non_neg_integer(),
    period_24h :: non_neg_integer()
}).

-type state() :: #state{}.

-include_lib("kernel/include/logger.hrl").

-type period() :: '15m' | '24h'.

% API

start() ->
    start(#{period_15min => 900, period_24hour => 86400}).

start_link(Args) ->
    gen_statem:start_link({local, ?MODULE}, ?MODULE, Args, []).

start(Args) ->
    gen_statem:start({local, ?MODULE}, ?MODULE, Args, []).

stop(Pid) ->
    gen_statem:stop(Pid).

register_monitors(Name, Monitors) ->
    gen_statem:cast(?MODULE, {register_monitor, Name, Monitors}).

unregister_monitors(Name) ->
    gen_statem:cast(?MODULE, {unregister_monitor, Name}).

% Callbacks

init(Map) ->
    logger:set_module_level(?MODULE, debug),
    Period15m = map_get(period_15min, Map),
    Period24h = map_get(period_24hour, Map),

    % Need to monitor clock_service to get time offset changes
    ClockMonitorRef = erlang:monitor(time_offset, clock_service),

    {_Ts, Datetime} = datetime(),

    EventContent15m = make_event_content('15m', Period15m),
    EventContent24h = make_event_content('24h', Period24h),

    AbsT15m = round_to_next_quarter(Datetime, Period15m),
    AbsT24h = first_timeout(24),

    Options = [{abs, true}],

    % Configure generic timeouts,
    %  to start at the next quarter hour:
    T15m = {{timeout, '15m'}, AbsT15m, {pmclock, AbsT15m, EventContent15m}, Options},
    %  to start at the next 24h period:
    T24h = {{timeout, '24h'}, AbsT24h, {pmclock, AbsT24h, EventContent24h}, Options},

    Info = #{
        time_correction => erlang:system_info(time_correction),
        time_warp_mode => erlang:system_info(time_warp_mode),
        os_system_time_source => erlang:system_info(os_system_time_source),
        os_monotonic_time_source => erlang:system_info(os_monotonic_time_source)
    },
    ?LOG_NOTICE(#{
        '15m' => T15m,
        '24h' => T24h,
        start_period_15m => AbsT15m,
        start_period_24h => AbsT24h,
        msg => "periods",
        info => Info
    }),

    Actions = [T15m, T24h],

    Data = #state{
        clock_service_ref = ClockMonitorRef,
        monitors = #{},
        period_15m = Period15m,
        period_24h = Period24h
    },
    {ok, pmclock, Data, Actions}.

callback_mode() ->
    state_functions.

pmclock(cast, {register_monitor, Name, MonMonitors}, #state{monitors = Monitors} = Data) ->
    NewMonitors = maps:put(Name, MonMonitors, Monitors),
    {keep_state, Data#state{monitors = NewMonitors}};
pmclock(cast, {unregister_monitor, Name}, #state{monitors = Monitors} = Data) ->
    NewMonitors = maps:remove(Name, Monitors),
    {keep_state, Data#state{monitors = NewMonitors}};
pmclock({timeout, '15m'}, EventContent, Data) ->
    {NewData, Actions} = do_pmclock(EventContent, Data),
    {keep_state, NewData, Actions};
pmclock({timeout, '24h'}, EventContent, Data) ->
    {NewData, Actions} = do_pmclock(EventContent, Data),
    {keep_state, NewData, Actions};
% Read it first: https://www.erlang.org/doc/apps/erts/time_correction#new-erlang-monotonic-time
pmclock(
    info,
    {'CHANGE', MonitorRef, time_offset, clock_service, NewTimeOffset},
    #state{clock_service_ref = MonitorRef} = Data
) ->
    {NewData, Actions} = do_time_offset(NewTimeOffset, Data),
    {keep_state, NewData, Actions}.

% Internal functions

do_time_offset(NewTimeOffset, Data) ->
    SystemTimeMs = erlang:system_time(millisecond),
    TimeOffsetMs = erlang:convert_time_unit(NewTimeOffset, native, millisecond),

    Period15m = Data#state.period_15m,
    Period24h = Data#state.period_24h,

    Period15mMs = timer:seconds(Period15m),
    Period24hMs = timer:seconds(Period24h),

    Timeout15m = next_timeout(SystemTimeMs, TimeOffsetMs, Period15mMs),
    Timeout24h = next_timeout(SystemTimeMs, TimeOffsetMs, Period24hMs),

    EventContent15m = make_event_content('15m', Period15m),
    EventContent24h = make_event_content('24h', Period24h),

    Options = [{abs, true}],
    T15m = {{timeout, '15m'}, Timeout15m, {pmclock, Timeout15m, EventContent15m}, Options},
    T24h = {{timeout, '24h'}, Timeout24h, {pmclock, Timeout24h, EventContent24h}, Options},

    ?LOG_DEBUG(#{
        new_offset => TimeOffsetMs,
        t15m => T15m,
        t24h => T24h,
        msg => "time offset has changed"
    }),

    {Data, [T15m, T24h]}.

do_pmclock({pmclock, PrevTimeout, #{period := Period, period_t := PeriodT}} = E, Data) ->
    Now = erlang:monotonic_time(millisecond),
    PeriodMs = timer:seconds(PeriodT),

    EndOfPeriod = add_timeout(PrevTimeout, PeriodMs),

    DeltaPeriod = EndOfPeriod - PrevTimeout,

    ?LOG_DEBUG(#{
        event => E,
        period => Period,
        period_t => PeriodT,
        next_end_of_period_abs => EndOfPeriod,
        delta_period => DeltaPeriod
    }),

    send_pmclock(Period, Now, Data),

    EventContent = make_event_content(Period, PeriodT),

    % Create next generic timeout
    Options = [{abs, true}],
    Actions = [
        {{timeout, Period}, EndOfPeriod, {pmclock, EndOfPeriod, EventContent}, Options}
    ],
    {Data, Actions}.

send_pmclock('15m', StartTime, #state{monitors = Monitors}) ->
    Fun = fun(_Name, Monitors0) ->
        PidRec15min = proplists:get_value(rec15min, Monitors0),
        PidCur15min = proplists:get_value(cur15min, Monitors0),
        perfmon_mon_cur15min:pmclock(PidCur15min, StartTime),
        perfmon_mon_rec15min:pmclock(PidRec15min, StartTime)
    end,
    maps:foreach(Fun, Monitors),

    ok;
send_pmclock('24h', StartTime, #state{monitors = Monitors}) ->
    Fun = fun(_Name, Monitors0) ->
        PidCur24hour = proplists:get_value(cur24hour, Monitors0),
        perfmon_mon_cur24hour:pmclock(PidCur24hour, StartTime)
    end,
    maps:foreach(Fun, Monitors),

    ok.

make_event_content(Period, PeriodT) ->
    #{period => Period, period_t => PeriodT}.

-spec datetime() -> {integer(), calendar:datetime()}.
datetime() ->
    Ts = erlang:system_time(millisecond),
    {Ts, calendar:system_time_to_universal_time(Ts, millisecond)}.

-spec round_to_next_quarter(calendar:datetime(), non_neg_integer()) -> non_neg_integer().
round_to_next_quarter(Datetime, Period) ->
    round_to_next_period('15m', Period, Datetime).

-spec round_to_next_period(period(), non_neg_integer(), calendar:datetime()) ->
    non_neg_integer().
round_to_next_period('15m', Period, {_, {_Hour, Minute, Second}}) ->
    SysTime = erlang:system_time(millisecond),
    TimeOffs = erlang:time_offset(millisecond),
    MSeconds = Minute * 60,
    TSeconds = MSeconds + Second,
    CurrentQuarterSeconds = erlang:round(math:ceil(TSeconds / Period) * Period),
    Ms = (CurrentQuarterSeconds - TSeconds) * 1000,
    SysTime + Ms - TimeOffs;
round_to_next_period('24h', Period, {_, Time}) ->
    T = calendar:time_to_seconds(Time),
    Period - T.

%% @doc Returns an absolute monotonic time in milliseconds for
%% the next period.
%%
%% @param SysTime Erlang system time in millisecond time unit
%% @param TimeOffs Erlang time offset in millisecond time unit
%% @param PeriodMs Number of milliseconds during a period
%%
%% @end
-spec next_timeout(SysTime, TimeOffs, PeriodMs) -> Timeout when
    SysTime :: integer(),
    TimeOffs :: integer(),
    PeriodMs :: non_neg_integer(),
    Timeout :: integer().
next_timeout(SysTime, TimeOffs, PeriodMs) ->
    (SysTime div PeriodMs + 1) * PeriodMs - TimeOffs.

add_timeout(Timeout, PeriodMs) ->
    Timeout + PeriodMs.

%% @doc Returns an absolute monotonic time in millisecond time unit
%% until the next HourNr.
%%
%% @param HourNr Number of the next hour to get timeout from
%%
%% @end
-spec first_timeout(HourNr) -> Timeout when
    HourNr :: 1..24,
    Timeout :: integer().
first_timeout(HourNr) ->
    SysTime = erlang:system_time(millisecond),
    TimeOffs = erlang:time_offset(millisecond),
    first_timeout(SysTime, TimeOffs, HourNr).

-spec first_timeout(SysTime, TimeOffs, HourNr) -> Timeout when
    SysTime :: integer(),
    TimeOffs :: integer(),
    HourNr :: 1..24,
    Timeout :: integer().
first_timeout(SysTime, TimeOffs, HourNr) ->
    DayMs = 24 * 60 * 60 * 1000,
    HourNrMs = HourNr * 60 * 60 * 1000,
    ((SysTime + DayMs - HourNrMs) div DayMs) * DayMs + HourNrMs - TimeOffs.