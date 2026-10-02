-module(quizzes).
-export([all/0, seed/0]).

%% Lista dei quiz di seed
all() ->
    [
        #{
            owner => "host_user",
            title => "Storia del Novecento",
            description => "Eventi principali del XX secolo",
            questions => [
                #{text => "In che anno è caduto il muro di Berlino?",
                  answers => ["1987", "1989", "1991", "1993"],
                  correct => "1989", time_limit => 30000},
                #{text => "Chi era il presidente USA nel 1963?",
                  answers => ["Eisenhower", "Kennedy", "Johnson", "Nixon"],
                  correct => "Kennedy", time_limit => 30000},
                #{text => "In che anno è iniziata la Prima Guerra Mondiale?",
                  answers => ["1912", "1914", "1916", "1918"],
                  correct => "1914", time_limit => 30000}
            ]
        },
        #{
            owner => "host_user",
            title => "Geografia d'Europa",
            description => "Capitali e fiumi",
            questions => [
                #{text => "Qual è la capitale della Francia?",
                  answers => ["Lione", "Marsiglia", "Parigi", "Nizza"],
                  correct => "Parigi", time_limit => 20000},
                #{text => "Qual è il fiume più lungo d'Europa?",
                  answers => ["Danubio", "Volga", "Reno", "Senna"],
                  correct => "Volga", time_limit => 20000}
            ]
        },
        #{
            owner => "alice",
            title => "Informatica Base",
            description => "Concetti fondamentali",
            questions => [
                #{text => "Cos'è la RAM?",
                  answers => ["Memoria volatile", "Disco rigido",
                              "Processore", "Rete"],
                  correct => "Memoria volatile", time_limit => 15000},
                #{text => "Cosa significa CPU?",
                  answers => ["Central Processing Unit",
                              "Computer Personal Unit",
                              "Central Program Utility",
                              "Control Panel Unit"],
                  correct => "Central Processing Unit", time_limit => 15000}
            ]
        }
    ].

%% Inserisce tutti i quiz in Mnesia
seed() ->
    Results = lists:map(fun(Q) ->
        Owner = maps:get(owner, Q),
        case quizarena_db:create_quiz(Owner, Q) of
            {ok, Id} ->
                io:format("  + [~p] ~s (owner: ~s, ~p domande)~n",
                          [Id, maps:get(title, Q), Owner,
                           length(maps:get(questions, Q))]),
                {ok, Id};
            {error, R} ->
                io:format("  ! Failed: ~p (~p)~n", [maps:get(title, Q), R]),
                {error, R}
        end
    end, all()),
    Inserted = length([ok || {ok, _} <- Results]),
    io:format("Seeded ~p quizzes.~n", [Inserted]),
    ok.