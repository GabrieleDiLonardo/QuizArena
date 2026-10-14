-module(quizarena_room_tests).
-include_lib("eunit/include/eunit.hrl").

%% Scenari di gioco eseguiti attraverso il gateway, come farebbe il web
%% tier. Ogni client e' un processo Erlang che si comporta come una
%% mailbox Jinterface: riceve le risposte {Ref, Result} e gli eventi
%% {event, Evento}; quando termina, la room riceve un 'EXIT' dal link.

-define(HOST, "host1").

%% ---------- Fixture ----------

room_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(QuizIds) ->
         {inorder, [
             {timeout, 30, fun() -> full_game(QuizIds) end},
             {timeout, 30, fun() -> host_cannot_join_own_room(QuizIds) end},
             {timeout, 30, fun() -> player_leaves_while_waiting(QuizIds) end},
             {timeout, 30, fun() -> player_disconnect_closes_round(QuizIds) end},
             {timeout, 30, fun() -> host_rejoins_during_game(QuizIds) end},
             {timeout, 30, fun() -> host_grace_expires_cancels(QuizIds) end},
             {timeout, 30, fun() -> host_grace_after_last_round_saves(QuizIds) end},
             {timeout, 30, fun() -> concurrent_room_creation(QuizIds) end},
             {timeout, 30, fun() -> orphan_sessions_are_swept(QuizIds) end}
         ]}
     end}.

setup() ->
    Dir = filename:join(filename:basedir(user_cache, "quizarena_tests"),
                        integer_to_list(os:system_time(microsecond))),
    _ = file:del_dir_r(Dir),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    application:set_env(mnesia, dir, Dir),
    application:set_env(quizarena, host_grace_ms, 500),
    {ok, _} = application:ensure_all_started(quizarena),
    {ok, TwoRounds} = quizarena_db:create_quiz(?HOST, #{
        title => "Quiz di prova",
        description => "due domande",
        visibility => public,
        questions => [
            #{text => "Q1", answers => ["a", "b"], correct => "a",
              time_limit => 2000},
            #{text => "Q2", answers => ["a", "b"], correct => "b",
              time_limit => 1500}
        ]}),
    {ok, OneRound} = quizarena_db:create_quiz(?HOST, #{
        title => "Quiz breve",
        description => "una domanda",
        visibility => public,
        questions => [
            #{text => "Q1", answers => ["a", "b"], correct => "a",
              time_limit => 2000}
        ]}),
    #{two => TwoRounds, one => OneRound, dir => Dir}.

