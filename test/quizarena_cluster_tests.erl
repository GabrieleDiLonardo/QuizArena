-module(quizarena_cluster_tests).
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
             {timeout, 120, fun() -> crashed_node_rejoins(Ctx) end}
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
    ok = peer:call(Pid, application, set_env, [mnesia, dir, Dir]),
    ok = peer:call(Pid, application, set_env, [quizarena, host_grace_ms, 500]),
    Pid.

start_app(Ctx, Node) ->
    Pid = start_node(Ctx, Node),
    {ok, _} = peer:call(Pid, application, ensure_all_started, [quizarena],
                        120000),
    ok.

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

is_project_path(Path) ->
    string:find(Path, "_build") =/= nomatch.
