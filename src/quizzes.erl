-module(quizzes).
-export([all/0, all_extended/0, seed/0, seed_extended/0]).

%% ---------------------------------------------------------------
%% Quiz di seed originali (3)
%% ---------------------------------------------------------------
all() ->
    [
        #{
            owner => "host_user",
            visibility => public,
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
            visibility => public,
            title => "Geografia d'Europa",
            description => "Capitali e fiumi",
            questions => [
                #{text => "Qual è la capitale della Francia?",
                  answers => ["Lione", "Marsiglia", "Parigi", "Nizza"],
                  correct => "Parigi", time_limit => 20000},
                #{text => "Qual è il fiume più lungo d'Europa?",
                  answers => ["Danubio", "Volga", "Reno", "Senna"],
                  correct => "Volga", time_limit => 20000},
                #{text => "Qual è la capitale della Spagna?",
                  answers => ["Barcellona", "Siviglia", "Madrid", "Valencia"],
                  correct => "Madrid", time_limit => 20000}
            ]
        },
        #{
            owner => "alice",
            visibility => public,
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
                  correct => "Central Processing Unit", time_limit => 15000},
                #{text => "Cosa significa HTML?",
                  answers => ["HyperText Markup Language",
                              "High Tech Modern Language",
                              "Home Tool Markup Language",
                              "Hyperlink Text Machine Language"],
                  correct => "HyperText Markup Language", time_limit => 15000}
            ]
        }
    ].

