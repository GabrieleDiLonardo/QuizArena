-module(quizarena_gateway).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% Punto di ingresso dei nodi Java. Il gateway non esegue le richieste:
%% per ognuna avvia un processo dedicato, cosi' una room lenta o una
%% transazione Mnesia non bloccano le richieste degli altri utenti.
%% L'identita' del client resta il pid della sua mailbox Java (JavaPid),
%% che viene passato esplicitamente alle room.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({JavaPid, Ref, Request}, State)
  when is_pid(JavaPid), is_reference(Ref) ->
    _ = spawn(fun() ->
        JavaPid ! {Ref, safe_call(fun() -> handle_request(Request, JavaPid) end)}
    end),
    {noreply, State};

handle_info(_Message, State) ->
    {noreply, State}.

%% ---------- Richieste ----------

handle_request(ping, _JavaPid) ->
    {ok, pong};

%% Autenticazione
handle_request({register_user, Username, Password}, _JavaPid) ->
    quizarena_auth:register(Username, Password);
handle_request({authenticate_user, Username, Password}, _JavaPid) ->
    quizarena_auth:authenticate(Username, Password);

%% Quiz
handle_request({list_owned_quizzes, Owner}, _JavaPid)
  when is_list(Owner) ->
    quizarena_db:list_quizzes_by_owner(Owner);
handle_request({list_browsable_quizzes, Username}, _JavaPid)
  when is_list(Username) ->
    quizarena_db:list_browsable_quizzes(Username);
handle_request({get_owned_quiz, Owner, QuizId}, _JavaPid)
  when is_list(Owner), is_tuple(QuizId) ->
    quizarena_db:get_quiz(Owner, QuizId);
handle_request({create_quiz, Owner, Quiz}, _JavaPid)
  when is_list(Owner), is_map(Quiz) ->
    quizarena_db:create_quiz(Owner, Quiz);
handle_request({update_quiz, Owner, QuizId, Quiz}, _JavaPid)
  when is_list(Owner), is_tuple(QuizId), is_map(Quiz) ->
    quizarena_db:update_quiz(Owner, QuizId, Quiz);
handle_request({delete_quiz, Owner, QuizId}, _JavaPid)
  when is_list(Owner), is_tuple(QuizId) ->
    quizarena_db:delete_quiz(Owner, QuizId);
handle_request({get_history, User}, _JavaPid)
  when is_list(User) ->
    case quizarena_db:get_history(User) of
        {error, Reason} -> {error, Reason};
        History when is_list(History) -> {ok, History}
    end;

%% Stanze
handle_request({create_room, QuizId, HostUsername, Visibility}, JavaPid)
  when is_tuple(QuizId), is_list(HostUsername),
       (Visibility =:= public orelse Visibility =:= private) ->
    quizarena_rooms:create(QuizId, HostUsername, JavaPid, Visibility);
handle_request({create_room, QuizId, HostUsername}, JavaPid)
  when is_tuple(QuizId), is_list(HostUsername) ->
    quizarena_rooms:create(QuizId, HostUsername, JavaPid, public);
handle_request({cancel_room, Pin}, JavaPid) when is_list(Pin) ->
    room_gen_server:cancel(Pin, JavaPid);
handle_request(list_rooms, _JavaPid) ->
    quizarena_db:list_public_rooms();
handle_request(subscribe_lobby, JavaPid) ->
    quizarena_lobby:subscribe(JavaPid);

%% Logout
handle_request({revoke_token, Jti, ExpiresAt}, _JavaPid)
  when is_list(Jti), is_integer(ExpiresAt) ->
    quizarena_db:revoke_token(Jti, ExpiresAt);
handle_request(subscribe_revocations, JavaPid) ->
    quizarena_revocations:subscribe(JavaPid);

%% Gioco
handle_request({join, Pin, Username}, JavaPid)
  when is_list(Pin), is_list(Username) ->
    room_gen_server:join(Pin, Username, JavaPid);
handle_request({rejoin, Pin, Username}, JavaPid)
  when is_list(Pin), is_list(Username) ->
    room_gen_server:rejoin(Pin, Username, JavaPid);
handle_request({host_rejoin, Pin, Username}, JavaPid)
  when is_list(Pin), is_list(Username) ->
    room_gen_server:host_rejoin(Pin, Username, JavaPid);
handle_request({disconnect, Pin}, JavaPid) when is_list(Pin) ->
    room_gen_server:disconnect(Pin, JavaPid);
handle_request({start_game, Pin}, JavaPid) when is_list(Pin) ->
    room_gen_server:start_game(Pin, JavaPid);
handle_request({next_round, Pin}, JavaPid) when is_list(Pin) ->
    room_gen_server:next_round(Pin, JavaPid);
handle_request({answer, Pin, Round, Answer, ClientElapsedMs, RttMs}, JavaPid)
  when is_list(Pin), is_integer(Round), is_list(Answer),
       is_integer(ClientElapsedMs), ClientElapsedMs >= 0,
       is_integer(RttMs), RttMs >= 0 ->
    room_gen_server:answer(Pin, JavaPid, Round, Answer,
                           ClientElapsedMs, RttMs);
handle_request({end_game, Pin}, JavaPid) when is_list(Pin) ->
    room_gen_server:end_game(Pin, JavaPid);
handle_request({get_events_since, Pin, SinceSeq}, _JavaPid)
  when is_list(Pin), is_integer(SinceSeq) ->
    room_gen_server:get_events_since(Pin, SinceSeq);
handle_request({get_player_state, Pin, Username}, _JavaPid)
  when is_list(Pin), is_list(Username) ->
    room_gen_server:get_player_state(Pin, Username);

handle_request(_Request, _JavaPid) ->
    {error, unsupported_request}.

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
        exit:{normal, _} -> {error, room_not_found};
        exit:Reason -> {error, {call_failed, Reason}};
        Class:Reason -> {error, {call_failed, {Class, Reason}}}
    end.