cleanup(#{dir := Dir}) ->
    application:stop(quizarena),
    application:stop(mnesia),
    file:del_dir_r(Dir).

%% ---------- Scenari ----------

full_game(#{two := QuizId}) ->
    H = client(),
    {ok, Pin} = req(H, {create_room, QuizId, ?HOST, public}),
    Room = find_room(Pin),
    ?assertEqual("Quiz di prova", maps:get(quiz_title, Room)),
    ?assertEqual(?HOST, maps:get(host, Room)),
    ?assertEqual(waiting, maps:get(status, Room)),

    P1 = client(), P2 = client(),
    ?assertEqual({ok, ok}, req(P1, {join, Pin, "p1"})),
    ?assertEqual({ok, ok}, req(P2, {join, Pin, "p2"})),
    ?assertEqual({error, already_joined}, req(client(), {join, Pin, "p1"})),
    ?assertEqual(2, maps:get(num_players, find_room(Pin))),

    %% Solo l'host comanda la partita.
    ?assertEqual({error, not_host}, req(P1, {start_game, Pin})),
    ?assertEqual({ok, ok}, req(H, {start_game, Pin})),
    ?assertEqual({ok, ok}, req(H, {next_round, Pin})),
    #{question := Q} = expect_event(P1, round_started),
    ?assertNot(maps:is_key(correct, Q)),

    %% Tutti hanno risposto: il round si chiude subito.
    ?assertEqual({ok, ok}, req(P1, {answer, Pin, 1, "a", 100, 40})),
    ?assertEqual({error, already_answered},
                 req(P1, {answer, Pin, 1, "b", 150, 40})),
    ?assertEqual({ok, ok}, req(P2, {answer, Pin, 1, "b", 100, 40})),
    #{leaderboard := [{"p1", Score1}, {"p2", 0}], has_next_round := true} =
        expect_event(H, round_closed),
    ?assertEqual(950, Score1),
    ?assertEqual({error, round_not_open},
                 req(P2, {answer, Pin, 1, "a", 100, 40})),

    %% Nessuno risponde: il round si chiude per timeout.
    ?assertEqual({ok, ok}, req(H, {next_round, Pin})),
    #{has_next_round := false} =
        expect_event(P2, round_closed, #{round => 2}, 3000),

    ?assertEqual({ok, ok}, req(H, {end_game, Pin})),
    #{final_leaderboard := [{"p1", 950}, {"p2", 0}]} =
        expect_event(P1, game_finished),
    wait_until(fun() -> not room_listed(Pin) end),
    ?assertEqual({error, room_not_found}, req(H, {next_round, Pin})),

    [#{rank := 1, score := 950}] =
        [E || #{quiz_title := "Quiz di prova"} = E
                  <- quizarena_db:get_history("p1")],
    stop_all([H, P1, P2]).

host_cannot_join_own_room(#{two := QuizId}) ->
    H = client(),
    {ok, Pin} = req(H, {create_room, QuizId, ?HOST, private}),
    ?assertEqual({error, host_cannot_play}, req(client(), {join, Pin, ?HOST})),
    %% Le stanze private non compaiono nella lobby.
    ?assertNot(room_listed(Pin)),
    ?assertEqual({ok, ok}, req(H, {cancel_room, Pin})),
    stop_all([H]).

player_leaves_while_waiting(#{two := QuizId}) ->
    H = client(),
    {ok, Pin} = req(H, {create_room, QuizId, ?HOST, public}),
    P1 = client(),
    ?assertEqual({ok, ok}, req(P1, {join, Pin, "p1"})),
    P1 ! stop,
    #{username := "p1"} = expect_event(H, player_disconnected),
    ?assertEqual(0, maps:get(num_players, find_room(Pin))),
    ?assertEqual({error, no_players}, req(H, {start_game, Pin})),

    %% Rientrare in attesa equivale a un nuovo ingresso.
    P1b = client(),
    ?assertEqual({ok, ok}, req(P1b, {rejoin, Pin, "p1"})),
    ?assertEqual({ok, ok}, req(H, {cancel_room, Pin})),
    #{reason := host_left} = expect_event(P1b, game_cancelled),
    stop_all([H, P1b]).

player_disconnect_closes_round(#{two := QuizId}) ->
    {H, Pin, [P1, P2]} = started_game(QuizId, ["p1", "p2"]),
    ?assertEqual({ok, ok}, req(H, {next_round, Pin})),
    ?assertEqual({ok, ok}, req(P1, {answer, Pin, 1, "a", 100, 40})),
    %% P2 cade: non deve trattenere gli altri fino al timeout (2000 ms).
    P2 ! stop,
    expect_event(P1, round_closed, 1000),

    %% P2 rientra a partita in corso e ritrova punteggio e stato.
    P2b = client(),
    ?assertEqual({ok, ok}, req(P2b, {rejoin, Pin, "p2"})),
    {ok, #{status := round_closed, score := 0}} =
        req(P2b, {get_player_state, Pin, "p2"}),
    ?assertEqual({ok, ok}, req(H, {cancel_room, Pin})),
    stop_all([H, P1, P2b]).

host_rejoins_during_game(#{two := QuizId}) ->
    application:set_env(quizarena, host_grace_ms, 5000),
    {H, Pin, [P1]} = started_game(QuizId, ["p1"]),
    ?assertEqual({ok, ok}, req(H, {next_round, Pin})),
    H ! stop,
    expect_event(P1, host_disconnected),

    %% Il round prosegue anche senza host.
    ?assertEqual({ok, ok}, req(P1, {answer, Pin, 1, "a", 100, 40})),
    expect_event(P1, round_closed),

    ?assertEqual({error, not_host}, req(client(), {host_rejoin, Pin, "p1"})),
    H2 = client(),
    {ok, State} = req(H2, {host_rejoin, Pin, ?HOST}),
    ?assertMatch(#{status := round_closed, current_round := 1,
                   players := ["p1"], has_next_round := true}, State),
    expect_event(P1, host_rejoined),

    %% Il nuovo host comanda la partita; il periodo di grazia e' annullato.
    ?assertEqual({ok, ok}, req(H2, {next_round, Pin})),
    expect_event(P1, round_started),
    timer:sleep(200),
    ?assert(room_listed(Pin)),
    ?assertEqual({ok, ok}, req(H2, {end_game, Pin})),
    expect_event(P1, game_finished),
    application:set_env(quizarena, host_grace_ms, 500),
    stop_all([H2, P1]).

host_grace_expires_cancels(#{two := QuizId}) ->
    {H, Pin, [P1]} = started_game(QuizId, ["p1"]),
    H ! stop,
    #{grace_ms := 500} = expect_event(P1, host_disconnected),
    #{reason := host_disconnected} = expect_event(P1, game_cancelled, 2000),
    wait_until(fun() -> not room_listed(Pin) end),
    ?assertEqual([], mnesia:dirty_read(session_pins, Pin)),
    stop_all([P1]).

host_grace_after_last_round_saves(#{one := QuizId}) ->
    {H, Pin, [P1]} = started_game(QuizId, ["p9"]),
    ?assertEqual({ok, ok}, req(H, {next_round, Pin})),
    ?assertEqual({ok, ok}, req(P1, {answer, Pin, 1, "a", 0, 40})),
    #{has_next_round := false} = expect_event(P1, round_closed),
    H ! stop,
    #{final_leaderboard := [{"p9", 1000}]} =
        expect_event(P1, game_finished, 2000),
    [#{score := 1000}] = quizarena_db:get_history("p9"),
    stop_all([P1]).

%% Molti host aprono stanze nello stesso istante: ogni PIN deve essere
%% assegnato una sola volta.
concurrent_room_creation(#{two := QuizId}) ->
    N = 40,
    Hosts = [client() || _ <- lists:seq(1, N)],
    Self = self(),
    [spawn(fun() ->
         Self ! {created, req(Host, {create_room, QuizId, ?HOST, private})}
     end) || Host <- Hosts],
    Pins = [receive {created, {ok, Pin}} -> Pin after 10000 -> error(timeout)
            end || _ <- Hosts],
    ?assertEqual(N, length(lists:usort(Pins))),
    [?assertEqual({ok, ok}, req(Host, {cancel_room, Pin}))
     || {Host, Pin} <- lists:zip(Hosts, sorted_by_owner(Hosts, Pins))],
    stop_all(Hosts).

orphan_sessions_are_swept(#{two := QuizId}) ->
    {ok, SessionId, 2} = quizarena_db:open_session("000001", QuizId, ?HOST),
    ok = quizarena_db:sweep_orphan_sessions(),
    ?assertMatch({ok, #{status := cancelled}},
                 quizarena_db:get_session(SessionId)),
    ?assertEqual([], mnesia:dirty_read(session_pins, "000001")).

%% ---------- Helper ----------

started_game(QuizId, Usernames) ->
    H = client(),
    {ok, Pin} = req(H, {create_room, QuizId, ?HOST, public}),
    Players = [begin
                   P = client(),
                   {ok, ok} = req(P, {join, Pin, U}),
                   P
               end || U <- Usernames],
    {ok, ok} = req(H, {start_game, Pin}),
    [expect_event(P, game_started) || P <- Players],
    {H, Pin, Players}.

client() ->
    Test = self(),
    spawn(fun() -> client_loop(Test) end).

client_loop(Test) ->
    receive
        {request, Request, From, Tag} ->
            Ref = make_ref(),
            quizarena_gateway ! {self(), Ref, Request},
            Result = receive {Ref, R} -> R after 5000 -> no_reply end,
            From ! {Tag, Result},
            client_loop(Test);
        stop ->
            ok;
        {event, Event} ->
            Test ! {event, self(), Event},
            client_loop(Test)
    end.

req(Client, Request) ->
    Tag = make_ref(),
    Client ! {request, Request, self(), Tag},
    receive {Tag, Result} -> Result after 6000 -> error(no_reply) end.

expect_event(Client, Type) ->
    expect_event(Client, Type, 1000).

expect_event(Client, Type, Timeout) ->
    expect_event(Client, Type, #{}, Timeout).

%% Attende un evento del tipo dato i cui campi coincidono con Fields.
expect_event(Client, Type, Fields, Timeout) ->
    receive
        {event, Client, #{type := Type} = Event}
          when map_size(Fields) =:= 0 ->
            Event;
        {event, Client, #{type := Type} = Event} ->
            case maps:with(maps:keys(Fields), Event) =:= Fields of
                true -> Event;
                false -> expect_event(Client, Type, Fields, Timeout)
            end
    after Timeout ->
        error({missing_event, Type, Fields})
    end.

find_room(Pin) ->
    {ok, Rooms} = quizarena_db:list_public_rooms(),
    [Room] = [R || #{pin := P} = R <- Rooms, P =:= Pin],
    Room.

room_listed(Pin) ->
    {ok, Rooms} = quizarena_db:list_public_rooms(),
    lists:any(fun(#{pin := P}) -> P =:= Pin end, Rooms).

%% Le risposte concorrenti arrivano in ordine sparso: ricostruisce il PIN
%% posseduto da ogni host chiedendolo al registro delle stanze.
sorted_by_owner(Hosts, Pins) ->
    ByHost = maps:from_list(
        [{maps:get(host_pid, room_gen_server:get_state(Pin)), Pin}
         || Pin <- Pins]),
    [maps:get(Host, ByHost) || Host <- Hosts].

wait_until(Fun) ->
    wait_until(Fun, 50).

wait_until(Fun, 0) ->
    ?assert(Fun());
wait_until(Fun, Attempts) ->
    case Fun() of
        true -> ok;
        false -> timer:sleep(20), wait_until(Fun, Attempts - 1)
    end.

stop_all(Clients) ->
    [C ! stop || C <- Clients],
    ok.
