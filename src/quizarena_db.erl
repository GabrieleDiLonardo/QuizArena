-module(quizarena_db).
-export([init/0,
         %% PIN e sessioni
         claim_pin/2, release_pin/1,
         open_session/3, close_session/1,
         %% Storico
         get_history/1,
         %% Quiz CRUD
         create_quiz/2, get_quiz/1, update_quiz/2,
         delete_quiz/1, list_quizzes/0, list_quizzes_by_owner/1,
         clear_quizzes/0, seed_quizzes/0]).

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
         {attributes, [id, username, password_hash, created_at]}]),

    create_table(quizzes,
        [{disc_copies, Nodes},
         {attributes, [id, owner, title, description]},
         {index, [owner]}]),

    create_table(questions,
        [{disc_copies, Nodes},
         {attributes, [id, quiz_id, text, answers, correct, time_limit]},
         {index, [quiz_id]}]),

    create_table(sessions,
        [{disc_copies, Nodes},
         {attributes, [pin, quiz_id, host, status, started_at]}]),

    create_table(results,
        [{disc_copies, Nodes},
         {type, bag},
         {attributes, [session_id, user_id, score, finished_at]},
         {index, [user_id]}]),

    create_table(session_pins,
        [{disc_copies, Nodes},
         {attributes, [pin, quiz_id]}]),

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

%% ---------- ID univoci ----------

%% Genera un ID univoco basato sul timestamp in microsecondi.
%% Unico anche dopo riavvio del nodo (a differenza di unique_integer).
new_id() ->
    {erlang:system_time(microsecond), erlang:unique_integer([positive])}.

%% ---------- PIN ----------

claim_pin(Pin, SessionId) ->
    F = fun() ->
        case mnesia:read(session_pins, Pin) of
            [] ->
                mnesia:write({session_pins, Pin, SessionId}),
                ok;
            _ -> {error, taken}
        end
    end,
    mnesia:transaction(F).

release_pin(Pin) ->
    F = fun() -> mnesia:delete({session_pins, Pin}) end,
    mnesia:transaction(F).

%% ---------- Sessioni ----------

open_session(Pin, QuizId, Host) ->
    F = fun() ->
        case mnesia:read(session_pins, Pin) of
            [_] -> {error, pin_taken};
            [] ->
                case mnesia:read(quizzes, QuizId) of
                    [] -> {error, quiz_not_found};
                    [{quizzes, QuizId, _Owner, _Title, _Desc}] ->
                        RawQs = mnesia:index_read(questions, QuizId, quiz_id),
                        Qs = lists:keysort(1, RawQs),
                        case Qs of
                            [] -> {error, no_questions};
                            _ ->
                                mnesia:write({session_pins, Pin, QuizId}),
                                Now = erlang:system_time(millisecond),
                                mnesia:write({sessions, Pin, QuizId, Host,
                                              waiting, Now}),
                                lists:foldl(
                                  fun({questions, _QId, _QuizId, Text, Ans,
                                       Corr, TL}, N) ->
                                      mnesia:write({session_questions,
                                                    {Pin, N}, Text, Ans, Corr, TL}),
                                      N + 1
                                  end, 1, Qs),
                                {ok, length(Qs)}
                        end
                end
        end
    end,
    case mnesia:transaction(F) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, Reason}
    end.

close_session(Pin) ->
    F = fun() ->
        case mnesia:read(sessions, Pin) of
            [{sessions, Pin, QuizId, Host, _Status, StartedAt}] ->
                mnesia:write({sessions, Pin, QuizId, Host, finished, StartedAt}),
                ok;
            [] -> {error, session_not_found}
        end
    end,
    mnesia:transaction(F).

%% ---------- Storico ----------

get_history(UserId) ->
    F = fun() -> mnesia:index_read(results, UserId, user_id) end,
    case mnesia:transaction(F) of
        {atomic, Rows} ->
            [{SessionId, Score, FinishedAt}
             || {results, SessionId, _Uid, Score, FinishedAt} <- Rows];
        {aborted, Reason} -> {error, Reason}
    end.

%% ---------- Quiz CRUD ----------

