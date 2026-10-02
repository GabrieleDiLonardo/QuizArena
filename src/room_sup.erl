-module(room_sup).
-behaviour(supervisor).

-export([start_link/0, start_room/2, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% Avvia un room process per un PIN. Il QuizId non serve: le domande
%% sono già nello snapshot `session_questions`.
start_room(Pin, HostPid) ->
    supervisor:start_child(?MODULE, [Pin, HostPid]).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 10,
                 period => 10},
    ChildSpec = #{id => room_gen_server,
                  start => {room_gen_server, start_link, []},
                  restart => temporary,
                  shutdown => 5000,
                  type => worker,
                  modules => [room_gen_server]},
    {ok, {SupFlags, [ChildSpec]}}.