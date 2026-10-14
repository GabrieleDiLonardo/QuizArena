-module(quizarena_cluster_tests).
-export([start_quizarena/0]).
-include_lib("eunit/include/eunit.hrl").

%% Test di cluster: tre nodi Erlang reali (avviati con il modulo peer)
%% eseguono l'applicazione, ognuno con la propria directory Mnesia.

-define(COOKIE, "quizarena_cluster_test").
-define(PEERS, quizarena_cluster_test_peers).

cluster_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(Ctx) ->
         {inorder, [
             {timeout, 120, fun() -> bootstrap_in_any_order(Ctx) end},
             {timeout, 60, fun() -> data_is_replicated(Ctx) end},
             {timeout, 120, fun() -> crashed_node_rejoins(Ctx) end},
             {timeout, 60, fun() -> highest_node_is_leader(Ctx) end},
             {timeout, 120, fun() -> room_survives_node_crash(Ctx) end},
             {timeout, 120, fun() -> new_leader_after_leader_crash(Ctx) end}
         ]}
     end}.

setup() ->
    {ok, Host} = inet:gethostname(),
    Names = [list_to_atom(N ++ "@" ++ Host) || N <- ["qat1", "qat2", "qat3"]],
    Base = filename:join(filename:basedir(user_cache, "quizarena_cluster_tests"),
                         integer_to_list(os:system_time(microsecond))),
    Ctx = #{names => Names, base => Base,
            peers => ets:new(?PEERS, [named_table, public])},
    Ctx.

