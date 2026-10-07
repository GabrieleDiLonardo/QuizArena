-module(room_gen_server).
-behaviour(gen_server).

-export([start_link/2, join/3, rejoin/3, start_game/2, next_round/2,
         answer/4, cancel/2, end_game/2, get_state/1, get_events_since/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(POINTS_BASE, 1000).
-define(ROUND_TIME_LIMIT, 60000).
-define(MAX_EVENT_LOG, 200).

-record(player, {
    id,
    nickname,
    pid,
    score = 0,
    answered = false,
    answer_time,
    chosen_answer,
    connected = true,
    monitor_ref = undefined
}).

%% ---------- API pubblica ----------

start_link(Pin, HostPid) ->
    gen_server:start_link(?MODULE, [Pin, HostPid], []).

join(Pin, Nickname, PlayerPid) ->
    gen_server:call(via(Pin), {join, Nickname, PlayerPid}).

rejoin(Pin, PlayerId, NewPid) ->
    gen_server:call(via(Pin), {rejoin, PlayerId, NewPid}).

start_game(Pin, RequesterPid) ->
    gen_server:call(via(Pin), {start_game, RequesterPid}).

next_round(Pin, RequesterPid) ->
    gen_server:call(via(Pin), {next_round, RequesterPid}).

answer(Pin, PlayerId, Round, Answer) ->
    gen_server:call(via(Pin), {answer, PlayerId, Round, Answer}).

cancel(Pin, RequesterPid) ->
    gen_server:call(via(Pin), {cancel, RequesterPid}).

end_game(Pin, RequesterPid) ->
    gen_server:call(via(Pin), {end_game, RequesterPid}).

get_state(Pin) ->
    gen_server:call(via(Pin), get_state).

get_events_since(Pin, SinceSeq) ->
    gen_server:call(via(Pin), {get_events_since, SinceSeq}).

via(Pin) ->
    {via, global, {room, Pin}}.

%% ---------- Callback gen_server ----------

init([Pin, HostPid]) ->
    case global:register_name({room, Pin}, self()) of
        yes ->
            init_registered_room(Pin, HostPid);
        no ->
            {stop, {room_already_registered, Pin}}
    end.

init_registered_room(Pin, HostPid) ->
    Questions = load_session_questions(Pin),
    HostMonitorRef = erlang:monitor(process, HostPid),
    io:format("[room ~s] avviato (host=~p, ~p domande)~n",
              [Pin, HostPid, length(Questions)]),
    {ok, #{
        pin => Pin,
        host_pid => HostPid,
        host_monitor_ref => HostMonitorRef,
        quiz_questions => Questions,
        players => #{},
        status => waiting,
        current_round => 0,
        question => undefined,
        round_start_time => undefined,
        round_deadline => undefined,
        timer_ref => undefined,
        seq => 0,
        event_log => []
    }}.

handle_call({join, Nickname, PlayerPid}, _From, State)
  when is_list(Nickname), Nickname =/= [], is_pid(PlayerPid) ->
    case maps:get(status, State) of
        waiting ->
            Players = maps:get(players, State),
            PlayerId = erlang:unique_integer([positive]),
            MonitorRef = erlang:monitor(process, PlayerPid),
            Player = #player{id = PlayerId, nickname = Nickname,
                             pid = PlayerPid, connected = true,
                             monitor_ref = MonitorRef},
            NewPlayers = maps:put(PlayerId, Player, Players),
            State1 = State#{players => NewPlayers},
            NewState = emit_event(State1, #{
                type => player_joined,
                nickname => Nickname
            }),
            io:format("[room ~s] ~s joined (id=~p, pid=~p)~n",
                      [maps:get(pin, State), Nickname,
                       PlayerId, PlayerPid]),
            {reply, {ok, PlayerId}, NewState};
        Status ->
            {reply, {error, {invalid_state, Status}}, State}
    end;

handle_call({join, _Nickname, _PlayerPid}, _From, State) ->
    {reply, {error, invalid_request}, State};

