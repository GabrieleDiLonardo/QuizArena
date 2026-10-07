-module(quizarena_gateway).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

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

%% Restituisce un errore quando Java richiede un'operazione non supportata
handle_info({JavaPid, Ref, _Request}, State)
  when is_pid(JavaPid), is_reference(Ref) ->
    JavaPid ! {Ref, {error, unsupported_request}},
    {noreply, State};

%% Ignora i messaggi che non rispettano il formato del protocollo
handle_info(_Message, State) ->
    {noreply, State}.
