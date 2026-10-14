-module(quizarena_cluster).

-export([members/0, others/0, seed/0, connect/0]).

%% Composizione del cluster. L'ordine della lista e' significativo:
%% il primo nodo e' il seed che crea lo schema Mnesia al primo avvio, e la
%% posizione di un nodo e' il suo identificatore nell'elezione Bully.
%%
%% Fonte, in ordine di priorita':
%%   1. variabile d'ambiente QUIZARENA_CLUSTER_NODES (nodi separati da virgola)
%%   2. parametro cluster_nodes dell'applicazione (sys.config)
%% Il nodo locale viene aggiunto in coda se non compare nella lista.
members() ->
    Configured = case os:getenv("QUIZARENA_CLUSTER_NODES") of
        false -> application:get_env(quizarena, cluster_nodes, []);
        Value -> parse_nodes(Value)
    end,
    case lists:member(node(), Configured) of
        true -> Configured;
        false -> Configured ++ [node()]
    end.

others() ->
    members() -- [node()].

seed() ->
    hd(members()).

%% Stabilisce la connessione con gli altri nodi configurati; quelli non
%% ancora avviati si collegheranno a loro volta quando partiranno.
connect() ->
    [net_adm:ping(Node) || Node <- others()],
    ok.

parse_nodes(Value) ->
    [list_to_atom(Name)
     || Token <- string:split(Value, ",", all),
        Name <- [string:trim(Token)],
        Name =/= ""].
