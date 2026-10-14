-module(quizarena_revocations).
-behaviour(gen_server).

%% Notifica ai Tomcat i token revocati con il logout.
%%
%% Ogni Tomcat tiene in memoria l'elenco dei token revocati e si iscrive a
%% questo processo su uno dei nodi Erlang. Il processo osserva la tabella
%% Mnesia revoked_tokens (replicata su tutti i nodi), quindi vede anche i
%% logout ricevuti dagli altri Tomcat, e li inoltra agli iscritti: ognuno
%% chiude le sessioni e le WebSocket aperte con quel token.
%%
%% Gli iscritti sono linkati: se questo nodo cade, il Tomcat riceve l'uscita
%% del link e si iscrive su un altro nodo, ricaricando l'elenco completo.

-export([start_link/0, subscribe/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Iscrive la mailbox e restituisce i token attualmente revocati.
subscribe(Pid) ->
    gen_server:call(?MODULE, {subscribe, Pid}).

init([]) ->
    process_flag(trap_exit, true),
    {ok, _} = mnesia:subscribe({table, revoked_tokens, simple}),
    {ok, #{subscribers => #{}}}.

handle_call({subscribe, Pid}, _From, State) when is_pid(Pid) ->
    link(Pid),
    Subscribers = maps:put(Pid, true, maps:get(subscribers, State)),
    {reply, quizarena_db:list_revoked_tokens(),
     State#{subscribers => Subscribers}}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({mnesia_table_event, {write, {revoked_tokens, Jti, _Exp}, _}},
            State) ->
    Event = {event, #{type => token_revoked, jti => Jti}},
    [Pid ! Event || Pid <- maps:keys(maps:get(subscribers, State))],
    {noreply, State};

handle_info({'EXIT', Pid, _Reason}, State) ->
    {noreply, State#{subscribers => maps:remove(
                         Pid, maps:get(subscribers, State))}};

handle_info(_Info, State) ->
    {noreply, State}.