handle_call({rejoin, PlayerId, NewPid}, _From, State) ->
    Players = maps:get(players, State),
    case maps:get(PlayerId, Players, undefined) of
        undefined ->
            {reply, {error, player_not_found}, State};
        Player ->
            %% Cancella il vecchio monitor (se esiste)
            case Player#player.monitor_ref of
                undefined -> ok;
                OldRef -> _ = erlang:demonitor(OldRef, [flush]), ok
            end,
            %% Crea nuovo monitor sul nuovo PID
            NewRef = erlang:monitor(process, NewPid),
            UpdatedPlayer = Player#player{pid = NewPid,
                                          connected = true,
                                          monitor_ref = NewRef},
            NewPlayers = maps:put(PlayerId, UpdatedPlayer, Players),
            io:format("[room ~s] player ~p (~s) rejoined with pid ~p~n",
                      [maps:get(pin, State), PlayerId,
                       Player#player.nickname, NewPid]),
            {reply, ok, State#{players => NewPlayers}}
    end;

handle_call({get_events_since, SinceSeq}, _From, State) ->
    CurrentSeq = maps:get(seq, State),
    Log = maps:get(event_log, State, []),
    case Log of
        [] ->
            {reply, {ok, []}, State};
        _ ->
            OldestSeq = lists:min([S || {S, _} <- Log]),
            case SinceSeq < OldestSeq - 1 of
                true ->
                    {reply, {too_far_behind, CurrentSeq}, State};
                false ->
                    Sorted = lists:keysort(1,
                             [{S, E} || {S, E} <- Log, S > SinceSeq]),
                    Events = [E || {_S, E} <- Sorted],
                    {reply, {ok, Events}, State}
            end
    end;

handle_call({start_game, From}, _From, State) ->
    case authorize_host(From, State) of
        ok ->
            start_game_if_allowed(State);
        {error, Reason} ->
            io:format("[room ~s] start_game denied: ~p~n",
                      [maps:get(pin, State), Reason]),
            {reply, {error, Reason}, State}
    end;

handle_call({next_round, From}, _From, State) ->
    case authorize_host(From, State) of
        ok ->
            case maps:get(status, State) of
                playing -> open_next_round(State);
                round_closed -> open_next_round(State);
                Status ->
                    {reply, {error, {invalid_state, Status}}, State}
            end;
        {error, Reason} ->
            io:format("[room ~s] next_round denied: ~p~n",
                      [maps:get(pin, State), Reason]),
            {reply, {error, Reason}, State}
    end;

handle_call({answer, PlayerId, Round, Answer}, _From, State) ->
    CurrentRound = maps:get(current_round, State),
    Status = maps:get(status, State),
    Players = maps:get(players, State),
    case Status of
        round_open ->
            case {CurrentRound =:= Round,
                  maps:get(PlayerId, Players, undefined)} of
                {false, _} -> {reply, {error, wrong_round}, State};
                {_, undefined} -> {reply, {error, player_not_found}, State};
                {_, Player} ->
                    case Player#player.answered of
                        true -> {reply, {error, already_answered}, State};
                        false ->
                            UpdatedPlayer = Player#player{
                                answered = true,
                                answer_time = erlang:monotonic_time(millisecond),
                                chosen_answer = Answer
                            },
                            NewPlayers = maps:put(PlayerId, UpdatedPlayer, Players),
                            State1 = State#{players => NewPlayers},
                            io:format("[room ~s] player ~p answered round ~p: ~p~n",
                                      [maps:get(pin, State), PlayerId, Round, Answer]),
                            State2 = maybe_close_round(State1),
                            {reply, ok, State2}
                    end
            end;
        _ ->
            {reply, {error, round_not_open}, State}
    end;

handle_call({cancel, From}, _From, State) ->
    case authorize_host(From, State) of
        ok ->
            case maps:get(status, State) of
                waiting ->
                    {stop, normal, ok,
                     cancel_game_state(State, host_left)};
                playing ->
                    {stop, normal, ok,
                     cancel_game_state(State, host_left)};
                round_open ->
                    {stop, normal, ok,
                     cancel_game_state(State, host_left)};
                round_closed ->
                    {stop, normal, ok,
                     cancel_game_state(State, host_left)};
                Status ->
                    {reply, {error, {invalid_state, Status}}, State}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call({end_game, From}, _From, State) ->
    case authorize_host(From, State) of
        ok ->
            case maps:get(status, State) of
                playing -> finish_game(State);
                round_open -> finish_game(State);
                round_closed -> finish_game(State);
                Status ->
                    {reply, {error, {invalid_state, Status}}, State}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(get_state, _From, State) ->
    {reply, State, State}.

handle_cast(_Msg, State) -> {noreply, State}.

%% --- Gestione disconnessione (monitor DOWN) ---
handle_info({'DOWN', MonitorRef, process, _Pid, _Reason}, State) ->
    case MonitorRef =:= maps:get(host_monitor_ref, State) of
        true ->
            cancel_after_host_disconnect(State);
        false ->
            handle_player_disconnect(MonitorRef, State)
    end;

handle_info({round_timeout, Round}, State) ->
    case maps:get(current_round, State) of
        Round ->
            case maps:get(status, State) of
                round_open ->
                    io:format("[room ~s] round ~p timeout~n",
                              [maps:get(pin, State), Round]),
                    NewState = close_round(State),
                    {noreply, NewState};
                _ -> {noreply, State}
            end;
        _ -> {noreply, State}
    end;

handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

%% ---------- Funzioni interne ----------

handle_player_disconnect(MonitorRef, State) ->
    Players = maps:get(players, State),
    case find_player_by_monitor(MonitorRef, Players) of
        {ok, PlayerId, Player} ->
            %% Marca come disconnesso (non lo rimuoviamo: può riconnettersi)
            UpdatedPlayer = Player#player{connected = false,
                                          monitor_ref = undefined},
            NewPlayers = maps:put(PlayerId, UpdatedPlayer, Players),
            State1 = State#{players => NewPlayers},
            io:format("[room ~s] player ~p (~s) disconnected~n",
                      [maps:get(pin, State), PlayerId,
                       Player#player.nickname]),
            %% Emetti un evento di disconnessione
            NewState = emit_event(State1, #{
                type => player_disconnected,
                nickname => Player#player.nickname,
                player_id => PlayerId
            }),
            %% Se il round è aperto, controlla se si può chiudere
            NewState2 = case maps:get(status, NewState) of
                round_open -> maybe_close_round(NewState);
                _ -> NewState
            end,
            {noreply, NewState2};
        not_found ->
            {noreply, State}
    end.

cancel_after_host_disconnect(State) ->
    {stop, normal, cancel_game_state(State, host_disconnected)}.

cancel_game_state(State, Reason) ->
    State1 = cancel_timer(State),
    Pin = maps:get(pin, State1),
    case quizarena_db:cancel_session(Pin) of
        ok -> ok;
        {error, DbReason} ->
            io:format("[room ~s] cancel_session failed: ~p~n",
                      [Pin, DbReason])
    end,
    CancelledState = State1#{status => cancelled},
    NewState = emit_event(CancelledState, #{
        type => game_cancelled,
        reason => Reason
    }),
    io:format("[room ~s] cancelled: ~p~n", [Pin, Reason]),
    NewState.

%% Avvia una sessione waiting solo se è presente almeno un giocatore connesso
start_game_if_allowed(State) ->
    case maps:get(status, State) of
        waiting ->
            Players = maps:values(maps:get(players, State)),
            ConnectedPlayers = [P || P <- Players,
                                      P#player.connected =:= true],
            case ConnectedPlayers of
                [] ->
                    {reply, {error, no_players}, State};
                _ ->
                    Pin = maps:get(pin, State),
                    case quizarena_db:mark_session_started(Pin) of
                        ok ->
                            State1 = State#{
                                status => playing,
                                current_round => 0
                            },
                            NewState = emit_event(
                                State1,
                                #{type => game_started}
                            ),
                            io:format("[room ~s] game started~n", [Pin]),
                            {reply, ok, NewState};
                        {error, Reason} ->
                            {reply, {
                                error,
                                {session_start_failed, Reason}
                            }, State}
                    end
            end;
        Status ->
            {reply, {error, {invalid_state, Status}}, State}
    end.

open_next_round(State) ->
    State1 = cancel_timer(State),
    Questions = maps:get(quiz_questions, State1),
    Round = maps:get(current_round, State1) + 1,

    case Round =< length(Questions) of
        true ->
            Players = maps:get(players, State1),
            ResetPlayers = maps:map(fun(_Id, P) ->
                P#player{answered = false,
                         answer_time = undefined,
                         chosen_answer = undefined}
            end, Players),
            Q = lists:nth(Round, Questions),
            TimeLimit = maps:get(time_limit, Q, ?ROUND_TIME_LIMIT),
            Question = #{
                id => Round,
                text => maps:get(text, Q),
                answers => maps:get(answers, Q),
                correct => maps:get(correct, Q),
                time_limit => TimeLimit
            },
            PublicQuestion = maps:remove(correct, Question),
            Now = erlang:monotonic_time(millisecond),
            Deadline = Now + TimeLimit,
            TimerRef = erlang:send_after(
                TimeLimit,
                self(),
                {round_timeout, Round}
            ),
            State2 = State1#{
                current_round => Round,
                question => Question,
                status => round_open,
                round_start_time => Now,
                round_deadline => Deadline,
                timer_ref => TimerRef,
                players => ResetPlayers
            },
            NewState = emit_event(State2, #{
                type => round_started,
                round => Round,
                question => PublicQuestion
            }),
            io:format("[room ~s] round ~p started (~p ms)~n",
                      [maps:get(pin, State), Round, TimeLimit]),
            {reply, ok, NewState};
        false ->
            io:format("[room ~s] no more questions (round ~p)~n",
                      [maps:get(pin, State), Round]),
            {reply, {error, no_more_questions}, State1}
    end.

