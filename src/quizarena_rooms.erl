-module(quizarena_rooms).

-export([create/4]).

-define(PIN_GENERATION_ATTEMPTS, 20).

%% Creazione di una stanza: coordina l'apertura della sessione in Mnesia
%% (che riserva il PIN) e l'avvio del processo room sotto room_sup.
%% Se l'avvio fallisce la sessione appena aperta viene annullata; se il
%% PIN risulta gia' in uso si riprova con un altro.

create(QuizId, HostUsername, HostPid, Visibility) ->
    try_create(QuizId, HostUsername, HostPid, Visibility,
               ?PIN_GENERATION_ATTEMPTS).

try_create(_QuizId, _HostUsername, _HostPid, _Visibility, 0) ->
    {error, pin_generation_failed};
try_create(QuizId, HostUsername, HostPid, Visibility, AttemptsLeft) ->
    Pin = generate_pin(),
    case global:whereis_name({room, Pin}) of
        undefined ->
            open_session_and_start_room(
                Pin, QuizId, HostUsername, HostPid, Visibility, AttemptsLeft);
        _RoomPid ->
            try_create(QuizId, HostUsername, HostPid, Visibility,
                       AttemptsLeft - 1)
    end.

open_session_and_start_room(Pin, QuizId, HostUsername, HostPid,
                            Visibility, AttemptsLeft) ->
    case quizarena_db:open_session(Pin, QuizId, HostUsername) of
        {ok, SessionId, _QuestionCount} ->
            RoomArgs = #{pin => Pin, session_id => SessionId,
                         host_username => HostUsername, host_pid => HostPid,
                         visibility => Visibility},
            case safe_start_room(RoomArgs) of
                {ok, _RoomPid} ->
                    {ok, Pin};
                {error, {room_already_registered, Pin}} ->
                    retry_after_rollback(SessionId, QuizId, HostUsername,
                                         HostPid, Visibility, AttemptsLeft);
                {error, Reason} ->
                    room_start_error_after_rollback(SessionId, Reason)
            end;
        {error, pin_taken} ->
            try_create(QuizId, HostUsername, HostPid, Visibility,
                       AttemptsLeft - 1);
        {error, Reason} ->
            {error, Reason}
    end.

safe_start_room(RoomArgs) ->
    try room_sup:start_room(RoomArgs)
    catch Class:Reason -> {error, {Class, Reason}} end.

retry_after_rollback(SessionId, QuizId, HostUsername, HostPid, Visibility,
                     AttemptsLeft) ->
    case quizarena_db:abort_session(SessionId) of
        ok -> try_create(QuizId, HostUsername, HostPid, Visibility,
                         AttemptsLeft - 1);
        {error, RollbackReason} -> {error, {rollback_failed, RollbackReason}}
    end.

room_start_error_after_rollback(SessionId, StartReason) ->
    case quizarena_db:abort_session(SessionId) of
        ok -> {error, {room_start_failed, StartReason}};
        {error, RollbackReason} ->
            {error, {room_start_failed, StartReason,
                     rollback_failed, RollbackReason}}
    end.

generate_pin() ->
    integer_to_list(100000 + rand:uniform(900000) - 1).
