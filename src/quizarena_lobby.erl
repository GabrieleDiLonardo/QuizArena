-module(quizarena_lobby).
-behaviour(gen_server).

%% Aggiornamenti della lobby inviati dal server (push) invece che richiesti
%% periodicamente dai client.
%%
%% Ogni nodo esegue questo processo. Si iscrive agli eventi Mnesia della
%% tabella open_rooms (replicata su tutti i nodi), quindi vede anche le
%% stanze ospitate dagli altri nodi. Quando la tabella cambia invia la lista
%% aggiornata delle stanze pubbliche alle mailbox Java iscritte da questo
%% nodo. Le modifiche ravvicinate (es. molti ingressi in pochi istanti) sono
%% accorpate in un unico invio.
%%
%% Gli iscritti sono linkati, come le mailbox dei giocatori nelle room: la
%% chiusura della mailbox (pagina chiusa) arriva come 'EXIT'.

-export([start_link/0, subscribe/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(COALESCE_MS, 300).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Iscrive la mailbox e restituisce la lista corrente delle stanze.
subscribe(Pid) ->
    gen_server:call(?MODULE, {subscribe, Pid}).

init([]) ->
    process_flag(trap_exit, true),
    {ok, _} = mnesia:subscribe({table, open_rooms, simple}),
    {ok, #{subscribers => #{}, pending => false, last => undefined}}.

handle_call({subscribe, Pid}, _From, State) when is_pid(Pid) ->
    link(Pid),
    Subscribers = maps:put(Pid, true, maps:get(subscribers, State)),
    {ok, Rooms} = quizarena_db:list_public_rooms(),
    {reply, {ok, Rooms}, State#{subscribers => Subscribers}}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({mnesia_table_event, _Event}, #{pending := true} = State) ->
    {noreply, State};
handle_info({mnesia_table_event, _Event}, State) ->
    erlang:send_after(?COALESCE_MS, self(), push),
    {noreply, State#{pending => true}};

handle_info(push, State) ->
    {ok, Rooms} = quizarena_db:list_public_rooms(),
    Sorted = lists:sort(Rooms),
    case Sorted =:= maps:get(last, State) of
        true ->
            ok;
        false ->
            Event = {event, #{type => lobby_update, rooms => Rooms}},
            [Pid ! Event || Pid <- maps:keys(maps:get(subscribers, State))]
    end,
    {noreply, State#{pending => false, last => Sorted}};

handle_info({'EXIT', Pid, _Reason}, State) ->
    {noreply, State#{subscribers => maps:remove(
                         Pid, maps:get(subscribers, State))}};

handle_info(_Info, State) ->
    {noreply, State}.
