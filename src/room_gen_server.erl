-module(room_gen_server).
-behaviour(gen_server).

-export([start_link/1, join/3, rejoin/3, host_rejoin/3, disconnect/2,
         start_game/2, next_round/2, answer/6, cancel/2, end_game/2,
         get_state/1, get_player_state/2, get_events_since/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(POINTS_BASE, 1000).
-define(ROUND_TIME_LIMIT, 60000).
-define(MAX_EVENT_LOG, 200).
%% Controllo dei tempi di risposta (approccio simile a Cristian): il tempo
%% misurato dal client sul proprio orologio monotono e' accettato se si
%% discosta dal tempo misurato dal server di al piu' questa tolleranza piu'
%% l'RTT del client, stimato dal web tier con piu' sonde (il minimo).
-define(ANSWER_TIME_TOLERANCE_MS, 1000).
%% Limite all'RTT dichiarato: un client che ritarda di proposito le sonde
%% non puo' allargare la tolleranza oltre questo valore.
-define(MAX_ACCEPTED_RTT_MS, 1000).
%% Margine dopo la scadenza del round: una risposta data in tempo dal
%% client ma ancora in viaggio sulla rete non viene scartata.
-define(ANSWER_GRACE_MS, 500).
%% Tempo concesso all'host per riconnettersi prima di chiudere la stanza
%% (sovrascrivibile con la variabile d'ambiente host_grace_ms).
-define(DEFAULT_HOST_GRACE_MS, 30000).
%% Eventi conservati nello snapshot per il recupero dei client.
-define(SNAPSHOT_EVENT_LOG, 50).

%% I client sono mailbox Jinterface: Jinterface non supporta i monitor
%% (la chiusura di una singola mailbox non genera DOWN), mentre propaga
%% correttamente i link. Per questo la room fa trap_exit e si linka a
%% host e giocatori: la chiusura di una mailbox arriva come 'EXIT'.
-record(player, {
    username,
    pid,
    score = 0,
    answered = false,
    answer_time,
    chosen_answer,
    connected = true,
    %% Tempo di risposta del round corrente non coerente con quello misurato
    %% dal server: viene segnalato all'host alla chiusura del round.
    suspicious = false
}).

%% ---------- API pubblica ----------

start_link(Args) when is_map(Args) ->
    gen_server:start_link(?MODULE, Args, []).

join(Pin, Username, PlayerPid) ->
    gen_server:call(via(Pin), {join, Username, PlayerPid}).

rejoin(Pin, Username, NewPid) ->
    gen_server:call(via(Pin), {rejoin, Username, NewPid}).

host_rejoin(Pin, Username, NewPid) ->
    gen_server:call(via(Pin), {host_rejoin, Username, NewPid}).

disconnect(Pin, ClientPid) ->
    gen_server:call(via(Pin), {disconnect, ClientPid}).

start_game(Pin, RequesterPid) ->
    gen_server:call(via(Pin), {start_game, RequesterPid}).

next_round(Pin, RequesterPid) ->
    gen_server:call(via(Pin), {next_round, RequesterPid}).

answer(Pin, PlayerPid, Round, Answer, ClientElapsedMs, RttMs) ->
    gen_server:call(via(Pin),
                    {answer, PlayerPid, Round, Answer,
                     ClientElapsedMs, RttMs}).

cancel(Pin, RequesterPid) ->
    gen_server:call(via(Pin), {cancel, RequesterPid}).

end_game(Pin, RequesterPid) ->
    gen_server:call(via(Pin), {end_game, RequesterPid}).

get_state(Pin) ->
    gen_server:call(via(Pin), get_state).

get_player_state(Pin, Username) ->
    gen_server:call(via(Pin), {get_player_state, Username}).

get_events_since(Pin, SinceSeq) ->
    gen_server:call(via(Pin), {get_events_since, SinceSeq}).

via(Pin) ->
    {via, global, {room, Pin}}.

%% ---------- Callback gen_server ----------

%% Avvio normale (#{pin, session_id, host_username, host_pid, visibility})
%% oppure ripristino da snapshot dopo la caduta del nodo che ospitava la
%% stanza (#{recover => Snapshot}).
init(#{recover := #{pin := Pin} = Snapshot}) ->
    process_flag(trap_exit, true),
    case global:register_name({room, Pin}, self()) of
        yes -> {ok, recover_state(Snapshot)};
        no  -> {stop, {room_already_registered, Pin}}
    end;
init(#{pin := Pin} = Args) ->
    process_flag(trap_exit, true),
    case global:register_name({room, Pin}, self()) of
        yes -> init_registered_room(Args);
        no  -> {stop, {room_already_registered, Pin}}
    end.

init_registered_room(#{pin := Pin, session_id := SessionId,
                       host_username := HostUsername, host_pid := HostPid,
                       visibility := Visibility}) ->
    case {quizarena_db:get_session(SessionId),
          quizarena_db:get_session_questions(SessionId)} of
        {{ok, #{quiz_title := Title}}, {ok, [_ | _] = Questions}} ->
            link(HostPid),
            logger:notice("[room ~s] avviato (host=~s, visibility=~p, "
                      "~p domande)",
                      [Pin, HostUsername, Visibility, length(Questions)]),
            State = #{
                pin => Pin,
                session_id => SessionId,
                quiz_title => Title,
                host_username => HostUsername,
                host_pid => HostPid,
                host_connected => true,
                host_grace_ref => undefined,
                visibility => Visibility,
                quiz_questions => Questions,
                players => #{},
                status => waiting,
                current_round => 0,
                question => undefined,
                round_start_time => undefined,
                round_deadline => undefined,
                timer_ref => undefined,
                seq => 0,
                event_log => [],
                recover_count => 0
            },
            publish(State),
            persist(State),
            {ok, State};
        {{ok, _Session}, {ok, []}} ->
            {stop, no_questions};
        {{error, Reason}, _} ->
            {stop, {session_load_failed, Reason}};
        {_, {error, Reason}} ->
            {stop, {session_load_failed, Reason}}
    end.

handle_call({join, Username, PlayerPid}, _From, State)
  when is_list(Username), Username =/= [], is_pid(PlayerPid) ->
    Players = maps:get(players, State),
    case {Username =:= maps:get(host_username, State),
          maps:get(Username, Players, undefined)} of
        {true, _} ->
            {reply, {error, host_cannot_play}, State};
        {false, #player{connected = false} = Player} ->
            reattach_player(Username, Player, PlayerPid, State);
        {false, #player{}} ->
            {reply, {error, already_joined}, State};
        {false, undefined} ->
            join_new_player(Username, PlayerPid, State)
    end;

handle_call({join, _Username, _PlayerPid}, _From, State) ->
    {reply, {error, invalid_request}, State};

handle_call({rejoin, Username, NewPid}, _From, State)
  when is_list(Username), Username =/= [], is_pid(NewPid) ->
    Players = maps:get(players, State),
    case {maps:get(Username, Players, undefined), maps:get(status, State)} of
        {undefined, waiting} ->
            %% In attesa chi esce viene rimosso: rientrare equivale a
            %% un nuovo ingresso.
            handle_call({join, Username, NewPid}, undefined, State);
        {undefined, _Status} ->
            {reply, {error, player_not_found}, State};
        {Player, _Status} ->
            reattach_player(Username, Player, NewPid, State)
    end;

handle_call({rejoin, _Username, _NewPid}, _From, State) ->
    {reply, {error, invalid_request}, State};

handle_call({host_rejoin, Username, NewPid}, _From, State)
  when is_list(Username), is_pid(NewPid) ->
    case Username =:= maps:get(host_username, State) of
        true ->
            NewState = reattach_host(NewPid, State),
            {reply, {ok, host_state_for(NewState)}, NewState};
        false ->
            {reply, {error, not_host}, State}
    end;

handle_call({host_rejoin, _Username, _NewPid}, _From, State) ->
    {reply, {error, invalid_request}, State};

handle_call({disconnect, ClientPid}, _From, State)
  when is_pid(ClientPid) ->
    case client_down(ClientPid, State) of
        {ok, NewState} -> {reply, ok, NewState};
        {stop, NewState} -> {stop, normal, ok, NewState}
    end;

handle_call({disconnect, _ClientPid}, _From, State) ->
    {reply, {error, invalid_request}, State};

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
                    {reply, {error, {too_far_behind, CurrentSeq}}, State};
                false ->
                    Sorted = lists:keysort(1,
                             [{S, E} || {S, E} <- Log, S > SinceSeq]),
                    Events = [E || {_S, E} <- Sorted],
                    {reply, {ok, Events}, State}
            end
    end;

handle_call({get_player_state, Username}, _From, State)
  when is_list(Username), Username =/= [] ->
    {reply, player_state_for(Username, State), State};

handle_call({get_player_state, _Username}, _From, State) ->
    {reply, {error, invalid_request}, State};

handle_call({start_game, From}, _From, State) ->
    case authorize_host(From, State) of
        ok ->
            start_game_if_allowed(State);
        {error, Reason} ->
            logger:notice("[room ~s] start_game denied: ~p",
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
            logger:notice("[room ~s] next_round denied: ~p",
                      [maps:get(pin, State), Reason]),
            {reply, {error, Reason}, State}
    end;

handle_call({answer, PlayerPid, Round, Answer, ClientElapsedMs, RttMs},
            _From, State)
  when is_integer(ClientElapsedMs), ClientElapsedMs >= 0,
       is_integer(RttMs), RttMs >= 0 ->
    CurrentRound = maps:get(current_round, State),
    Status = maps:get(status, State),
    Players = maps:get(players, State),
    case Status of
        round_open ->
            case {CurrentRound =:= Round,
                  find_player_by_pid(PlayerPid, Players)} of
                {false, _} -> {reply, {error, wrong_round}, State};
                {_, not_found} -> {reply, {error, player_not_found}, State};
                {_, {ok, Username, Player}} ->
                    case Player#player.answered of
                        true -> {reply, {error, already_answered}, State};
                        false ->
                            ServerElapsedMs = erlang:monotonic_time(millisecond)
                                - maps:get(round_start_time, State),
                            TimeLimitMs = maps:get(
                                time_limit, maps:get(question, State)),
                            {ElapsedMs, Suspicious} = validated_answer_time(
                                ClientElapsedMs, ServerElapsedMs,
                                RttMs, TimeLimitMs,
                                maps:get(pin, State), Username),
                            UpdatedPlayer = Player#player{
                                answered = true,
                                answer_time = ElapsedMs,
                                chosen_answer = Answer,
                                suspicious = Suspicious
                            },
                            NewPlayers = maps:put(Username, UpdatedPlayer, Players),
                            State1 = State#{players => NewPlayers},
                            logger:notice("[room ~s] player ~s answered round ~p: ~p",
                                      [maps:get(pin, State), Username, Round, Answer]),
                            State2 = maybe_close_round(State1),
                            %% Risposta confermata solo dopo la replica.
                            persist(State2),
                            {reply, ok, State2}
                    end
            end;
        _ ->
            {reply, {error, round_not_open}, State}
    end;

handle_call({answer, _PlayerPid, _Round, _Answer,
             _ClientElapsedMs, _RttMs}, _From, State) ->
    {reply, {error, invalid_request}, State};

handle_call({cancel, From}, _From, State) ->
    case authorize_host(From, State) of
        ok ->
            {stop, normal, ok, cancel_game_state(State, host_left)};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call({end_game, From}, _From, State) ->
    case authorize_host(From, State) of
        ok ->
            case maps:get(status, State) of
                waiting ->
                    {reply, {error, {invalid_state, waiting}}, State};
                _ ->
                    case finish_game(State) of
                        {ok, NewState} -> {stop, normal, ok, NewState};
                        {error, Reason} -> {reply, {error, Reason}, State}
                    end
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(get_state, _From, State) ->
    {reply, State, State}.

handle_cast(_Msg, State) -> {noreply, State}.

%% --- Mailbox Java chiusa (link) ---
handle_info({'EXIT', Pid, _Reason}, State) ->
    case client_down(Pid, State) of
        {ok, NewState} -> {noreply, NewState};
        {stop, NewState} -> {stop, normal, NewState}
    end;

handle_info({round_timeout, Round}, State) ->
    case maps:get(current_round, State) of
        Round ->
            case maps:get(status, State) of
                round_open ->
                    logger:notice("[room ~s] round ~p timeout",
                              [maps:get(pin, State), Round]),
                    NewState = close_round(State),
                    {noreply, NewState};
                _ -> {noreply, State}
            end;
        _ -> {noreply, State}
    end;

handle_info({host_grace_expired, Ref}, State) ->
    case {maps:get(host_connected, State), maps:get(host_grace_ref, State)} of
        {false, Ref} ->
            host_gone(State);
        _ ->
            {noreply, State}
    end;

handle_info(_Info, State) -> {noreply, State}.

%% Fine regolare della partita: la stanza sparisce. Se invece il nodo si
%% sta spegnendo (shutdown) lo snapshot resta, e il leader del cluster
%% ripristinera' la stanza su un altro nodo.
terminate(normal, State) ->
    Pin = maps:get(pin, State),
    quizarena_db:unpublish_room(Pin),
    quizarena_db:delete_snapshot(Pin),
    ok;
terminate(_Reason, _State) ->
    ok.

%% ---------- Disconnessioni ----------

%% Un client (host o giocatore) non e' piu' raggiungibile, per chiusura
%% esplicita o per 'EXIT' del link.
client_down(Pid, State) ->
    case maps:get(host_connected, State)
         andalso Pid =:= maps:get(host_pid, State) of
        true ->
            {ok, host_disconnected(State)};
        false ->
            case find_player_by_pid(Pid, maps:get(players, State)) of
                {ok, Username, Player} ->
                    {ok, mark_player_disconnected(Username, Player, State)};
                not_found ->
                    {ok, State}
            end
    end.

%% L'host non uccide subito la partita: ha un periodo di grazia per rientrare.
%% Intanto il round in corso prosegue e si chiude normalmente.
host_disconnected(State) ->
    safe_unlink(maps:get(host_pid, State)),
    {GraceMs, State1} = start_host_grace(State),
    logger:notice("[room ~s] host disconnected, grace ~p ms",
              [maps:get(pin, State), GraceMs]),
    emit_event(State1, #{
        type => host_disconnected,
        grace_ms => GraceMs
    }).

start_host_grace(State) ->
    GraceMs = application:get_env(quizarena, host_grace_ms,
                                  ?DEFAULT_HOST_GRACE_MS),
    Ref = make_ref(),
    erlang:send_after(GraceMs, self(), {host_grace_expired, Ref}),
    {GraceMs, State#{host_connected => false, host_grace_ref => Ref}}.

%% Scaduto il periodo di grazia: se tutte le domande sono state giocate i
%% risultati vengono salvati, altrimenti la partita e' annullata.
host_gone(State) ->
    case all_rounds_played(State) andalso finish_game(State) of
        {ok, NewState} ->
            {stop, normal, NewState};
        _ ->
            {stop, normal, cancel_game_state(State, host_disconnected)}
    end.

reattach_host(NewPid, State) ->
    case maps:get(host_connected, State) of
        true -> safe_unlink(maps:get(host_pid, State));
        false -> ok
    end,
    link(NewPid),
    logger:notice("[room ~s] host rejoined with pid ~p",
              [maps:get(pin, State), NewPid]),
    emit_event(State#{host_pid => NewPid, host_connected => true,
                      host_grace_ref => undefined},
               #{type => host_rejoined}).

mark_player_disconnected(Username, Player, State) ->
    safe_unlink(Player#player.pid),
    Players = maps:get(players, State),
    NewPlayers = case maps:get(status, State) of
        waiting ->
            maps:remove(Username, Players);
        _ ->
            maps:put(Username,
                     Player#player{pid = undefined, connected = false},
                     Players)
    end,
    logger:notice("[room ~s] player ~s disconnected",
              [maps:get(pin, State), Username]),
    State1 = emit_event(State#{players => NewPlayers}, #{
        type => player_disconnected,
        username => Username
    }),
    case maps:get(status, State1) of
        round_open -> maybe_close_round(State1);
        _ -> State1
    end.

safe_unlink(Pid) when is_pid(Pid) ->
    unlink(Pid),
    %% Scarta un eventuale 'EXIT' gia' arrivato dal vecchio link.
    receive {'EXIT', Pid, _} -> ok after 0 -> ok end;
safe_unlink(_) ->
    ok.

%% ---------- Stato per il rientro ----------

player_state_for(Username, State) ->
    Players = maps:get(players, State),
    case maps:get(Username, Players, undefined) of
        undefined ->
            {error, player_not_found};
        Player ->
            Status = maps:get(status, State),
            Base = #{
                status => Status,
                current_round => maps:get(current_round, State),
                username => Player#player.username,
                answered => Player#player.answered,
                score => Player#player.score,
                host_connected => maps:get(host_connected, State),
                seq => maps:get(seq, State)
            },
            {ok, add_round_state(Status, State, Players, Base)}
    end.

host_state_for(State) ->
    Status = maps:get(status, State),
    Players = maps:get(players, State),
    Base = #{
        pin => maps:get(pin, State),
        visibility => maps:get(visibility, State),
        quiz_title => maps:get(quiz_title, State),
        status => Status,
        current_round => maps:get(current_round, State),
        total_rounds => length(maps:get(quiz_questions, State)),
        players => [U || {U, #player{connected = true}}
                             <- maps:to_list(Players)],
        seq => maps:get(seq, State)
    },
    add_round_state(Status, State, Players, Base).

add_round_state(round_open, State, _Players, Base) ->
    Question = maps:get(question, State),
    Deadline = maps:get(round_deadline, State),
    Remaining = erlang:max(
        0, Deadline - erlang:monotonic_time(millisecond)),
    Base#{
        question => maps:remove(correct, Question),
        remaining_time => Remaining
    };
add_round_state(round_closed, State, Players, Base) ->
    Question = maps:get(question, State),
    Base#{
        correct => maps:get(correct, Question),
        leaderboard => build_leaderboard(Players),
        has_next_round => not all_rounds_played(State)
    };
add_round_state(_Status, _State, _Players, Base) ->
    Base.

%% ---------- Ciclo di vita della partita ----------

cancel_game_state(State, Reason) ->
    State1 = cancel_timer(State),
    Pin = maps:get(pin, State1),
    SessionId = maps:get(session_id, State1),
    case quizarena_db:cancel_session(SessionId) of
        ok -> ok;
        {error, DbReason} ->
            logger:notice("[room ~s] cancel_session failed: ~p",
                      [Pin, DbReason])
    end,
    CancelledState = State1#{status => cancelled},
    NewState = emit_event(CancelledState, #{
        type => game_cancelled,
        reason => Reason
    }),
    logger:notice("[room ~s] cancelled: ~p", [Pin, Reason]),
    NewState.

start_game_if_allowed(State) ->
    case maps:get(status, State) of
        waiting ->
            case connected_players(State) of
                [] ->
                    {reply, {error, no_players}, State};
                _ ->
                    Pin = maps:get(pin, State),
                    SessionId = maps:get(session_id, State),
                    case quizarena_db:mark_session_started(SessionId) of
                        ok ->
                            State1 = State#{
                                status => playing,
                                current_round => 0
                            },
                            NewState = emit_event(
                                State1,
                                #{type => game_started}
                            ),
                            logger:notice("[room ~s] game started", [Pin]),
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
            ResetPlayers = maps:map(fun(_Username, P) ->
                P#player{answered = false,
                         answer_time = undefined,
                         chosen_answer = undefined,
                         suspicious = false}
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
                TimeLimit + ?ANSWER_GRACE_MS,
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
            logger:notice("[room ~s] round ~p started (~p ms)",
                      [maps:get(pin, State), Round, TimeLimit]),
            {reply, ok, NewState};
        false ->
            logger:notice("[room ~s] no more questions (round ~p)",
                      [maps:get(pin, State), Round]),
            {reply, {error, no_more_questions}, State1}
    end.

%% Salva i risultati e notifica la classifica finale.
%% Restituisce {ok, NuovoStato} oppure {error, Motivo}.
finish_game(State) ->
    Pin = maps:get(pin, State),
    SessionId = maps:get(session_id, State),
    Players = maps:get(players, State),
    PlayerResults = [
        {P#player.username, P#player.score}
        || P <- maps:values(Players)
    ],
    case quizarena_db:finish_session(SessionId, PlayerResults) of
        ok ->
            State1 = cancel_timer(State),
            Leaderboard = build_leaderboard(Players),
            State2 = State1#{status => finished},
            NewState = emit_event(State2, #{
                type => game_finished,
                final_leaderboard => Leaderboard
            }),
            logger:notice("[room ~s] game finished", [Pin]),
            {ok, NewState};
        {error, Reason} ->
            {error, {session_finish_failed, Reason}}
    end.

all_rounds_played(State) ->
    maps:get(status, State) =:= round_closed
        andalso maps:get(current_round, State)
                =:= length(maps:get(quiz_questions, State)).

%% ---------- Giocatori ----------

connected_players(State) ->
    [P || P <- maps:values(maps:get(players, State)),
          P#player.connected =:= true].

find_player_by_pid(PlayerPid, Players) ->
    maps:fold(
        fun(Username, #player{pid = Pid, connected = Connected} = Player, Acc) ->
            case {Acc, Pid =:= PlayerPid andalso Connected} of
                {not_found, true} -> {ok, Username, Player};
                _ -> Acc
            end
        end, not_found, Players).

join_new_player(Username, PlayerPid, State) ->
    case maps:get(status, State) of
        waiting ->
            Players = maps:get(players, State),
            link(PlayerPid),
            Player = #player{username = Username,
                             pid = PlayerPid,
                             connected = true},
            NewPlayers = maps:put(Username, Player, Players),
            State1 = State#{players => NewPlayers},
            NewState = emit_event(State1, #{
                type => player_joined,
                username => Username
            }),
            logger:notice("[room ~s] ~s joined (pid=~p)",
                      [maps:get(pin, State), Username, PlayerPid]),
            {reply, ok, NewState};
        Status ->
            {reply, {error, {invalid_state, Status}}, State}
    end.

reattach_player(Username, Player, NewPid, State) ->
    safe_unlink(Player#player.pid),
    link(NewPid),
    UpdatedPlayer = Player#player{pid = NewPid, connected = true},
    Players = maps:get(players, State),
    NewPlayers = maps:put(Username, UpdatedPlayer, Players),
    State1 = State#{players => NewPlayers},
    NewState = emit_event(State1, #{
        type => player_rejoined,
        username => Player#player.username
    }),
    logger:notice("[room ~s] player ~s rejoined with pid ~p",
              [maps:get(pin, State), Username, NewPid]),
    {reply, ok, NewState}.

authorize_host(From, State) ->
    case maps:get(host_connected, State)
         andalso From =:= maps:get(host_pid, State) of
        true -> ok;
        false -> {error, not_host}
    end.

%% ---------- Eventi ----------

%% Ogni evento riceve un numero di sequenza crescente: la room e' l'unico
%% sequencer della partita. Ogni cambio di stato passa da qui, quindi qui
%% si aggiorna anche il registro delle stanze letto dalla lobby.
emit_event(State, Event) ->
    NewSeq = maps:get(seq, State) + 1,
    Event1 = Event#{seq => NewSeq},
    OldLog = maps:get(event_log, State, []),
    NewLog = [{NewSeq, Event1} | OldLog],
    TrimmedLog = lists:sublist(NewLog, ?MAX_EVENT_LOG),
    NewState = State#{seq => NewSeq, event_log => TrimmedLog},
    %% Prima il registro, poi i client: chi reagisce all'evento leggendo
    %% la lobby trova gia' lo stato aggiornato.
    publish(NewState),
    persist(NewState),
    broadcast(NewState, Event1),
    NewState.

broadcast(State, Event) ->
    case maps:get(host_connected, State) of
        true -> maps:get(host_pid, State) ! {event, Event};
        false -> ok
    end,
    maps:foreach(fun(_Username, #player{pid = Pid, connected = Connected}) ->
        case Connected of
            true -> Pid ! {event, Event};
            false -> ok
        end
    end, maps:get(players, State)).

publish(State) ->
    quizarena_db:publish_room(#{
        pin => maps:get(pin, State),
        session_id => maps:get(session_id, State),
        quiz_title => maps:get(quiz_title, State),
        host => maps:get(host_username, State),
        visibility => maps:get(visibility, State),
        status => maps:get(status, State),
        num_players => length(connected_players(State)),
        num_questions => length(maps:get(quiz_questions, State)),
        current_round => maps:get(current_round, State)
    }).

%% ---------- Snapshot e ripristino ----------

%% Lo stato della partita viene replicato a ogni cambiamento. I tempi del
%% round sono salvati come tempo di sistema: il tempo monotono non e'
%% confrontabile fra nodi diversi, mentre gli orologi delle macchine sono
%% sincronizzati (NTP) con uno scarto trascurabile rispetto alla durata
%% di un round.
persist(State) ->
    Now = erlang:monotonic_time(millisecond),
    WallNow = erlang:system_time(millisecond),
    ToWall = fun(undefined) -> undefined;
                (Monotonic) -> WallNow + (Monotonic - Now)
             end,
    Snapshot = maps:without(
        [timer_ref, host_grace_ref, round_start_time, round_deadline],
        State#{event_log => lists:sublist(maps:get(event_log, State),
                                          ?SNAPSHOT_EVENT_LOG)}),
    quizarena_db:save_snapshot(maps:get(pin, State), Snapshot#{
        round_start_wall => ToWall(maps:get(round_start_time, State)),
        round_deadline_wall => ToWall(maps:get(round_deadline, State))
    }).

%% Ricostruisce la stanza da uno snapshot. I client vengono ri-linkati:
%% quelli che erano sul nodo caduto risultano subito disconnessi ('EXIT'
%% noconnection) e potranno rientrare; gli altri continuano a ricevere gli
%% eventi senza accorgersi del cambio di nodo.
recover_state(Snapshot) ->
    Now = erlang:monotonic_time(millisecond),
    WallNow = erlang:system_time(millisecond),
    ToMonotonic = fun(undefined) -> undefined;
                     (Wall) -> Now + (Wall - WallNow)
                  end,
    State0 = maps:without([round_start_wall, round_deadline_wall], Snapshot),
    State1 = State0#{
        timer_ref => undefined,
        host_grace_ref => undefined,
        round_start_time => ToMonotonic(maps:get(round_start_wall, Snapshot)),
        round_deadline => ToMonotonic(maps:get(round_deadline_wall, Snapshot)),
        recover_count => maps:get(recover_count, Snapshot, 0) + 1
    },
    State2 = relink_clients(State1),
    State3 = restart_round_timer(State2),
    logger:notice("[room ~s] ripristinata su ~p (seq ~p, stato ~p)",
              [maps:get(pin, State3), node(), maps:get(seq, State3),
               maps:get(status, State3)]),
    emit_event(State3, #{type => room_recovered, node => node()}).

relink_clients(State) ->
    State1 = case maps:get(host_connected, State) of
        true ->
            link(maps:get(host_pid, State)),
            State;
        false ->
            {_GraceMs, WithGrace} = start_host_grace(State),
            WithGrace
    end,
    maps:foreach(fun(_Username, #player{pid = Pid, connected = Connected}) ->
        case Connected of
            true -> link(Pid);
            false -> ok
        end
    end, maps:get(players, State1)),
    State1.

restart_round_timer(#{status := round_open, current_round := Round,
                      round_deadline := Deadline} = State) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    TimerRef = erlang:send_after(Remaining + ?ANSWER_GRACE_MS, self(),
                                 {round_timeout, Round}),
    State#{timer_ref => TimerRef};
restart_round_timer(State) ->
    State.

%% ---------- Round ----------

maybe_close_round(State) ->
    case connected_players(State) of
        [] ->
            State;
        ConnectedPlayers ->
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
    TimeLimit = maps:get(time_limit, Question),

    Players = maps:get(players, State1),
    UpdatedPlayers = maps:map(fun(_Username, P) ->
        case P#player.answered andalso P#player.chosen_answer =:= Correct of
            true ->
                Points = compute_score(P#player.answer_time, TimeLimit),
                P#player{score = P#player.score + Points};
            false -> P
        end
    end, Players),

    Leaderboard = build_leaderboard(UpdatedPlayers),
    HasNextRound = Round < length(maps:get(quiz_questions, State1)),
    Suspicious = lists:sort([U || {U, #player{suspicious = true}}
                                      <- maps:to_list(UpdatedPlayers)]),
    State2 = State1#{players => UpdatedPlayers, status => round_closed},
    emit_event(State2, #{
        type => round_closed,
        round => Round,
        correct => Correct,
        has_next_round => HasNextRound,
        leaderboard => Leaderboard,
        suspicious => Suspicious
    }).

%% Restituisce {TempoUsatoPerIlPunteggio, Sospetto}. Il tempo del client e'
%% piu' preciso (non include la latenza di rete); se non e' credibile si usa
%% quello del server, che penalizza il client della latenza.
validated_answer_time(ClientElapsedMs, ServerElapsedMs, RttMs,
                      TimeLimitMs, Pin, Username) ->
    AcceptedRttMs = min(RttMs, ?MAX_ACCEPTED_RTT_MS),
    AllowedDifferenceMs = ?ANSWER_TIME_TOLERANCE_MS + AcceptedRttMs,
    DifferenceMs = abs(ServerElapsedMs - ClientElapsedMs),
    case ClientElapsedMs =< TimeLimitMs
         andalso DifferenceMs =< AllowedDifferenceMs of
        true ->
            {ClientElapsedMs, false};
        false ->
            logger:notice(
                "[room ~s] suspicious answer time from ~s: "
                "client=~p ms server=~p ms rtt=~p ms",
                [Pin, Username, ClientElapsedMs, ServerElapsedMs, RttMs]),
            {max(0, ServerElapsedMs), true}
    end.

compute_score(ElapsedMs, TimeLimitMs) ->
    Remaining = max(0, TimeLimitMs - ElapsedMs),
    round(?POINTS_BASE * Remaining / TimeLimitMs).

build_leaderboard(Players) ->
    List = [{P#player.username, P#player.score} || P <- maps:values(Players)],
    lists:reverse(lists:keysort(2, List)).

cancel_timer(State) ->
    case maps:get(timer_ref, State, undefined) of
        undefined -> State;
        Ref ->
            _ = erlang:cancel_timer(Ref),
            State#{timer_ref => undefined}
    end.
