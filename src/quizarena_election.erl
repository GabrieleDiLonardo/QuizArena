-module(quizarena_election).
-behaviour(gen_server).

%% Elezione del leader con l'algoritmo Bully e ripristino delle stanze.
%%
%% Ogni nodo del cluster esegue questo processo. L'identificatore (UID) di
%% un nodo e' la sua posizione nella lista quizarena_cluster:members(): vince
%% il nodo attivo con UID piu' alto. Messaggi, come nelle slide del corso:
%%   {election, From}  annuncia un'elezione ai nodi con UID piu' alto
%%   {answer, From}    "non sarai tu il leader": risposta di un nodo piu' alto
%%   {leader, Node}    annuncio del nuovo leader ai nodi con UID piu' basso
%% Il sistema si assume sincrono: un nodo che non risponde entro il timeout
%% e' considerato guasto. I guasti sono rilevati dalla distribuzione Erlang
%% (net_kernel:monitor_nodes), che si basa a sua volta su un timeout
%% (net_ticktime).
%%
%% Il leader ripristina le stanze orfane: quelle che hanno uno snapshot ma
%% nessun processo registrato (nodo caduto o processo terminato per errore).

-export([start_link/0, leader/0, recover_orphans/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% T: attesa delle risposte ANSWER dopo l'invio di ELECTION.
-define(ANSWER_TIMEOUT_MS, 1000).
%% T': attesa del messaggio LEADER dopo aver ricevuto un ANSWER.
-define(LEADER_TIMEOUT_MS, 3000).
%% Controllo periodico delle stanze orfane eseguito dal leader.
-define(RECOVERY_PERIOD_MS, 5000).
%% Oltre questo numero di ripristini una stanza viene annullata.
-define(MAX_RECOVERIES, 3).

%% ---------- API ----------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

leader() ->
    gen_server:call(?MODULE, leader).

%% ---------- Callback ----------

init([]) ->
    ok = net_kernel:monitor_nodes(true),
    self() ! start_election,
    erlang:send_after(?RECOVERY_PERIOD_MS, self(), recovery_tick),
    {ok, #{leader => undefined, phase => idle, timer => undefined}}.

handle_call(leader, _From, State) ->
    {reply, maps:get(leader, State), State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(start_election, State) ->
    {noreply, start_election(State)};

%% Un nodo con UID piu' basso avvia un'elezione: gli si risponde e, se non
%% e' gia' in corso, si avvia la propria.
handle_info({election, From}, State) ->
    send(From, {answer, node()}),
    case maps:get(phase, State) of
        idle -> {noreply, start_election(State)};
        _ -> {noreply, State}
    end;

%% Un nodo piu' alto e' vivo: sara' lui (o uno ancora piu' alto) a
%% proclamarsi leader. Si attende il suo annuncio per al massimo T'.
handle_info({answer, _From}, #{phase := waiting_answers} = State) ->
    {noreply, set_timer(State#{phase => waiting_leader},
                        ?LEADER_TIMEOUT_MS, leader_timeout)};
handle_info({answer, _From}, State) ->
    {noreply, State};

handle_info({leader, Node}, State) ->
    case uid(Node) < uid(node()) of
        true ->
            %% Un nodo piu' basso si e' proclamato leader (es. questo nodo
            %% e' appena rientrato): si rivendica la leadership.
            {noreply, start_election(State)};
        false ->
            logger:notice("[election] ~p: leader is ~p", [node(), Node]),
            {noreply, cancel_timer(State#{leader => Node, phase => idle})}
    end;

%% Nessuna risposta entro T dai nodi piu' alti: questo nodo e' il leader.
handle_info({timeout, Ref, answer_timeout},
            #{phase := waiting_answers, timer := Ref} = State) ->
    {noreply, become_leader(State)};

%% Annunciato un ANSWER ma nessun LEADER entro T': nuova elezione.
handle_info({timeout, Ref, leader_timeout},
            #{phase := waiting_leader, timer := Ref} = State) ->
    {noreply, start_election(State)};

handle_info({timeout, _Ref, _Stale}, State) ->
    {noreply, State};

handle_info({nodedown, Node}, State) ->
    case is_member(Node) of
        false ->
            {noreply, State};
        true ->
            logger:notice("[election] ~p: node ~p is down", [node(), Node]),
            case maps:get(leader, State) of
                Node ->
                    {noreply, start_election(State#{leader => undefined})};
                Leader when Leader =:= node() ->
                    recover_orphans(),
                    {noreply, State};
                _ ->
                    {noreply, State}
            end
    end;

%% Un nodo appena collegato viene informato del leader corrente.
handle_info({nodeup, Node}, State) ->
    case is_member(Node) andalso maps:get(leader, State) =:= node() of
        true -> send(Node, {leader, node()});
        false -> ok
    end,
    {noreply, State};

handle_info(recovery_tick, State) ->
    case maps:get(leader, State) =:= node() of
        true -> recover_orphans();
        false -> ok
    end,
    erlang:send_after(?RECOVERY_PERIOD_MS, self(), recovery_tick),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

%% ---------- Bully ----------

start_election(State) ->
    case higher_nodes() of
        [] ->
            become_leader(State);
        Higher ->
            [send(Node, {election, node()}) || Node <- Higher],
            set_timer(State#{phase => waiting_answers},
                      ?ANSWER_TIMEOUT_MS, answer_timeout)
    end.

become_leader(State) ->
    logger:notice("[election] ~p: elected leader", [node()]),
    [send(Node, {leader, node()}) || Node <- lower_nodes()],
    recover_orphans(),
    cancel_timer(State#{leader => node(), phase => idle}).

uid(Node) ->
    index_of(Node, quizarena_cluster:members(), 1).

index_of(_Node, [], _Index) -> 0;
index_of(Node, [Node | _], Index) -> Index;
index_of(Node, [_ | Rest], Index) -> index_of(Node, Rest, Index + 1).

higher_nodes() ->
    [N || N <- quizarena_cluster:others(), uid(N) > uid(node())].

lower_nodes() ->
    [N || N <- quizarena_cluster:others(), uid(N) < uid(node())].

is_member(Node) ->
    lists:member(Node, quizarena_cluster:members()).

%% Invio asincrono senza tentare nuove connessioni: un nodo non connesso e'
%% considerato guasto, e il suo silenzio fa scattare il timeout.
send(Node, Message) ->
    _ = erlang:send({?MODULE, Node}, Message, [noconnect]),
    ok.

set_timer(State, Timeout, Tag) ->
    State1 = cancel_timer(State),
    State1#{timer => erlang:start_timer(Timeout, self(), Tag)}.

cancel_timer(#{timer := undefined} = State) ->
    State;
cancel_timer(#{timer := Ref} = State) ->
    _ = erlang:cancel_timer(Ref),
    State#{timer => undefined}.

%% ---------- Ripristino delle stanze ----------

%% Una stanza e' orfana se ha uno snapshot ma nessun processo registrato:
%% la room registra il proprio nome prima di scrivere lo snapshot e lo
%% cancella prima di terminare normalmente, quindi la condizione indica un
%% nodo caduto o un processo terminato per errore.
recover_orphans() ->
    _ = global:sync(),
    [recover(Pin, Snapshot)
     || {Pin, _OwnerNode, Snapshot} <- quizarena_db:list_snapshots(),
        global:whereis_name({room, Pin}) =:= undefined],
    ok.

recover(Pin, Snapshot) ->
    case maps:get(recover_count, Snapshot, 0) >= ?MAX_RECOVERIES of
        true ->
            abandon(Pin, Snapshot, too_many_recoveries);
        false ->
            case room_sup:start_room(#{recover => Snapshot}) of
                {ok, _Pid} ->
                    logger:notice("[election] room ~s recovered on ~p",
                              [Pin, node()]);
                {error, {room_already_registered, Pin}} ->
                    ok;
                {error, Reason} ->
                    abandon(Pin, Snapshot, Reason)
            end
    end.

abandon(Pin, Snapshot, Reason) ->
    logger:notice("[election] room ~s cannot be recovered: ~p", [Pin, Reason]),
    _ = quizarena_db:cancel_session(maps:get(session_id, Snapshot)),
    quizarena_db:unpublish_room(Pin),
    quizarena_db:delete_snapshot(Pin).
