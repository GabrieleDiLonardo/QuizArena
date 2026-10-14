-module(quizarena_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    ok = quizarena_cluster:connect(),
    ok = quizarena_db:init(),
    quizarena_sup:start_link().

%% Mnesia e' una dipendenza dell'applicazione: viene fermata da chi ferma
%% il sistema. Chiamare mnesia:stop() qui causerebbe un deadlock con
%% l'application controller, impegnato a fermare quizarena.
stop(_State) ->
    ok.