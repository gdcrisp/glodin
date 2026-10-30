-module(glodin_cli).
-export([main/0]).

main() ->
    Priv = case code:priv_dir(glodin) of
        {error, Reason} -> erlang:error({glodin_not_installed, Reason});
        Path -> Path
    end,
    Script = filename:join(Priv, "glodin.escript"),
    Port = open_port({spawn_executable, os:find_executable("escript")},
                     [{args, [Script | init:get_plain_arguments()]}, binary,
                      use_stdio, stderr_to_stdout, exit_status]),
    wait(Port).

wait(Port) ->
    receive
        {Port, {data, Data}} -> io:put_chars(Data), wait(Port);
        {Port, {exit_status, 0}} -> ok;
        {Port, {exit_status, Status}} -> erlang:halt(Status)
    end.
