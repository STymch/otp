%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2017. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%
-module(logger_h_common).

-include("logger_h_common.hrl").
-include("logger_internal.hrl").

-export([log_to_binary/2,
         check_common_config/1,
         call_cast_or_drop/2,
         check_load/1,
         limit_burst/1,
         kill_if_choked/4,
         flush_log_requests/0,
         flush_log_requests/1,
         handler_exit/2,
         cancel_timer/1,
         stop_or_restart/3,
         overload_levels_ok/1,
         error_notify/1,
         info_notify/1]).

%%%-----------------------------------------------------------------
%%% Covert log data on any form to binary
-spec log_to_binary(Log,Config) -> LogString when
      Log :: logger:log(),
      Config :: logger:config(),
      LogString :: binary().
log_to_binary(#{msg:={report,_},meta:=#{report_cb:=_}}=Log,Config) ->
    do_log_to_binary(Log,Config);
log_to_binary(#{msg:={report,_},meta:=Meta}=Log,Config) ->
    DefaultReportCb = fun logger:format_otp_report/1,
    do_log_to_binary(Log#{meta=>Meta#{report_cb=>DefaultReportCb}},Config);
log_to_binary(Log,Config) ->
    do_log_to_binary(Log,Config).

do_log_to_binary(Log,Config) ->
    {Formatter,FormatterConfig} = maps:get(formatter,Config),
    String = try_format(Log,Formatter,FormatterConfig),
    try unicode:characters_to_binary(String)
    catch _:_ ->
            ?LOG_INTERNAL(debug,[{formatter_error,Formatter},
                                 {config,FormatterConfig},
                                 {log,Log},
                                 {bad_return_value,String}]),
            <<"FORMATTER ERROR: bad_return_value">>
    end.

try_format(Log,Formatter,FormatterConfig) ->
    try Formatter:format(Log,FormatterConfig)
    catch
        C:R:S ->
            ?LOG_INTERNAL(debug,[{formatter_crashed,Formatter},
                                 {config,FormatterConfig},
                                 {log,Log},
                                 {reason,
                                  {C,R,logger:filter_stacktrace(?MODULE,S)}}]),
            case {?DEFAULT_FORMATTER,?DEFAULT_FORMAT_CONFIG} of
                {Formatter,FormatterConfig} ->
                    "DEFAULT FORMATTER CRASHED";
                {DefaultFormatter,DefaultConfig} ->
                    try_format(Log#{msg=>{"FORMATTER CRASH: ~tp",
                                          [maps:get(msg,Log)]}},
                              DefaultFormatter,DefaultConfig)
            end
    end.

%%%-----------------------------------------------------------------
%%% Check that the configuration term is valid
check_common_config({toggle_sync_qlen,N}) when is_integer(N) ->
    valid;
check_common_config({drop_new_reqs_qlen,N}) when is_integer(N) ->
    valid;
check_common_config({flush_reqs_qlen,N}) when is_integer(N) ->
    valid;
check_common_config({enable_burst_limit,Bool}) when Bool == true;
                                                    Bool == false ->
    valid;
check_common_config({burst_limit_size,N}) when is_integer(N) ->
    valid;
check_common_config({burst_window_time,N}) when is_integer(N) ->
    valid;
check_common_config({enable_kill_overloaded,Bool}) when Bool == true;
                                                        Bool == false ->
    valid;
check_common_config({handler_overloaded_qlen,N}) when is_integer(N) ->
    valid;
check_common_config({handler_overloaded_mem,N}) when is_integer(N) ->
    valid;
check_common_config({handler_restart_after,NorA})  when is_integer(NorA);
                                                        NorA == never ->
    valid;
check_common_config({filesync_repeat_interval,NorA}) when is_integer(NorA);
                                                          NorA == no_repeat ->
    valid;
check_common_config(_) ->
    invalid.


%%%-----------------------------------------------------------------
%%% Overload Protection
call_cast_or_drop(Name, Bin) ->
    %% If the handler process is getting overloaded, the log request
    %% will be synchronous instead of asynchronous (slows down the
    %% logging tempo of a process doing lots of logging. If the
    %% handler is choked, drop mode is set and no request will be sent.
    try ?get_mode(Name) of
        async ->
            gen_server:cast(Name, {log,Bin});
        sync ->
            try gen_server:call(Name, {log,Bin}, ?DEFAULT_CALL_TIMEOUT) of
                %% if return value from call == dropped, the
                %% message has been flushed by handler and should
                %% therefore not be counted as dropped in stats
                ok      -> ok;
                dropped -> ok
            catch
                _:{timeout,_} ->
                    ?observe(Name,{dropped,1})
            end;
        drop -> ?observe(Name,{dropped,1})
    catch
        %% if the ETS table doesn't exist (maybe because of a
        %% handler restart), we can only drop the request
        _:_ -> ?observe(Name,{dropped,1})
    end,
    ok.

handler_exit(_Name, Reason) ->
    exit(Reason).

check_load(State = #{id:=Name, mode := Mode,
                     toggle_sync_qlen := ToggleSyncQLen,
                     drop_new_reqs_qlen := DropNewQLen,
                     flush_reqs_qlen := FlushQLen}) ->
    {_,Mem} = process_info(self(), memory),
    ?observe(Name,{max_mem,Mem}),
    %% make sure the handler process doesn't get scheduled
    %% out between the message_queue_len check below and the
    %% action that follows (flush or write).
    {_,QLen} = process_info(self(), message_queue_len),
    ?observe(Name,{max_qlen,QLen}),

    {Mode1,_NewDrops,_NewFlushes} =
        if
            QLen >= FlushQLen ->
                {flush, 0,1};
            QLen >= DropNewQLen ->
                %% Note that drop mode will force log requests to
                %% be dropped on the client side (never sent get to
                %% the handler).
                IncDrops = if Mode == drop -> 0; true -> 1 end,
                {?change_mode(Name, Mode, drop), IncDrops,0};
            QLen >= ToggleSyncQLen ->
                {?change_mode(Name, Mode, sync), 0,0};
            true ->
                {?change_mode(Name, Mode, async), 0,0}
        end,
    State1 = ?update_other(drops,DROPS,_NewDrops,State),
    {Mode1, QLen, Mem,
     ?update_other(flushes,FLUSHES,_NewFlushes,
                   State1#{last_qlen => QLen})}.

limit_burst(#{enable_burst_limit := false}) ->
     {true,0,0};
limit_burst(#{burst_win_ts := BurstWinT0,
              burst_msg_count := BurstMsgCount,
              burst_window_time := BurstWinTime,
              burst_limit_size := BurstLimitSz}) ->
    if (BurstMsgCount >= BurstLimitSz) -> 
            %% the limit for allowed messages has been reached
            BurstWinT1 = ?timestamp(),
            case ?diff_time(BurstWinT1,BurstWinT0) of
                BurstCheckTime when BurstCheckTime < (BurstWinTime*1000) ->
                    %% we're still within the burst time frame
                    {false,BurstWinT0,BurstMsgCount};
                _BurstCheckTime ->
                    %% burst time frame passed, reset counters
                    {true,BurstWinT1,0}
            end;
       true ->
            %% the limit for allowed messages not yet reached
            {true,BurstWinT0,BurstMsgCount+1}
    end.

kill_if_choked(Name, QLen, Mem,
               #{enable_kill_overloaded := KillIfOL,
                 handler_overloaded_qlen := HOLQLen,
                 handler_overloaded_mem := HOLMem}) ->
    if KillIfOL andalso
       ((QLen > HOLQLen) orelse (Mem > HOLMem)) ->            
            handler_exit(Name, {shutdown,{overloaded,Name,QLen,Mem}});
       true ->
            ok
    end.

flush_log_requests() ->
    flush_log_requests(-1).

flush_log_requests(Limit) ->
    process_flag(priority, high),
    Flushed = flush_log_requests(0, Limit),
    process_flag(priority, normal),
    Flushed.

flush_log_requests(Limit, Limit) ->
    Limit;
flush_log_requests(N, Limit) ->
    %% flush log requests but leave other requests, such as
    %% file/disk_log_sync, info and change_config, so that these
    %% have a chance to be processed even under heavy load
    receive
        {'$gen_cast',{log,_}} ->
            flush_log_requests(N+1, Limit);
        {'$gen_call',{Pid,MRef},{log,_}} ->
            Pid ! {MRef, dropped},
            flush_log_requests(N+1, Limit)
    after
        0 -> N
    end.

cancel_timer(TRef) when is_atom(TRef) -> ok;
cancel_timer(TRef) -> timer:cancel(TRef).


stop_or_restart(Name, {shutdown,Reason={overloaded,_Name,_QLen,_Mem}},
                #{handler_restart_after := RestartAfter}) ->
    %% If we're terminating because of an overload situation (see
    %% logger_h_common:kill_if_choked/4), we need to remove the handler
    %% and set a restart timer. A separate process must perform this
    %% in order to avoid deadlock.
    HandlerPid = self(),
    RemoveAndRestart =
        fun() ->
                MRef = erlang:monitor(process, HandlerPid),
                receive
                    {'DOWN',MRef,_,_,_} ->
                        ok
                after 30000 ->
                        error_notify(Reason),
                        exit(HandlerPid, kill)
                end,
                case logger:get_handler_config(Name) of
                    {ok,{HMod,HConfig}} when is_integer(RestartAfter) ->
                        _ = logger:remove_handler(Name),
                        _ = timer:apply_after(RestartAfter, logger, add_handler,
                                              [Name,HMod,HConfig]);
                    {ok,_} ->
                        _ = logger:remove_handler(Name);
                    {error,CfgReason} when is_integer(RestartAfter) ->
                        error_notify({Name,restart_impossible,CfgReason});
                    {error,_} ->
                        ok
                end
        end,
    spawn(RemoveAndRestart),
    ok;

stop_or_restart(Name, shutdown, _State) ->
    %% Probably terminated by supervisor. Remove the handler to avoid
    %% error printouts due to failing handler.
    _ = case logger:get_handler_config(Name) of
            {ok,_} ->
                %% Spawning to avoid deadlock
                spawn(logger,remove_handler,[Name]);
            _ ->
                ok
        end,
    ok;

stop_or_restart(_Name, _Reason, _State) ->
    ok.

overload_levels_ok(HandlerConfig) ->
    TSQL = maps:get(toggle_sync_qlen, HandlerConfig, ?TOGGLE_SYNC_QLEN),
    DNRQL = maps:get(drop_new_reqs_qlen, HandlerConfig, ?DROP_NEW_REQS_QLEN),
    FRQL = maps:get(flush_reqs_qlen, HandlerConfig, ?FLUSH_REQS_QLEN),
    (TSQL < DNRQL) andalso (DNRQL < FRQL).

error_notify(Term) ->
    ?internal_log(error, Term).

info_notify(Term) ->
    ?internal_log(info, Term).
