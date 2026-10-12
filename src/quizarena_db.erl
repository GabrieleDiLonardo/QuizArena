-module(quizarena_db).
-define(SESSION_ID_ATTEMPTS, 3).
-export([init/0,
         %% Utenti
         create_user/2, get_user/1,
         %% PIN e sessioni
         open_session/3, abort_session/1, mark_session_started/1,
         cancel_session/1, finish_session/2,
         %% Storico
         get_history/1,
         %% Quiz CRUD
         create_quiz/2, get_quiz/2, update_quiz/3,
         delete_quiz/2, list_quizzes_by_owner/1,
         list_browsable_quizzes/1,
         clear_quizzes/0, seed_quizzes/0, seed_extended_quizzes/0]).

init() ->
    case mnesia:create_schema([node() | nodes()]) of
        ok -> ok;
        {error, {_, {already_exists, _}}} -> ok
    end,
    mnesia:start(),
    timer:sleep(2000),

    case mnesia:change_table_copy_type(schema, node(), disc_copies) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, schema, _, _}} -> ok;
        {aborted, Reason} -> io:format("Schema change failed: ~p~n", [Reason])
    end,

    Nodes = [node() | nodes()],

    create_table(users,
        [{disc_copies, Nodes},
         {attributes, [username, credentials]}]),

    create_table(quizzes,
        [{disc_copies, Nodes},
         {attributes, [id, owner, title, description, visibility]},
         {index, [owner]}]),

    create_table(questions,
        [{disc_copies, Nodes},
         {attributes, [id, quiz_id, position, text, answers, correct,
                       time_limit]},
         {index, [quiz_id]}]),

    create_table(sessions,
        [{disc_copies, Nodes},
         {attributes, [id, pin, quiz_id, quiz_title, host, status,
                       started_at, finished_at]}]),

    create_table(results,
        [{disc_copies, Nodes},
         {type, bag},
         {attributes, [session_id, user_id, score, finished_at]},
         {index, [user_id]}]),

    create_table(session_pins,
        [{disc_copies, Nodes},
         {attributes, [pin, session_id]}]),

    create_table(session_questions,
        [{disc_copies, Nodes},
         {attributes, [key, text, answers, correct, time_limit]}]),

    Tables = [users, quizzes, questions, sessions, results,
              session_pins, session_questions],
    ok = mnesia:wait_for_tables(Tables, 30000),
    io:format("Mnesia schema ready on ~p~n", [Nodes]),
    ok.

create_table(Name, Args) ->
    case mnesia:create_table(Name, Args) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, Name}} -> ok;
        {aborted, Reason} -> erlang:error({mnesia_create_failed, Name, Reason})
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