finish_game(State) ->
    Pin = maps:get(pin, State),
    Players = maps:get(players, State),
    PlayerResults = [
        {P#player.nickname, P#player.score}
        || P <- maps:values(Players)
    ],
    case quizarena_db:finish_session(Pin, PlayerResults) of
        ok ->
            State1 = cancel_timer(State),
            Leaderboard = build_leaderboard(Players),
            State2 = State1#{status => finished},
            NewState = emit_event(State2, #{
                type => game_finished,
                final_leaderboard => Leaderboard
            }),
            io:format("[room ~s] game finished~n", [Pin]),
            {stop, normal, ok, NewState};
        {error, Reason} ->
            {reply, {error, {session_finish_failed, Reason}}, State}
    end.

%% Trova un player tramite il suo MonitorRef
find_player_by_monitor(_MonitorRef, Players) when map_size(Players) =:= 0 ->
    not_found;
find_player_by_monitor(MonitorRef, Players) ->
    maps:fold(
        fun(PlayerId, #player{monitor_ref = Ref} = P, Acc) ->
            case {Acc, Ref} of
                {not_found, MonitorRef} -> {ok, PlayerId, P};
                _ -> Acc
            end
        end, not_found, Players).

load_session_questions(Pin) ->
    F = fun() ->
        All = mnesia:foldl(
            fun({session_questions, {P, N}, Text, Ans, Corr, TL}, Acc) ->
                case P =:= Pin of
                    true -> [{N, #{text => Text, answers => Ans,
                                   correct => Corr, time_limit => TL}} | Acc];
                    false -> Acc
                end
            end, [], session_questions),
        lists:keysort(1, All)
    end,
    {atomic, Sorted} = mnesia:transaction(F),
    [Q || {_N, Q} <- Sorted].

