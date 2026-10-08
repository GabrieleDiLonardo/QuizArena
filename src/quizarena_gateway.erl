-module(quizarena_gateway).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(PIN_GENERATION_ATTEMPTS, 20).

%% Avvia e registra il gateway come processo gen_server
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Inizializza lo stato, la funzione è richiesta da gen_server
init([]) ->
    {ok, #{}}.

%% Rifiuta le chiamate sincrone gen_server, non usate dal protocollo Java
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

%% Ignora le richieste asincrone gen_server, non usate dal protocollo Java
handle_cast(_Request, State) ->
    {noreply, State}.

%% Le funzioni successive gestiscono i messaggi applicativi ricevuti tramite il protocollo Java-Erlang
%% Test per verificare che il gateway comunichi con Java
handle_info({JavaPid, Ref, ping}, State)
  when is_pid(JavaPid), is_reference(Ref) ->
    JavaPid ! {Ref, {ok, pong}},
    {noreply, State};

%% Recupera dal database la lista dei quiz e la restituisce a Java
handle_info({JavaPid, Ref, list_quizzes}, State)
  when is_pid(JavaPid), is_reference(Ref) ->
    Result =
        case quizarena_db:list_quizzes() of
            {error, Reason} ->
                {error, Reason};
            Quizzes when is_list(Quizzes) ->
                {ok, Quizzes}
        end,
    JavaPid ! {Ref, Result},
    {noreply, State};

handle_info({JavaPid, Ref, {create_room, QuizId, HostName}}, State)
  when is_pid(JavaPid), is_reference(Ref),
       is_tuple(QuizId), is_list(HostName) ->
    Result = create_room(QuizId, HostName, JavaPid),
    JavaPid ! {Ref, Result},
    {noreply, State};

handle_info({JavaPid, Ref, {create_room, _QuizId, _HostName}}, State)
  when is_pid(JavaPid), is_reference(Ref) ->
    JavaPid ! {Ref, {error, invalid_request}},
    {noreply, State};

handle_info({JavaPid, Ref, {cancel_room, Pin}}, State)
  when is_pid(JavaPid), is_reference(Ref), is_list(Pin) ->
    Result = cancel_room(Pin, JavaPid),
    JavaPid ! {Ref, Result},
    {noreply, State};

handle_info({JavaPid, Ref, {cancel_room, _Pin}}, State)
  when is_pid(JavaPid), is_reference(Ref) ->
    JavaPid ! {Ref, {error, invalid_request}},
    {noreply, State};

handle_info({JavaPid, Ref, {start_game, Pin}}, State)
  when is_pid(JavaPid), is_reference(Ref), is_list(Pin) ->
    Result = start_game(Pin, JavaPid),
    JavaPid ! {Ref, Result},
    {noreply, State};

handle_info({JavaPid, Ref, {start_game, _Pin}}, State)
  when is_pid(JavaPid), is_reference(Ref) ->
    JavaPid ! {Ref, {error, invalid_request}},
    {noreply, State};

%% Restituisce un errore quando Java richiede un'operazione non supportata
handle_info({JavaPid, Ref, _Request}, State)
  when is_pid(JavaPid), is_reference(Ref) ->
    JavaPid ! {Ref, {error, unsupported_request}},
    {noreply, State};

%% Ignora i messaggi che non rispettano il formato del protocollo
handle_info(_Message, State) ->
    {noreply, State}.

%% Avvia la creazione della stanza
create_room(QuizId, HostName, HostPid) ->
    try_create_room(QuizId, HostName, HostPid,
                    ?PIN_GENERATION_ATTEMPTS).

try_create_room(_QuizId, _HostName, _HostPid, 0) ->
    {error, pin_generation_failed};
try_create_room(QuizId, HostName, HostPid, AttemptsLeft) ->
    Pin = generate_pin(),
    case global:whereis_name({room, Pin}) of
        undefined ->
            open_session_and_start_room(
                Pin, QuizId, HostName, HostPid, AttemptsLeft
            );
        _RoomPid ->
            try_create_room(
                QuizId, HostName, HostPid, AttemptsLeft - 1
            )
    end.

%% Crea la sessione in Mnesia e poi avvia il processo che gestisce la stanza
open_session_and_start_room(Pin, QuizId, HostName, HostPid,
                            AttemptsLeft) ->
    case quizarena_db:open_session(Pin, QuizId, HostName) of
        {ok, _QuestionCount} ->
            case safe_start_room(Pin, HostPid) of
                {ok, _RoomPid} ->
                    {ok, Pin};
                {error, {room_already_registered, Pin}} ->
                    retry_after_rollback(
                        Pin, QuizId, HostName, HostPid, AttemptsLeft
                    );
                {error, Reason} ->
                    room_start_error_after_rollback(Pin, Reason)
            end;
        {error, pin_taken} ->
            try_create_room(
                QuizId, HostName, HostPid, AttemptsLeft - 1
            );
        {error, Reason} ->
            {error, Reason}
    end.

safe_start_room(Pin, HostPid) ->
    try room_sup:start_room(Pin, HostPid) of
        Result -> Result
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

%% Annulla la sessione se il PIN è stato registrato nel frattempo e riprova con un nuovo PIN
retry_after_rollback(Pin, QuizId, HostName, HostPid, AttemptsLeft) ->
    case quizarena_db:abort_session(Pin) of
        ok ->
            try_create_room(
                QuizId, HostName, HostPid, AttemptsLeft - 1
            );
        {error, RollbackReason} ->
            {error, {rollback_failed, RollbackReason}}
    end.

%% Annulla la sessione se la stanza non parte e restituisce l'errore di avvio
room_start_error_after_rollback(Pin, StartReason) ->
    case quizarena_db:abort_session(Pin) of
        ok ->
            {error, {room_start_failed, StartReason}};
        {error, RollbackReason} ->
            {error, {
                room_start_failed,
                StartReason,
                rollback_failed,
                RollbackReason
            }}
    end.

cancel_room(Pin, HostPid) ->
    try room_gen_server:cancel(Pin, HostPid) of
        ok -> {ok, cancelled};
        {error, Reason} -> {error, Reason}
    catch
        exit:{noproc, _} -> {error, room_not_found};
        exit:Reason -> {error, {room_call_failed, Reason}}
    end.

start_game(Pin, HostPid) ->
    try room_gen_server:start_game(Pin, HostPid) of
        ok -> {ok, started};
        {error, Reason} -> {error, Reason}
    catch
        exit:{noproc, _} -> {error, room_not_found};
        exit:Reason -> {error, {room_call_failed, Reason}}
    end.

%% Genera un PIN casuale di sei cifre
generate_pin() ->
    integer_to_list(100000 + rand:uniform(900000) - 1).
