-module(quizarena_db).
-define(SESSION_ID_ATTEMPTS, 3).
-export([init/0,
         %% Utenti
         create_user/2, get_user/1,
         %% PIN e sessioni
         open_session/3, abort_session/1, mark_session_started/1,
         cancel_session/1, finish_session/2,
         get_session/1, get_session_questions/1, sweep_orphan_sessions/0,
         %% Registro stanze attive
         publish_room/1, unpublish_room/1, list_public_rooms/0,
         %% Snapshot delle partite in corso
         save_snapshot/2, delete_snapshot/1, list_snapshots/0,
         %% Storico
         get_history/1,
         %% Quiz CRUD
         create_quiz/2, get_quiz/2, update_quiz/3,
         delete_quiz/2, list_quizzes_by_owner/1,
         list_browsable_quizzes/1,
         clear_quizzes/0, seed_quizzes/0, seed_extended_quizzes/0]).

-define(JOIN_ATTEMPTS, 60).
-define(JOIN_RETRY_MS, 2000).
-define(TABLE_LOAD_TIMEOUT_MS, 30000).

%% ---------- Bootstrap del cluster Mnesia ----------
%%
%% Mnesia e' gia' avviata come dipendenza dell'applicazione. Tre casi:
%%   - schema gia' su disco: il nodo si riaggancia da solo agli altri nodi
%%     dello schema non appena la distribuzione Erlang li collega;
%%   - nodo nuovo con un altro nodo del cluster attivo: entra nel suo schema
%%     (extra_db_nodes) e si crea le proprie copie delle tabelle;
%%   - primo avvio assoluto: lo schema lo crea solo il seed, gli altri
%%     attendono che sia disponibile. Cosi' due nodi avviati insieme non
%%     creano schemi separati e incompatibili.
init() ->
    ok = join_cluster(?JOIN_ATTEMPTS),
    ok = ensure_disc_schema(),
    ok = ensure_tables(),
    ok = wait_for_tables(),
    RunningNodes = mnesia:system_info(running_db_nodes),
    logger:notice("Mnesia schema ready on ~p", [RunningNodes]),
    %% Con altri nodi attivi le stanze orfane sono compito del leader.
    case RunningNodes of
        [_OnlyThisNode] -> sweep_orphan_sessions();
        _ -> ok
    end,
    ok.

join_cluster(AttemptsLeft) ->
    case mnesia:system_info(use_dir) of
        true ->
            ok;
        false ->
            case running_peers() of
                [_ | _] = Peers ->
                    {ok, _} = mnesia:change_config(extra_db_nodes, Peers),
                    ok;
                [] ->
                    case node() =:= quizarena_cluster:seed() of
                        true ->
                            ok;
                        false when AttemptsLeft > 0 ->
                            logger:notice("Waiting for the Mnesia seed ~p",
                                      [quizarena_cluster:seed()]),
                            timer:sleep(?JOIN_RETRY_MS),
                            quizarena_cluster:connect(),
                            join_cluster(AttemptsLeft - 1);
                        false ->
                            {error, seed_unreachable}
                    end
            end
    end.

running_peers() ->
    [Node || Node <- quizarena_cluster:others(),
             lists:member(Node, nodes()),
             rpc:call(Node, mnesia, system_info, [is_running]) =:= yes].

ensure_disc_schema() ->
    case mnesia:change_table_copy_type(schema, node(), disc_copies) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, schema, _, disc_copies}} -> ok;
        {aborted, Reason} -> {error, {schema_copy_failed, Reason}}
    end.

table_specs() ->
    [{users, disc_copies,
      [{attributes, [username, credentials]}]},
     {quizzes, disc_copies,
      [{attributes, [id, owner, title, description, visibility]},
       {index, [owner]}]},
     {questions, disc_copies,
      [{attributes, [id, quiz_id, position, text, answers, correct,
                     time_limit]},
       {index, [quiz_id]}]},
     {sessions, disc_copies,
      [{attributes, [id, pin, quiz_id, quiz_title, host, status,
                     started_at, finished_at]}]},
     {results, disc_copies,
      [{type, bag},
       {attributes, [session_id, user_id, score, finished_at]},
       {index, [user_id]}]},
     {session_pins, disc_copies,
      [{attributes, [pin, session_id]}]},
     {session_questions, disc_copies,
      [{attributes, [key, text, answers, correct, time_limit]}]},
     %% Registro delle stanze attive, letto dalla lobby. Vive solo in RAM:
     %% ogni riga e' scritta esclusivamente dalla room che la possiede.
     {open_rooms, ram_copies,
      [{attributes, [pin, session_id, quiz_title, host, visibility,
                     status, num_players, num_questions,
                     current_round, node]}]},
     %% Stato delle partite in corso, replicato per il ripristino dopo la
     %% caduta del nodo che le ospita.
     {room_snapshots, ram_copies,
      [{attributes, [pin, owner_node, snapshot]}]}].

