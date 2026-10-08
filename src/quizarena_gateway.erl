-module(quizarena_gateway).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(PIN_GENERATION_ATTEMPTS, 20).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

%% ---------- Ping ----------
handle_info({JavaPid, Ref, ping}, State)
  when is_pid(JavaPid), is_reference(Ref) ->
    JavaPid ! {Ref, {ok, pong}},
    {noreply, State};

%% ---------- Quiz ----------
handle_info({JavaPid, Ref, list_quizzes}, State)
  when is_pid(JavaPid), is_reference(Ref) ->
    Result = case quizarena_db:list_quizzes() of
        {error, Reason} -> {error, Reason};
        Quizzes when is_list(Quizzes) -> {ok, Quizzes}
    end,
    JavaPid ! {Ref, Result},
    {noreply, State};

handle_info({JavaPid, Ref, {get_quiz, QuizId}}, State)
  when is_pid(JavaPid), is_reference(Ref) ->
    Result = case quizarena_db:get_quiz(QuizId) of
        {ok, Quiz} -> {ok, Quiz};
        {error, Reason} -> {error, Reason}
    end,
    JavaPid ! {Ref, Result},
    {noreply, State};

handle_info({JavaPid, Ref, {get_history, User}}, State)
  when is_pid(JavaPid), is_reference(Ref), is_list(User) ->
    Result = case quizarena_db:get_history(User) of
        {error, Reason} -> {error, Reason};
        History when is_list(History) -> {ok, History}
    end,
    JavaPid ! {Ref, Result},
    {noreply, State};

%% ---------- Stanze ----------
handle_info({JavaPid, Ref, {create_room, QuizId, HostName}}, State)
  when is_pid(JavaPid), is_reference(Ref), is_tuple(QuizId), is_list(HostName) ->
    Result = create_room(QuizId, HostName, JavaPid),
    JavaPid ! {Ref, Result},
    {noreply, State};

handle_info({JavaPid, Ref, {cancel_room, Pin}}, State)
  when is_pid(JavaPid), is_reference(Ref), is_list(Pin) ->
    Result = cancel_room(Pin, JavaPid),
    JavaPid ! {Ref, Result},
    {noreply, State};

handle_info({JavaPid, Ref, list_rooms}, State)
  when is_pid(JavaPid), is_reference(Ref) ->
    JavaPid ! {Ref, {ok, list_open_rooms()}},
    {noreply, State};

%% ---------- Gioco ----------
handle_info({JavaPid, Ref, {join, Pin, Nickname}}, State)
  when is_pid(JavaPid), is_reference(Ref), is_list(Pin), is_list(Nickname) ->
    Result = safe_call(fun() -> room_gen_server:join(Pin, Nickname, JavaPid) end),
    JavaPid ! {Ref, Result},
    {noreply, State};

handle_info({JavaPid, Ref, {rejoin, Pin, PlayerId}}, State)
  when is_pid(JavaPid), is_reference(Ref), is_list(Pin), is_integer(PlayerId) ->
    Result = safe_call(fun() -> room_gen_server:rejoin(Pin, PlayerId, JavaPid) end),
    JavaPid ! {Ref, Result},
    {noreply, State};

handle_info({JavaPid, Ref, {start_game, Pin}}, State)
  when is_pid(JavaPid), is_reference(Ref), is_list(Pin) ->
    Result = safe_call(fun() -> room_gen_server:start_game(Pin, JavaPid) end),
    JavaPid ! {Ref, Result},
    {noreply, State};

handle_info({JavaPid, Ref, {next_round, Pin}}, State)
  when is_pid(JavaPid), is_reference(Ref), is_list(Pin) ->
    Result = safe_call(fun() -> room_gen_server:next_round(Pin, JavaPid) end),
    JavaPid ! {Ref, Result},
    {noreply, State};

handle_info({JavaPid, Ref, {answer, Pin, PlayerId, Round, Answer}}, State)
  when is_pid(JavaPid), is_reference(Ref), is_list(Pin),
       is_integer(PlayerId), is_integer(Round), is_list(Answer) ->
    Result = safe_call(fun() -> room_gen_server:answer(Pin, PlayerId, Round, Answer) end),
    JavaPid ! {Ref, Result},
    {noreply, State};

handle_info({JavaPid, Ref, {end_game, Pin}}, State)
  when is_pid(JavaPid), is_reference(Ref), is_list(Pin) ->
    Result = safe_call(fun() -> room_gen_server:end_game(Pin, JavaPid) end),
    JavaPid ! {Ref, Result},
    {noreply, State};

