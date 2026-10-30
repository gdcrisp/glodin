#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).
main(Args) ->
    Root = case os:getenv("GLEAM_PROJECT_ROOT") of false -> filename:absname("."); P -> P end,
    Override = case os:getenv("GLODIN_PRIV") of false -> []; P0 -> [P0] end,
    Candidates = Override ++ filelib:wildcard(filename:join([Root,"build","*","erlang","glodin","priv"])) ++
                 [filename:join([Root,"build","packages","glodin","priv"])],
    case [filename:join(P1,"glodin.escript") || P1 <- Candidates,
          filelib:is_file(filename:join(P1,"glodin.escript"))] of
        [Script|_] ->
            Port = open_port({spawn_executable,os:find_executable("escript")},
                [{args,[Script|Args]},binary,use_stdio,stderr_to_stdout,exit_status]),
            wait(Port);
        [] -> io:format(standard_error,"glodin: toolkit not found; add glodin as a direct dependency~n",[]),halt(1)
    end.
wait(Port) ->
    receive
        {Port,{data,Data}} -> io:put_chars(Data),wait(Port);
        {Port,{exit_status,Code}} -> halt(Code)
    end.