%% Crea le tabelle mancanti su tutti i nodi attivi e garantisce che il
%% nodo locale abbia la propria copia di ognuna.
ensure_tables() ->
    Existing = mnesia:system_info(tables),
    lists:foreach(
        fun({Name, CopyType, Options}) ->
            case lists:member(Name, Existing) of
                false ->
                    Nodes = creation_nodes(CopyType),
                    create_table(Name, [{CopyType, Nodes} | Options]);
                true ->
                    ensure_local_copy(Name, CopyType)
            end
        end,
        table_specs()),
    ok.

%% Una copia su disco richiede che il nodo abbia gia' lo schema su disco:
%% un nodo appena entrato nel cluster si aggiunge le copie da solo dopo
%% aver convertito il proprio schema (ensure_local_copy/2).
creation_nodes(disc_copies) ->
    DiscSchemaNodes = mnesia:table_info(schema, disc_copies),
    [N || N <- mnesia:system_info(running_db_nodes),
          lists:member(N, DiscSchemaNodes)];
creation_nodes(ram_copies) ->
    [node()].

create_table(Name, Args) ->
    case mnesia:create_table(Name, Args) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, Name}} -> ensure_local_copy(Name, copy_type(Args));
        {aborted, Reason} -> erlang:error({mnesia_create_failed, Name, Reason})
    end.

copy_type(Args) ->
    hd([Type || {Type, _} <- Args,
                lists:member(Type, [disc_copies, ram_copies])]).

ensure_local_copy(Name, CopyType) ->
    Copies = mnesia:table_info(Name, disc_copies)
        ++ mnesia:table_info(Name, ram_copies)
        ++ mnesia:table_info(Name, disc_only_copies),
    case lists:member(node(), Copies) of
        true ->
            ok;
        false ->
            case mnesia:add_table_copy(Name, node(), CopyType) of
                {atomic, ok} -> ok;
                {aborted, {already_exists, Name, _}} -> ok;
                {aborted, Reason} ->
                    erlang:error({mnesia_add_copy_failed, Name, Reason})
            end
    end.

%% Al riavvio Mnesia carica da disco una tabella solo se sa che la copia
%% locale e' la piu' recente; se gli altri nodi non tornano entro il
%% timeout il caricamento viene forzato (va segnalato: si perdono le
%% eventuali scritture fatte altrove dopo la caduta di questo nodo).
wait_for_tables() ->
    Tables = [Name || {Name, _, _} <- table_specs()],
    case mnesia:wait_for_tables(Tables, ?TABLE_LOAD_TIMEOUT_MS) of
        ok ->
            ok;
        {timeout, Missing} ->
            logger:notice("Forcing load of tables ~p", [Missing]),
            [yes = mnesia:force_load_table(T) || T <- Missing],
            ok
    end.

%% ---------- Utenti ----------

create_user(Username, Credentials)
  when is_list(Username), is_map(Credentials) ->
    F = fun() ->
        case mnesia:read(users, Username, write) of
            [] ->
                mnesia:write({users, Username, Credentials}),
                ok;
            [_User] ->
                {error, username_taken}
        end
    end,
    transaction_result(F).

get_user(Username) when is_list(Username) ->
    F = fun() ->
        case mnesia:read(users, Username, read) of
            [{users, Username, Credentials}] -> {ok, Credentials};
            [] -> {error, not_found}
        end
    end,
    transaction_result(F).

%% ---------- ID univoci ----------

new_id() ->
    {erlang:system_time(microsecond), erlang:unique_integer([positive])}.

%% ---------- Sessioni ----------

%% Il PIN identifica la stanza attiva; l'UUID identifica la sessione storica.

%% Un host può avviare una sessione con:
%%   - un proprio quiz (visibility qualsiasi)
%%   - un quiz pubblico di chiunque altro
open_session(Pin, QuizId, Host) ->
    open_session(Pin, QuizId, Host, ?SESSION_ID_ATTEMPTS).

open_session(_Pin, _QuizId, _Host, 0) ->
    {error, session_id_generation_failed};
