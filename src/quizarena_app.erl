-module(quizarena_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    ok = quizarena_cluster:connect(),   %% collega gli altri nodi
    ok = quizarena_db:init(),           %% prepara Mnesia
    quizarena_sup:start_link().         %% avvia i processi 

stop(_State) ->
    ok.