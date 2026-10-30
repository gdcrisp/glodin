#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).

%% This entry point must work before the application can compile, including
%% immediately after a clean checkout with no build/ directory.
main(Args) ->
    Root = filename:absname("."),
    Gleam = case os:getenv("GLEAM") of false -> "gleam"; G -> G end,
    Override = case os:getenv("GLODIN_PRIV") of false -> []; P -> [P] end,
    Info = capture(Gleam,["export","package-information"]),
    Config = maps:get(<<"gleam.toml">>,json:decode(Info)),
    Dependency = maps:get(<<"glodin">>,maps:get(<<"dependencies">>,Config,#{}),#{}),
    Local = case maps:get(<<"path">>,Dependency,undefined) of
        undefined -> [];
        LocalPath -> [filename:join(filename:absname(binary_to_list(LocalPath),Root),"priv")]
    end,
    Candidates = Override ++ Local ++ [filename:join([Root,"build","packages","glodin","priv"])] ++
                 filelib:wildcard(filename:join([Root,"build","*","erlang","glodin","priv"])),
    Scripts = fun() -> [filename:join(P1,"glodin.escript") || P1 <- Candidates,
                       filelib:is_file(filename:join(P1,"glodin.escript"))] end,
    case Scripts() of
        [] -> execute(Gleam,["deps","download"]);
        _ -> ok
    end,
    case Scripts() of
        [Script|_] -> execute("escript",[Script|Args]);
        [] -> io:format(standard_error,"glodin: toolkit not found; add glodin as a direct dependency~n",[]),halt(1)
    end.

capture(Executable,Args) ->
    Port = open_port({spawn_executable,os:find_executable(Executable)},[{args,Args},binary,use_stdio,stderr_to_stdout,exit_status]),
    capture_output(Port,[]).

capture_output(Port,Acc) ->
    receive
        {Port,{data,Data}} -> capture_output(Port,[Data|Acc]);
        {Port,{exit_status,0}} -> iolist_to_binary(lists:reverse(Acc));
        {Port,{exit_status,Status}} -> io:put_chars(lists:reverse(Acc)),halt(Status)
    end.

execute(Executable,Args) ->
    case os:find_executable(Executable) of
        false -> io:format(standard_error,"glodin: missing executable ~s~n",[Executable]),halt(1);
        Path ->
            Port = open_port({spawn_executable,Path},[{args,Args},binary,use_stdio,stderr_to_stdout,exit_status]),
            wait(Port)
    end.

wait(Port) ->
    receive
        {Port,{data,Data}} -> io:put_chars(Data),wait(Port);
        {Port,{exit_status,0}} -> ok;
        {Port,{exit_status,Code}} -> halt(Code)
    end.