open_session(Pin, QuizId, Host, AttemptsLeft) ->
    SessionId = uuid:uuid_to_string(uuid:get_v4()),
    F = fun() ->
        case mnesia:read(session_pins, Pin, write) of
            [_] -> {error, pin_taken};
            [] ->
                case mnesia:read(sessions, SessionId, write) of
                    [_] ->
                        {error, session_id_taken};
                    [] ->
                        create_session(SessionId, Pin, QuizId, Host)
                end
        end
    end,
    case mnesia:transaction(F) of
        {atomic, {error, session_id_taken}} ->
            open_session(Pin, QuizId, Host, AttemptsLeft - 1);
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, Reason}
    end.

create_session(SessionId, Pin, QuizId, Host) ->
    case mnesia:read(quizzes, QuizId) of
        [] ->
            {error, quiz_not_found};
        [{quizzes, QuizId, Owner, Title, _Desc, Visibility}] ->
            case (Owner =:= Host) orelse (Visibility =:= public) of
                true ->
                    RawQs = mnesia:index_read(questions, QuizId, quiz_id),
                    Qs = lists:keysort(4, RawQs),
                    store_session(SessionId, Pin, QuizId, Title, Host, Qs);
                false ->
                    {error, not_owner}
            end
    end.

store_session(_SessionId, _Pin, _QuizId, _Title, _Host, []) ->
    {error, no_questions};
store_session(SessionId, Pin, QuizId, Title, Host, Questions) ->
    mnesia:write({session_pins, Pin, SessionId}),
    Now = erlang:system_time(millisecond),
    mnesia:write({sessions, SessionId, Pin, QuizId, Title, Host,
                  waiting, Now, undefined}),
    lists:foldl(
        fun({questions, _QuestionId, _QuizId, _Position, Text, Answers,
             Correct, TimeLimit}, Number) ->
            mnesia:write({session_questions, {SessionId, Number},
                          Text, Answers, Correct, TimeLimit}),
            Number + 1
        end,
        1,
        Questions
    ),
    {ok, SessionId, length(Questions)}.

abort_session(SessionId) ->
    F = fun() ->
        case mnesia:read(sessions, SessionId, write) of
            [{sessions, SessionId, Pin, _QuizId, _Title, _Host,
              waiting, _StartedAt, _FinishedAt}] ->
                mnesia:delete({sessions, SessionId}),
                mnesia:delete({session_pins, Pin}),
                delete_session_questions(SessionId),
                ok;
            [{sessions, SessionId, _Pin, _QuizId, _Title, _Host,
              _Status, _StartedAt, _FinishedAt}] ->
                {error, session_not_waiting};
            [] ->
                {error, session_not_found}
        end
    end,
    transaction_result(F).

mark_session_started(SessionId) ->
    F = fun() ->
        case mnesia:read(sessions, SessionId, write) of
            [{sessions, SessionId, Pin, QuizId, Title, Host,
              waiting, StartedAt, undefined}] ->
                mnesia:write({sessions, SessionId, Pin, QuizId, Title, Host,
                              playing, StartedAt, undefined}),
                ok;
            [{sessions, SessionId, _Pin, _QuizId, _Title, _Host,
              Status, _StartedAt, _FinishedAt}] ->
                {error, {invalid_status, Status}};
            [] ->
                {error, session_not_found}
        end
    end,
    transaction_result(F).

cancel_session(SessionId) ->
    F = fun() ->
        case mnesia:read(sessions, SessionId, write) of
            [{sessions, SessionId, Pin, QuizId, Title, Host, Status,
              StartedAt, _FinishedAt}]
              when Status =:= waiting; Status =:= playing ->
                CancelledAt = erlang:system_time(millisecond),
                mnesia:write({sessions, SessionId, Pin, QuizId, Title, Host,
                              cancelled, StartedAt, CancelledAt}),
                mnesia:delete({session_pins, Pin}),
                delete_session_questions(SessionId),
                ok;
            [{sessions, SessionId, _Pin, _QuizId, _Title, _Host,
              Status, _StartedAt, _FinishedAt}] ->
                {error, {invalid_status, Status}};
            [] ->
                {error, session_not_found}
        end
    end,
    transaction_result(F).

