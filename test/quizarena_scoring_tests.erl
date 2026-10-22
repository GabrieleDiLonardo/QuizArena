-module(quizarena_scoring_tests).

-include_lib("eunit/include/eunit.hrl").

%% Regole di gioco provate direttamente, senza avviare stanze.

%% ---------- Tempi di risposta ----------

%% Tempo del client coerente con quello del server: vale quello del client.
client_time_accepted_test() ->
    ?assertEqual({950, false},
                 quizarena_scoring:validated_answer_time(950, 1100, 40, 1000)).

%% La tolleranza e' 1000 ms piu' l'RTT dichiarato.
tolerance_includes_rtt_test() ->
    ?assertEqual({0, false},
                 quizarena_scoring:validated_answer_time(0, 1200, 200, 30000)),
    ?assertEqual({1201, true},
                 quizarena_scoring:validated_answer_time(0, 1201, 200, 30000)).

%% Un RTT gonfiato non allarga la tolleranza oltre 1000 ms.
rtt_is_capped_test() ->
    ?assertEqual({2500, true},
                 quizarena_scoring:validated_answer_time(0, 2500, 5000, 30000)).

%% Il client dichiara un tempo oltre il limite: sospetto, vale il server.
client_time_over_limit_test() ->
    ?assertEqual({1050, true},
                 quizarena_scoring:validated_answer_time(1050, 1050, 0, 1000)).

%% Un tempo del server negativo (orologi) non produce punteggi oltre il massimo.
negative_server_time_test() ->
    ?assertEqual({0, true},
                 quizarena_scoring:validated_answer_time(5000, -10, 0, 30000)).

%% ---------- Punteggio ----------

score_test_() ->
    [?_assertEqual(1000, quizarena_scoring:compute_score(0, 1000)),
     ?_assertEqual(750, quizarena_scoring:compute_score(500, 1000)),
     ?_assertEqual(500, quizarena_scoring:compute_score(1000, 1000)),
     ?_assertEqual(0, quizarena_scoring:compute_score(1001, 1000)),
     ?_assertEqual(1000, quizarena_scoring:compute_score(-5, 1000))].

%% ---------- Classifica ----------

leaderboard_test() ->
    ?assertEqual([{"b", 900}, {"c", 500}, {"a", 0}],
                 quizarena_scoring:leaderboard(
                     [{"a", 0}, {"b", 900}, {"c", 500}])),
    ?assertEqual([], quizarena_scoring:leaderboard([])).
