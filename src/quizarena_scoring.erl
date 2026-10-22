-module(quizarena_scoring).

-export([validated_answer_time/4, compute_score/2, leaderboard/1]).

%% Regole di gioco senza stato: controllo dei tempi di risposta, punteggio
%% e classifica. Le usa room_gen_server.

-define(POINTS_BASE, 1000).
%% Controllo dei tempi di risposta (approccio simile a Cristian): il tempo
%% misurato dal client sul proprio orologio monotono e' accettato se si
%% discosta dal tempo misurato dal server di al piu' questa tolleranza piu'
%% l'RTT del client, stimato dal web tier con piu' sonde (il minimo).
-define(ANSWER_TIME_TOLERANCE_MS, 1000).
%% Limite all'RTT dichiarato: un client che ritarda di proposito le sonde
%% non puo' allargare la tolleranza oltre questo valore.
-define(MAX_ACCEPTED_RTT_MS, 1000).

%% Restituisce {TempoUsatoPerIlPunteggio, Sospetto}. Il tempo del client e'
%% piu' preciso (non include la latenza di rete); se non e' credibile si usa
%% quello del server, che penalizza il client della latenza.
validated_answer_time(ClientElapsedMs, ServerElapsedMs, RttMs, TimeLimitMs) ->
    AcceptedRttMs = min(RttMs, ?MAX_ACCEPTED_RTT_MS),
    AllowedDifferenceMs = ?ANSWER_TIME_TOLERANCE_MS + AcceptedRttMs,
    DifferenceMs = abs(ServerElapsedMs - ClientElapsedMs),
    case ClientElapsedMs =< TimeLimitMs
         andalso DifferenceMs =< AllowedDifferenceMs of
        true -> {ClientElapsedMs, false};
        false -> {max(0, ServerElapsedMs), true}
    end.

%% Una risposta corretta vale da POINTS_BASE (istantanea) a POINTS_BASE/2
%% (alla scadenza), decrescendo linearmente: la correttezza conta sempre
%% piu' della velocita'. Oltre la scadenza (possibile solo nel margine,
%% quando per il punteggio vale il tempo del server) non vale nulla.
compute_score(ElapsedMs, TimeLimitMs) when ElapsedMs > TimeLimitMs ->
    0;
compute_score(ElapsedMs, TimeLimitMs) ->
    round(?POINTS_BASE * (1 - max(0, ElapsedMs) / (2 * TimeLimitMs))).

%% Classifica [{Username, Punteggio}] dal punteggio piu' alto.
leaderboard(Scores) ->
    lists:reverse(lists:keysort(2, Scores)).