finish_session(SessionId, PlayerResults) when is_list(PlayerResults) ->
    F = fun() ->
        case mnesia:read(sessions, SessionId, write) of
            [{sessions, SessionId, Pin, QuizId, Title, Host,
              playing, StartedAt, undefined}] ->
                FinishedAt = erlang:system_time(millisecond),
                lists:foreach(
                    fun({Username, Score}) ->
                        mnesia:write({results, SessionId, Username,
                                      Score, FinishedAt})
                    end,
                    PlayerResults
                ),
                mnesia:write({sessions, SessionId, Pin, QuizId, Title, Host,
                              finished, StartedAt, FinishedAt}),
                mnesia:delete({session_pins, Pin}),
                delete_session_questions(SessionId),
                ok;
            [{sessions, SessionId, _Pin, _QuizId, _Title, _Host,
              Status, _StartedAt, _FinishedAt}] ->
                {error, {invalid_status, Status}};
            [] ->
                {error, session_not_found}
        end
    end,
    transaction_result(F).

get_session(SessionId) ->
    F = fun() ->
        case mnesia:read(sessions, SessionId) of
            [{sessions, SessionId, Pin, QuizId, Title, Host, Status,
              _StartedAt, _FinishedAt}] ->
                {ok, #{pin => Pin, quiz_id => QuizId, quiz_title => Title,
                       host => Host, status => Status}};
            [] ->
                {error, session_not_found}
        end
    end,
    transaction_result(F).

get_session_questions(SessionId) ->
    F = fun() ->
        Rows = mnesia:match_object(
            {session_questions, {SessionId, '_'}, '_', '_', '_', '_'}),
        [#{text => Text, answers => Answers, correct => Correct,
           time_limit => TimeLimit}
         || {session_questions, {_Id, _N}, Text, Answers, Correct, TimeLimit}
                <- lists:keysort(2, Rows)]
    end,
    case mnesia:transaction(F) of
        {atomic, Questions} -> {ok, Questions};
        {aborted, Reason} -> {error, Reason}
    end.

%% Le sessioni rimaste in waiting/playing senza una room viva sono orfane
%% (es. riavvio del nodo durante una partita): vengono annullate e il loro
%% PIN torna libero.
sweep_orphan_sessions() ->
    _ = global:sync(),
    Pattern = {sessions, '_', '_', '_', '_', '_', '_', '_', '_'},
    Active = [{SessionId, Pin}
              || {sessions, SessionId, Pin, _Q, _T, _H, Status, _S, _F}
                     <- mnesia:dirty_match_object(Pattern),
                 Status =:= waiting orelse Status =:= playing],
    Orphans = [S || {S, Pin} <- Active,
                    global:whereis_name({room, Pin}) =:= undefined],
    lists:foreach(fun cancel_session/1, Orphans),
    StaleRooms = [Pin || Pin <- mnesia:dirty_all_keys(open_rooms),
                         global:whereis_name({room, Pin}) =:= undefined],
    lists:foreach(fun unpublish_room/1, StaleRooms),
    case Orphans of
        [] -> ok;
        _ -> logger:notice("Cancelled ~p orphan sessions", [length(Orphans)])
    end.

%% ---------- Registro stanze attive ----------

%% Scrittura dirty: ogni riga ha un unico scrittore (la room del PIN),
%% quindi non servono lock.
publish_room(#{pin := Pin, session_id := SessionId, quiz_title := Title,
               host := Host, visibility := Visibility, status := Status,
               num_players := NumPlayers, num_questions := NumQuestions,
               current_round := Round}) ->
    mnesia:dirty_write({open_rooms, Pin, SessionId, Title, Host, Visibility,
                        Status, NumPlayers, NumQuestions, Round, node()}).

unpublish_room(Pin) ->
    mnesia:dirty_delete(open_rooms, Pin).

list_public_rooms() ->
    Rows = mnesia:dirty_match_object(
        {open_rooms, '_', '_', '_', '_', public, '_', '_', '_', '_', '_'}),
    {ok, [#{pin => Pin, quiz_title => Title, host => Host,
            status => Status, num_players => NumPlayers,
            num_questions => NumQuestions, current_round => Round}
          || {open_rooms, Pin, _SessionId, Title, Host, _Visibility, Status,
              NumPlayers, NumQuestions, Round, _Node} <- Rows]}.

%% ---------- Snapshot delle partite in corso ----------

%% sync_dirty attende che la scrittura sia applicata su tutte le repliche
%% attive: quando la room conferma un'operazione, lo stato e' gia' al sicuro
%% sugli altri nodi. Ogni riga ha un unico scrittore (la room del PIN).
save_snapshot(Pin, Snapshot) ->
    mnesia:sync_dirty(fun() ->
        mnesia:write({room_snapshots, Pin, node(), Snapshot})
    end).