%% ---------------------------------------------------------------
%% Quiz di seed estesi (10 quiz da 3 domande)
%% ---------------------------------------------------------------
all_extended() ->
    [
        #{
            owner => "host_user",
            visibility => public,
            title => "Scienze Naturali",
            description => "Fisica, chimica e biologia di base",
            questions => [
                #{text => "Qual è il simbolo chimico dell'oro?",
                  answers => ["Go", "Au", "Ag", "Or"],
                  correct => "Au", time_limit => 20000},
                #{text => "Qual è l'unità di misura della forza?",
                  answers => ["Joule", "Watt", "Newton", "Pascal"],
                  correct => "Newton", time_limit => 20000},
                #{text => "Quale organo produce l'insulina?",
                  answers => ["Fegato", "Pancreas", "Reni", "Milza"],
                  correct => "Pancreas", time_limit => 20000}
            ]
        },
        #{
            owner => "host_user",
            visibility => public,
            title => "Letteratura Italiana",
            description => "Autori e opere classiche",
            questions => [
                #{text => "Chi ha scritto 'La Divina Commedia'?",
                  answers => ["Petrarca", "Boccaccio", "Dante", "Manzoni"],
                  correct => "Dante", time_limit => 20000},
                #{text => "Chi ha scritto 'I Promessi Sposi'?",
                  answers => ["Leopardi", "Manzoni", "Verga", "Pirandello"],
                  correct => "Manzoni", time_limit => 20000},
                #{text => "In quale secolo è ambientato 'Il Decameron'?",
                  answers => ["XII", "XIII", "XIV", "XV"],
                  correct => "XIV", time_limit => 25000}
            ]
        },
        #{
            owner => "host_user",
            visibility => private,
            title => "Matematica Base",
            description => "Quiz privato di prova",
            questions => [
                #{text => "Quanto fa 7 × 8?",
                  answers => ["54", "56", "58", "62"],
                  correct => "56", time_limit => 15000},
                #{text => "Qual è la radice quadrata di 144?",
                  answers => ["10", "11", "12", "14"],
                  correct => "12", time_limit => 15000},
                #{text => "Quanto vale il numero π approssimato a 2 decimali?",
                  answers => ["3.12", "3.14", "3.16", "3.18"],
                  correct => "3.14", time_limit => 15000}
            ]
        },
        #{
            owner => "alice",
            visibility => public,
            title => "Cinema",
            description => "Film e registi famosi",
            questions => [
                #{text => "Chi ha diretto 'Il Padrino'?",
                  answers => ["Spielberg", "Scorsese", "Coppola", "Tarantino"],
                  correct => "Coppola", time_limit => 20000},
                #{text => "In quale anno è uscito 'Titanic'?",
                  answers => ["1995", "1997", "1999", "2001"],
                  correct => "1997", time_limit => 20000},
                #{text => "Chi interpreta Jack Sparrow?",
                  answers => ["Tom Cruise", "Brad Pitt", "Johnny Depp", "Leo DiCaprio"],
                  correct => "Johnny Depp", time_limit => 20000}
            ]
        },
        #{
            owner => "alice",
            visibility => public,
            title => "Musica",
            description => "Brani e artisti celebri",
            questions => [
                #{text => "Chi ha cantato 'Bohemian Rhapsody'?",
                  answers => ["The Beatles", "Queen", "Pink Floyd", "Led Zeppelin"],
                  correct => "Queen", time_limit => 20000},
                #{text => "Qual è lo strumento principale di Mozart?",
                  answers => ["Violino", "Pianoforte", "Flauto", "Chitarra"],
                  correct => "Pianoforte", time_limit => 20000},
                #{text => "In quale città è nato il rock and roll?",
                  answers => ["New York", "Londra", "Memphis", "Chicago"],
                  correct => "Memphis", time_limit => 25000}
            ]
        },
        #{
            owner => "alice",
            visibility => private,
            title => "Sport",
            description => "Quiz privato di prova",
            questions => [
                #{text => "Quanti giocatori ha una squadra di calcio in campo?",
                  answers => ["9", "10", "11", "12"],
                  correct => "11", time_limit => 15000},
                #{text => "In quale sport si usa il termine 'ace'?",
                  answers => ["Calcio", "Tennis", "Basket", "Rugby"],
                  correct => "Tennis", time_limit => 15000},
                #{text => "Ogni quanti anni si svolgono le Olimpiadi estive?",
                  answers => ["2", "3", "4", "5"],
                  correct => "4", time_limit => 15000}
            ]
        },
        #{
            owner => "bob",
            visibility => public,
            title => "Cucina Italiana",
            description => "Piatti e tradizioni regionali",
            questions => [
                #{text => "Da quale regione viene la pizza margherita?",
                  answers => ["Lazio", "Campania", "Sicilia", "Puglia"],
                  correct => "Campania", time_limit => 20000},
                #{text => "Quale formaggio si usa nel tiramisù?",
                  answers => ["Ricotta", "Mascarpone", "Gorgonzola", "Parmigiano"],
                  correct => "Mascarpone", time_limit => 20000},
                #{text => "Cosa significa 'al dente' nella pasta?",
                  answers => ["Molto cotta", "Poco cotta",
                              "Cotta al punto giusto", "Cruda"],
                  correct => "Cotta al punto giusto", time_limit => 20000}
            ]
        },
        #{
            owner => "bob",
            visibility => public,
            title => "Astronomia",
            description => "Pianeti e stelle",
            questions => [
                #{text => "Qual è il pianeta più vicino al Sole?",
                  answers => ["Venere", "Mercurio", "Terra", "Marte"],
                  correct => "Mercurio", time_limit => 20000},
                #{text => "Quanti pianeti ha il sistema solare?",
                  answers => ["7", "8", "9", "10"],
                  correct => "8", time_limit => 15000},
                #{text => "Come si chiama la nostra galassia?",
                  answers => ["Andromeda", "Via Lattea", "Triangolo", "Orione"],
                  correct => "Via Lattea", time_limit => 20000}
            ]
        },
        #{
            owner => "bob",
            visibility => public,
            title => "Animali",
            description => "Il regno animale in generale",
            questions => [
                #{text => "Qual è l'animale terrestre più veloce?",
                  answers => ["Leone", "Ghepardo", "Cavallo", "Antilope"],
                  correct => "Ghepardo", time_limit => 20000},
                #{text => "Quante zampe ha un ragno?",
                  answers => ["6", "8", "10", "12"],
                  correct => "8", time_limit => 15000},
                #{text => "Qual è il mammifero più grande del mondo?",
                  answers => ["Elefante africano", "Balena azzurra",
                              "Giraffa", "Ippopotamo"],
                  correct => "Balena azzurra", time_limit => 20000}
            ]
        },
        #{
            owner => "bob",
            visibility => public,
            title => "Tecnologia",
            description => "Concetti informatici moderni",
            questions => [
                #{text => "Cosa significa 'Wi-Fi'?",
                  answers => ["Wireless Fidelity", "Wide Field",
                              "Wire Fire", "Wireless Find"],
                  correct => "Wireless Fidelity", time_limit => 20000},
                #{text => "Chi ha fondato Apple insieme a Wozniak?",
                  answers => ["Bill Gates", "Steve Jobs",
                              "Linus Torvalds", "Mark Zuckerberg"],
                  correct => "Steve Jobs", time_limit => 20000},
                #{text => "Cosa fa il protocollo HTTP?",
                  answers => ["Trasferisce file", "Trasferisce ipertesti",
                              "Cripta messaggi", "Gestisce email"],
                  correct => "Trasferisce ipertesti", time_limit => 20000}
            ]
        }
    ].

%% ---------------------------------------------------------------
%% Popolamento Mnesia
%% ---------------------------------------------------------------

%% Inserisce i 3 quiz base
seed() ->
    do_seed(all()).

%% Inserisce i 3 quiz base + i 10 estesi = 13 quiz totali
seed_extended() ->
    do_seed(all() ++ all_extended()).

do_seed(QuizList) ->
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
    end, QuizList),
    Inserted = length([ok || {ok, _} <- Results]),
    io:format("Seeded ~p quizzes.~n", [Inserted]),
    ok.