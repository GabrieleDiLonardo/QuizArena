-module(quizarena_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 5,
                 period => 10},
    Children = [
        #{id => room_sup,
          start => {room_sup, start_link, []},
          restart => permanent,
          shutdown => infinity,
          type => supervisor,
          modules => [room_sup]}
    ],
    {ok, {SupFlags, Children}}.