delete_snapshot(Pin) ->
    mnesia:sync_dirty(fun() ->
        mnesia:delete({room_snapshots, Pin})
    end).

list_snapshots() ->
    [{Pin, OwnerNode, Snapshot}
     || {room_snapshots, Pin, OwnerNode, Snapshot}
            <- mnesia:dirty_match_object({room_snapshots, '_', '_', '_'})].

delete_session_questions(SessionId) ->
    SessionQuestions = mnesia:match_object(
        {session_questions, {SessionId, '_'}, '_', '_', '_', '_'}
    ),
    lists:foreach(fun mnesia:delete_object/1, SessionQuestions).

transaction_result(F) ->
    case mnesia:transaction(F) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, Reason}
    end.

%% ---------- Storico ----------

get_history(Username) ->
    F = fun() ->
        PlayerRows = mnesia:index_read(results, Username, user_id),
        PlayerSessionIds = [SessionId
            || {results, SessionId, _User, _Score, _FinishedAt}
                   <- PlayerRows],
        HostedSessionIds = mnesia:foldl(
            fun({sessions, SessionId, _Pin, _QuizId, _Title, Host,
                 finished, _StartedAt, _FinishedAt}, Acc)
                  when Host =:= Username ->
                    [SessionId | Acc];
               (_Session, Acc) ->
                    Acc
            end,
            [],
            sessions
        ),
        SessionIds = lists:usort(PlayerSessionIds ++ HostedSessionIds),
        [history_entry(Username, SessionId) || SessionId <- SessionIds]
    end,
    case mnesia:transaction(F) of
        {atomic, History} -> History;
        {aborted, Reason} -> {error, Reason}
    end.

history_entry(Username, SessionId) ->
    [{sessions, SessionId, _Pin, _QuizId, Title, Host,
      finished, _StartedAt, FinishedAt}] = mnesia:read(sessions, SessionId),
    SessionResults = mnesia:read(results, SessionId),
    ParticipantCount = length(SessionResults),
    {Score, Rank} = player_result(Username, SessionResults),
    #{session_id => SessionId,
      quiz_title => Title,
      hosted => (Host =:= Username),
      participant_count => ParticipantCount,
      score => Score,
      rank => Rank,
      finished_at => FinishedAt}.

player_result(Username, SessionResults) ->
    case lists:keyfind(Username, 3, SessionResults) of
        {results, _SessionId, Username, Score, _FinishedAt} ->
            BetterScores = [OtherScore
                || {results, _Id, _User, OtherScore, _At} <- SessionResults,
                   OtherScore > Score],
            {Score, length(BetterScores) + 1};
        false ->
            {undefined, undefined}
    end.

%% ---------- Quiz CRUD ----------

create_quiz(Owner, #{title := Title, description := Desc,
                     questions := Questions} = QuizSpec) ->
    Visibility = maps:get(visibility, QuizSpec, public),
    QuizId = new_id(),
    F = fun() ->
        mnesia:write({quizzes, QuizId, Owner, Title, Desc, Visibility}),
        lists:foreach(fun({Position, Q}) ->
            QId = new_id(),
            mnesia:write({questions, QId, QuizId, Position,
                         maps:get(text, Q),
                         maps:get(answers, Q),
                         maps:get(correct, Q),
                         maps:get(time_limit, Q, 60000)})
        end, lists:zip(lists:seq(1, length(Questions)), Questions))
    end,
    case mnesia:transaction(F) of
        {atomic, ok} -> {ok, QuizId};
        {aborted, Reason} -> {error, Reason}
    end.

get_quiz(Owner, QuizId) ->
    F = fun() ->
        case mnesia:read(quizzes, QuizId) of
            [] -> {error, not_found};
            [{quizzes, QuizId, Owner, Title, Desc, Visibility}] ->
                RawQs = mnesia:index_read(questions, QuizId, quiz_id),
                Qs = lists:keysort(4, RawQs),
                QsOut = [#{text => Text, answers => Ans,
                           correct => Corr, time_limit => TL}
                         || {questions, _, _, _Position,
                             Text, Ans, Corr, TL} <- Qs],
                {ok, #{id => QuizId, owner => Owner, title => Title,
                       description => Desc, visibility => Visibility,
                       questions => QsOut}};
            [{quizzes, QuizId, _OtherOwner, _Title, _Desc, _Visibility}] ->
                {error, not_owner}
        end
    end,
    case mnesia:transaction(F) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, Reason}
    end.