authorize_host(From, State) ->
    HostPid = maps:get(host_pid, State),
    case From =:= HostPid of
        true -> ok;
        false -> {error, not_host}
    end.

emit_event(State, Event) ->
    NewSeq = maps:get(seq, State) + 1,
    Event1 = Event#{seq => NewSeq},
    broadcast(State, Event1),
    OldLog = maps:get(event_log, State, []),
    NewLog = [{NewSeq, Event1} | OldLog],
    TrimmedLog = lists:sublist(NewLog, ?MAX_EVENT_LOG),
    State#{seq => NewSeq, event_log => TrimmedLog}.

%% Invia l'evento all'host e a tutti i player connessi.
broadcast(State, Event) ->
    HostPid = maps:get(host_pid, State),
    HostPid ! {event, Event},
    Players = maps:get(players, State),
    maps:foreach(fun(_Id, #player{pid = Pid, connected = Connected}) ->
        case Connected andalso Pid =/= HostPid of
            true -> Pid ! {event, Event};
            false -> ok
        end
    end, Players).

%% Chiude il round quando tutti i player CONNESSI hanno risposto.
%% I disconnessi non contano.
maybe_close_round(State) ->
    Players = maps:get(players, State),
    ConnectedPlayers = [P || P <- maps:values(Players),
                             P#player.connected =:= true],
    case ConnectedPlayers of
        [] ->
            %% Nessun giocatore connesso: nessuno può rispondere.
            %% Non chiudiamo da soli: aspettiamo il timeout.
            State;
        _ ->
            AllAnswered = lists:all(
                fun(#player{answered = A}) -> A end,
                ConnectedPlayers
            ),
            case AllAnswered of
                true -> close_round(State);
                false -> State
            end
    end.

close_round(State) ->
    State1 = cancel_timer(State),
    Round = maps:get(current_round, State1),
    Question = maps:get(question, State1),
    Correct = maps:get(correct, Question),
    StartTime = maps:get(round_start_time, State1),
    TimeLimit = maps:get(time_limit, Question),

    Players = maps:get(players, State1),
    UpdatedPlayers = maps:map(fun(_Id, P) ->
        case P#player.answered andalso P#player.chosen_answer =:= Correct of
            true ->
                Elapsed = P#player.answer_time - StartTime,
                Points = compute_score(Elapsed, TimeLimit),
                P#player{score = P#player.score + Points};
            false -> P
        end
    end, Players),

    Leaderboard = build_leaderboard(UpdatedPlayers),
    State2 = State1#{players => UpdatedPlayers, status => round_closed},
    emit_event(State2, #{
        type => round_closed,
        round => Round,
        correct => Correct,
        leaderboard => Leaderboard
    }).

compute_score(ElapsedMs, TimeLimitMs) ->
    Remaining = max(0, TimeLimitMs - ElapsedMs),
    round(?POINTS_BASE * Remaining / TimeLimitMs).

build_leaderboard(Players) ->
    List = [{P#player.nickname, P#player.score} || P <- maps:values(Players)],
    lists:reverse(lists:keysort(2, List)).

cancel_timer(State) ->
    case maps:get(timer_ref, State, undefined) of
        undefined -> State;
        Ref ->
            _ = erlang:cancel_timer(Ref),
            State#{timer_ref => undefined}
    end.
