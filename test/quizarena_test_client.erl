-module(quizarena_test_client).

%% Client di test eseguito su un nodo del cluster, al posto di una mailbox
%% Jinterface: invia richieste al gateway di un nodo a scelta e registra
%% gli eventi ricevuti dalle room.

-export([start/1, request/3, events/1, stop/1]).

%% Come la mailbox Java, il client sopravvive all'uscita della room a cui
%% e' linkato (es. caduta del nodo che la ospita).
start(Name) ->
    Pid = spawn(fun() -> process_flag(trap_exit, true), loop([]) end),
    true = register(Name, Pid),
    ok.

request(Name, GatewayNode, Request) ->
    Tag = make_ref(),
    Name ! {request, GatewayNode, Request, self(), Tag},
    receive {Tag, Result} -> Result after 10000 -> {error, no_reply} end.

events(Name) ->
    Tag = make_ref(),
    Name ! {events, self(), Tag},
    receive {Tag, Events} -> Events after 5000 -> error(no_reply) end.

stop(Name) ->
    Name ! stop,
    ok.

loop(Events) ->
    receive
        {request, GatewayNode, Request, From, Tag} ->
            Ref = make_ref(),
            {quizarena_gateway, GatewayNode} ! {self(), Ref, Request},
            Result = receive {Ref, R} -> R after 8000 -> no_reply end,
            From ! {Tag, Result},
            loop(Events);
        {events, From, Tag} ->
            From ! {Tag, lists:reverse(Events)},
            loop(Events);
        {event, Event} ->
            loop([Event | Events]);
        {'EXIT', _Room, _Reason} ->
            loop(Events);
        stop ->
            ok
    end.