update_quiz(Owner, QuizId, #{title := Title, description := Desc,
                             questions := Questions} = QuizSpec) ->
    Visibility = maps:get(visibility, QuizSpec, public),
    F = fun() ->
        case mnesia:read(quizzes, QuizId, write) of
            [] -> {error, not_found};
            [{quizzes, QuizId, Owner, _OldTitle, _OldDesc, _OldVis}] ->
                mnesia:write({quizzes, QuizId, Owner, Title, Desc, Visibility}),
                OldQs = mnesia:index_read(questions, QuizId, quiz_id),
                lists:foreach(fun({questions, QId, _, _, _, _, _, _}) ->
                    mnesia:delete({questions, QId})
                end, OldQs),
                lists:foreach(fun({Position, Q}) ->
                    QId = new_id(),
                    mnesia:write({questions, QId, QuizId, Position,
                                 maps:get(text, Q),
                                 maps:get(answers, Q),
                                 maps:get(correct, Q),
                                 maps:get(time_limit, Q, 60000)})
                end, lists:zip(lists:seq(1, length(Questions)), Questions)),
                ok;
            [{quizzes, QuizId, _OtherOwner, _Title, _Desc, _Visibility}] ->
                {error, not_owner}
        end
    end,
    case mnesia:transaction(F) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, Reason}
    end.

delete_quiz(Owner, QuizId) ->
    F = fun() ->
        case mnesia:read(quizzes, QuizId, write) of
            [] -> {error, not_found};
            [{quizzes, QuizId, Owner, _Title, _Desc, _Visibility}] ->
                OldQs = mnesia:index_read(questions, QuizId, quiz_id),
                lists:foreach(fun({questions, QId, _, _, _, _, _, _}) ->
                    mnesia:delete({questions, QId})
                end, OldQs),
                mnesia:delete({quizzes, QuizId}),
                ok;
            [{quizzes, QuizId, _OtherOwner, _Title, _Desc, _Visibility}] ->
                {error, not_owner}
        end
    end,
    case mnesia:transaction(F) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, Reason}
    end.

list_quizzes_by_owner(Owner) ->
    F = fun() -> mnesia:index_read(quizzes, Owner, owner) end,
    case mnesia:transaction(F) of
        {atomic, Rows} ->
            Quizzes = [#{id => Id, owner => RowOwner, title => Title,
                         description => Desc, visibility => Vis}
                       || {quizzes, Id, RowOwner, Title, Desc, Vis} <- Rows],
            {ok, Quizzes};
        {aborted, Reason} -> {error, Reason}
    end.

%% Quiz visibili all'utente: i propri (pubblici o privati) +
%% i quiz pubblici degli altri.
list_browsable_quizzes(Username) when is_list(Username) ->
    F = fun() ->
        AllQuizzes = mnesia:foldl(
            fun({quizzes, Id, Owner, Title, Desc, Visibility}, Acc) ->
                case (Owner =:= Username) orelse (Visibility =:= public) of
                    true ->
                        [#{id => Id, owner => Owner, title => Title,
                           description => Desc, visibility => Visibility,
                           is_own => (Owner =:= Username)} | Acc];
                    false ->
                        Acc
                end
            end, [], quizzes),
        AllQuizzes
    end,
    case mnesia:transaction(F) of
        {atomic, Quizzes} -> {ok, Quizzes};
        {aborted, Reason} -> {error, Reason}
    end.

clear_quizzes() ->
    F = fun() ->
        AllQ = mnesia:foldl(fun(Q, Acc) -> [Q | Acc] end, [], quizzes),
        AllQs = mnesia:foldl(fun(Q, Acc) -> [Q | Acc] end, [], questions),
        lists:foreach(fun({quizzes, Id, _, _, _, _}) ->
            mnesia:delete({quizzes, Id})
        end, AllQ),
        lists:foreach(fun({questions, Id, _, _, _, _, _, _}) ->
            mnesia:delete({questions, Id})
        end, AllQs),
        {length(AllQ), length(AllQs)}
    end,
    case mnesia:transaction(F) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, Reason}
    end.

%% Popola con i 3 quiz originali
seed_quizzes() ->
    quizzes:seed().

%% Popola con i 3 quiz originali + 10 estesi (13 quiz, ~39 domande)
seed_extended_quizzes() ->
    quizzes:seed_extended().