create_quiz(Owner, #{title := Title, description := Desc,
                     questions := Questions}) ->
    QuizId = new_id(),
    F = fun() ->
        mnesia:write({quizzes, QuizId, Owner, Title, Desc}),
        lists:foreach(fun(Q) ->
            QId = new_id(),
            mnesia:write({questions, QId, QuizId,
                         maps:get(text, Q),
                         maps:get(answers, Q),
                         maps:get(correct, Q),
                         maps:get(time_limit, Q, 60000)})
        end, Questions)
    end,
    case mnesia:transaction(F) of
        {atomic, ok} -> {ok, QuizId};
        {aborted, Reason} -> {error, Reason}
    end.

get_quiz(QuizId) ->
    F = fun() ->
        case mnesia:read(quizzes, QuizId) of
            [] -> {error, not_found};
            [{quizzes, QuizId, Owner, Title, Desc}] ->
                RawQs = mnesia:index_read(questions, QuizId, quiz_id),
                Qs = lists:keysort(1, RawQs),
                QsOut = [#{text => Text, answers => Ans,
                           correct => Corr, time_limit => TL}
                         || {questions, _, _, Text, Ans, Corr, TL} <- Qs],
                {ok, #{id => QuizId, owner => Owner, title => Title,
                       description => Desc, questions => QsOut}}
        end
    end,
    case mnesia:transaction(F) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, Reason}
    end.

update_quiz(QuizId, #{title := Title, description := Desc,
                      questions := Questions}) ->
    F = fun() ->
        case mnesia:read(quizzes, QuizId) of
            [] -> {error, not_found};
            [{quizzes, QuizId, Owner, _OldTitle, _OldDesc}] ->
                mnesia:write({quizzes, QuizId, Owner, Title, Desc}),
                OldQs = mnesia:index_read(questions, QuizId, quiz_id),
                lists:foreach(fun({questions, QId, _, _, _, _, _}) ->
                    mnesia:delete({questions, QId})
                end, OldQs),
                lists:foreach(fun(Q) ->
                    QId = new_id(),
                    mnesia:write({questions, QId, QuizId,
                                 maps:get(text, Q),
                                 maps:get(answers, Q),
                                 maps:get(correct, Q),
                                 maps:get(time_limit, Q, 60000)})
                end, Questions),
                ok
        end
    end,
    case mnesia:transaction(F) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, Reason}
    end.

delete_quiz(QuizId) ->
    F = fun() ->
        case mnesia:read(quizzes, QuizId) of
            [] -> {error, not_found};
            [_] ->
                OldQs = mnesia:index_read(questions, QuizId, quiz_id),
                lists:foreach(fun({questions, QId, _, _, _, _, _}) ->
                    mnesia:delete({questions, QId})
                end, OldQs),
                mnesia:delete({quizzes, QuizId}),
                ok
        end
    end,
    case mnesia:transaction(F) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, Reason}
    end.

list_quizzes() ->
    F = fun() -> mnesia:foldl(fun(Q, Acc) -> [Q | Acc] end, [], quizzes) end,
    case mnesia:transaction(F) of
        {atomic, Rows} ->
            [#{id => Id, owner => Owner, title => Title, description => Desc}
             || {quizzes, Id, Owner, Title, Desc} <- Rows];
        {aborted, Reason} -> {error, Reason}
    end.

list_quizzes_by_owner(Owner) ->
    F = fun() -> mnesia:index_read(quizzes, Owner, owner) end,
    case mnesia:transaction(F) of
        {atomic, Rows} ->
            [#{id => Id, owner => RowOwner, title => Title,
               description => Desc}
             || {quizzes, Id, RowOwner, Title, Desc} <- Rows];
        {aborted, Reason} -> {error, Reason}
    end.

clear_quizzes() ->
    F = fun() ->
        AllQ = mnesia:foldl(fun(Q, Acc) -> [Q | Acc] end, [], quizzes),
        AllQs = mnesia:foldl(fun(Q, Acc) -> [Q | Acc] end, [], questions),
        lists:foreach(fun({quizzes, Id, _, _, _}) ->
            mnesia:delete({quizzes, Id})
        end, AllQ),
        lists:foreach(fun({questions, Id, _, _, _, _, _}) ->
            mnesia:delete({questions, Id})
        end, AllQs),
        {length(AllQ), length(AllQs)}
    end,
    case mnesia:transaction(F) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, Reason}
    end.

seed_quizzes() ->
    quizzes:seed().