handle_info({JavaPid, Ref, {get_events_since, Pin, SinceSeq}}, State)
  when is_pid(JavaPid), is_reference(Ref), is_list(Pin), is_integer(SinceSeq) ->
    Result = safe_call(fun() -> room_gen_server:get_events_since(Pin, SinceSeq) end),
    JavaPid ! {Ref, Result},
    {noreply, State};

%% ---------- Fallback ----------
handle_info({JavaPid, Ref, _Request}, State)
  when is_pid(JavaPid), is_reference(Ref) ->
    JavaPid ! {Ref, {error, unsupported_request}},
    {noreply, State};

handle_info(_Message, State) ->
    {noreply, State}.

%% ---------- Helper ----------

safe_call(Fun) ->
    try Fun() of
        {ok, _} = Ok -> Ok;
        {error, _} = Err -> Err;
        ok -> {ok, ok};
        Other -> {error, {unexpected, Other}}
    catch
        exit:{noproc, _} -> {error, room_not_found};
        exit:{timeout, _} -> {error, timeout};
        exit:{nodedown, _} -> {error, node_down};
        exit:Reason -> {error, {call_failed, Reason}}
    end.

create_room(QuizId, HostName, HostPid) ->
    try_create_room(QuizId, HostName, HostPid, ?PIN_GENERATION_ATTEMPTS).

try_create_room(_QuizId, _HostName, _HostPid, 0) ->
    {error, pin_generation_failed};
try_create_room(QuizId, HostName, HostPid, AttemptsLeft) ->
    Pin = generate_pin(),
    case global:whereis_name({room, Pin}) of
        undefined ->
            open_session_and_start_room(
                Pin, QuizId, HostName, HostPid, AttemptsLeft);
        _RoomPid ->
            try_create_room(QuizId, HostName, HostPid, AttemptsLeft - 1)
    end.

open_session_and_start_room(Pin, QuizId, HostName, HostPid, AttemptsLeft) ->
    case quizarena_db:open_session(Pin, QuizId, HostName) of
        {ok, _QuestionCount} ->
            case safe_start_room(Pin, HostPid) of
                {ok, _RoomPid} ->
                    {ok, Pin};
                {error, {room_already_registered, Pin}} ->
                    retry_after_rollback(Pin, QuizId, HostName, HostPid, AttemptsLeft);
                {error, Reason} ->
                    room_start_error_after_rollback(Pin, Reason)
            end;
        {error, pin_taken} ->
            try_create_room(QuizId, HostName, HostPid, AttemptsLeft - 1);
        {error, Reason} ->
            {error, Reason}
    end.

safe_start_room(Pin, HostPid) ->
    try room_sup:start_room(Pin, HostPid)
    catch Class:Reason -> {error, {Class, Reason}} end.

retry_after_rollback(Pin, QuizId, HostName, HostPid, AttemptsLeft) ->
    case quizarena_db:abort_session(Pin) of
        ok -> try_create_room(QuizId, HostName, HostPid, AttemptsLeft - 1);
        {error, RollbackReason} -> {error, {rollback_failed, RollbackReason}}
    end.

room_start_error_after_rollback(Pin, StartReason) ->
    case quizarena_db:abort_session(Pin) of
        ok -> {error, {room_start_failed, StartReason}};
        {error, RollbackReason} ->
            {error, {room_start_failed, StartReason, rollback_failed, RollbackReason}}
    end.

cancel_room(Pin, HostPid) ->
    try room_gen_server:cancel(Pin, HostPid)
    catch
        exit:{noproc, _} -> {error, room_not_found};
        exit:Reason -> {error, {room_call_failed, Reason}}
    end.

list_open_rooms() ->
    Names = global:registered_names(),
    RoomNames = [N || {room, _} = N <- Names],
    lists:filtermap(fun room_summary/1, RoomNames).

room_summary({room, Pin} = Name) ->
    case global:whereis_name(Name) of
        undefined -> false;
        _Pid ->
            try room_gen_server:get_state(Pin) of
                State ->
                    {true, #{
                        pin => Pin,
                        status => maps:get(status, State, unknown),
                        num_players => maps:size(maps:get(players, State, #{})),
                        num_questions => length(maps:get(quiz_questions, State, []))
                    }}
            catch
                _:_ -> false
            end
    end.

generate_pin() ->
    integer_to_list(100000 + rand:uniform(900000) - 1).