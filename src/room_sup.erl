-module(room_sup).
-behaviour(supervisor).

-export([start_link/0, start_room/1, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_room(Args) when is_map(Args) ->
    supervisor:start_child(?MODULE, [Args]).

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