cleanup(#{peers := Peers, base := Base}) ->
    [catch peer:stop(Pid) || {_Node, Pid} <- ets:tab2list(Peers)],
    file:del_dir_r(Base).

%% ---------- Scenari ----------

%% Il nodo non seed parte per primo e attende il seed; poi parte il seed
%% e infine il terzo nodo: tutti finiscono nello stesso schema.
bootstrap_in_any_order(#{names := [N1, N2, N3]} = Ctx) ->
    Waiting = start_app_async(Ctx, N3),
    timer:sleep(3000),
    ok = start_app(Ctx, N1),
    ok = await(Waiting),
    ok = start_app(Ctx, N2),
    Running = lists:sort(call(N1, mnesia, system_info, [running_db_nodes])),
    ?assertEqual(lists:sort([N1, N2, N3]), Running),
    [?assertEqual(lists:sort([N1, N2, N3]),
                  lists:sort(call(N, mnesia, table_info, [users, disc_copies])))
     || N <- [N1, N2, N3]],
    ?assertEqual(lists:sort([N1, N2, N3]),
                 lists:sort(call(N2, mnesia, table_info,
                                 [open_rooms, ram_copies]))).

data_is_replicated(#{names := [N1, N2, N3]}) ->
    ok = call(N3, quizarena_db, create_user, ["replica_user", #{k => v}]),
    ?assertEqual({ok, #{k => v}},
                 call(N1, quizarena_db, get_user, ["replica_user"])),
    ?assertEqual({ok, #{k => v}},
                 call(N2, quizarena_db, get_user, ["replica_user"])).

%% Il seed cade; mentre e' giu' gli altri nodi continuano a scrivere.
%% Al riavvio rientra nello schema e vede le scritture perse.
crashed_node_rejoins(#{names := [N1, N2, _N3]} = Ctx) ->
    stop_node(Ctx, N1),
    ok = call(N2, quizarena_db, create_user, ["written_while_down", #{}]),
    ok = start_app(Ctx, N1),
    ?assertEqual({ok, #{}},
                 call(N1, quizarena_db, get_user, ["written_while_down"])).

%% Bully: tutti i nodi riconoscono come leader quello con UID piu' alto.
highest_node_is_leader(#{names := [N1, N2, N3]}) ->
    wait_until(fun() ->
        [call(N, quizarena_election, leader, []) || N <- [N1, N2, N3]]
            =:= [N3, N3, N3]
    end).

%% La partita e' ospitata da N2, i client stanno su N1 (come un Tomcat su
%% una macchina che resta attiva). N2 cade a round aperto: il leader N3
%% ripristina la stanza e la partita prosegue con stato e punteggi intatti.
room_survives_node_crash(#{names := [N1, N2, N3]} = Ctx) ->
    {ok, QuizId} = call(N1, quizarena_db, create_quiz, ["host1", #{
        title => "Quiz cluster", description => "", visibility => public,
        questions => [
            #{text => "Q1", answers => ["a", "b"], correct => "a",
              time_limit => 8000},
            #{text => "Q2", answers => ["a", "b"], correct => "b",
              time_limit => 8000}
        ]}]),
    [ok = call(N1, quizarena_test_client, start, [C]) || C <- [host, p1, p2]],
    Req = fun(Client, Gateway, Request) ->
        call(N1, quizarena_test_client, request, [Client, Gateway, Request])
    end,

    {ok, Pin} = Req(host, N2, {create_room, QuizId, "host1", public}),
    ?assertEqual(N2, room_node(N1, Pin)),
    {ok, ok} = Req(p1, N1, {join, Pin, "p1"}),
    {ok, ok} = Req(p2, N1, {join, Pin, "p2"}),
    {ok, ok} = Req(host, N1, {start_game, Pin}),
    {ok, ok} = Req(host, N1, {next_round, Pin}),
    {ok, ok} = Req(p1, N1, {answer, Pin, 1, "a", 500, 40}),

    stop_node(Ctx, N2),
    wait_until(fun() -> room_node(N1, Pin) =:= N3 end),

    %% Lo stato e' quello di prima della caduta: round aperto, p1 ha gia'
    %% risposto, p2 no.
    {ok, #{status := round_open, current_round := 1, answered := true}} =
        Req(p1, N1, {get_player_state, Pin, "p1"}),
    {ok, #{answered := false}} = Req(p2, N1, {get_player_state, Pin, "p2"}),

    %% Gli eventi continuano ad arrivare ai client e la numerazione prosegue.
    {ok, ok} = Req(p2, N1, {answer, Pin, 1, "b", 700, 40}),
    wait_until(fun() -> has_event(N1, p1, round_closed) end),
    #{leaderboard := [{"p1", 969}, {"p2", 0}]} = last_event(N1, p1, round_closed),
    ?assert(has_event(N1, p1, room_recovered)),
    Seqs = [maps:get(seq, E) || E <- call(N1, quizarena_test_client, events, [p1])],
    ?assertEqual(lists:usort(Seqs), Seqs),

    %% L'host, che era su N1, continua a comandare la partita.
    {ok, ok} = Req(host, N1, {next_round, Pin}),
    {ok, ok} = Req(host, N1, {end_game, Pin}),
    wait_until(fun() -> has_event(N1, p1, game_finished) end),
    [#{score := 969}] = [E || #{quiz_title := "Quiz cluster"} = E
                                  <- call(N1, quizarena_db, get_history, ["p1"])],
    ?assertEqual([], call(N1, quizarena_db, list_snapshots, [])).

%% N2 rientra; poi cade il leader N3 e i superstiti eleggono N2.
new_leader_after_leader_crash(#{names := [N1, N2, N3]} = Ctx) ->
    ok = start_app(Ctx, N2),
    wait_until(fun() ->
        [call(N, quizarena_election, leader, []) || N <- [N1, N2, N3]]
            =:= [N3, N3, N3]
    end),
    stop_node(Ctx, N3),
    wait_until(fun() ->
        [call(N, quizarena_election, leader, []) || N <- [N1, N2]]
            =:= [N2, N2]
    end).

%% ---------- Supporto agli scenari ----------

room_node(Via, Pin) ->
    case call(Via, global, whereis_name, [{room, Pin}]) of
        Pid when is_pid(Pid) -> node(Pid);
        undefined -> undefined
    end.

has_event(Node, Client, Type) ->
    lists:any(fun(#{type := T}) -> T =:= Type end,
              call(Node, quizarena_test_client, events, [Client])).

last_event(Node, Client, Type) ->
    lists:last([E || #{type := T} = E
                         <- call(Node, quizarena_test_client, events, [Client]),
                     T =:= Type]).

wait_until(Fun) ->
    wait_until(Fun, 100).

wait_until(Fun, 0) ->
    ?assert(Fun());
wait_until(Fun, Attempts) ->
    case catch Fun() of
        true -> ok;
        _ -> timer:sleep(250), wait_until(Fun, Attempts - 1)
    end.

%% ---------- Gestione dei nodi ----------

start_node(#{names := Names, base := Base, peers := Peers}, Node) ->
    [Short, _Host] = string:split(atom_to_list(Node), "@"),
    ClusterEnv = lists:join(",", [atom_to_list(N) || N <- Names]),
    {ok, Pid, Node} = peer:start(#{
        name => list_to_atom(Short),
        connection => 0,
        args => ["-setcookie", ?COOKIE,
                 "-kernel", "net_ticktime", "8"
                 | lists:append([["-pa", P] || P <- code:get_path(),
                                                  is_project_path(P)])],
        env => [{"QUIZARENA_CLUSTER_NODES", lists:flatten(ClusterEnv)}]
    }),
    ets:insert(Peers, {Node, Pid}),
    Dir = filename:join(Base, Short),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    %% I log dei nodi restano consultabili dopo il test.
    LogFile = filename:join(log_dir(), Short ++ ".log"),
    ok = filelib:ensure_dir(LogFile),
    ok = peer:call(Pid, logger, add_handler,
                   [file_log, logger_std_h,
                    #{config => #{file => LogFile}}]),
    ok = peer:call(Pid, application, set_env, [mnesia, dir, Dir]),
    ok = peer:call(Pid, application, set_env, [quizarena, host_grace_ms, 500]),
    Pid.

start_app(Ctx, Node) ->
    Pid = start_node(Ctx, Node),
    {ok, _} = peer:call(Pid, ?MODULE, start_quizarena, [], 120000),
    ok.

%% Eseguita sul nodo peer: l'applicazione viene avviata da un processo con
%% il group leader permanente del nodo, come in una release, e non da quello
%% temporaneo di peer:call.
start_quizarena() ->
    group_leader(whereis(user), self()),
    application:ensure_all_started(quizarena).

start_app_async(Ctx, Node) ->
    Self = self(),
    Ref = make_ref(),
    spawn_link(fun() -> Self ! {Ref, start_app(Ctx, Node)} end),
    Ref.

await(Ref) ->
    receive {Ref, Result} -> Result after 120000 -> error(timeout) end.

stop_node(#{peers := Peers}, Node) ->
    [{Node, Pid}] = ets:lookup(Peers, Node),
    peer:stop(Pid),
    ets:delete(Peers, Node),
    ok.

call(Node, M, F, A) ->
    call(Node, M, F, A, 30000).

call(Node, M, F, A, Timeout) ->
    [{Node, Pid}] = ets:lookup(?PEERS, Node),
    peer:call(Pid, M, F, A, Timeout).

log_dir() ->
    filename:basedir(user_cache, "quizarena_cluster_tests_logs").

is_project_path(Path) ->
    string:find(Path, "_build") =/= nomatch.
