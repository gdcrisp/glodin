#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).

main(Args) ->
    try dispatch(Args) catch
        throw:{glodin, Message} -> io:format(standard_error, "glodin: ~ts~n", [Message]), halt(1);
        error:Reason:Stack -> io:format(standard_error, "glodin: ~p~n~p~n", [Reason, Stack]), halt(1)
    end.

dispatch(["new", Name]) -> scaffold(Name);
dispatch(["build"]) -> build();
dispatch(["build", "--hook"]) -> build();
dispatch(["generate"]) -> generate();
dispatch(["doctor"]) ->
    lists:foreach(fun(Tool) -> io:format("~s: ~p~n", [Tool, os:find_executable(Tool)]) end,
                  ["odin", "cc", "erl", "escript"]);
dispatch(_) -> fail("usage: gleam run -m glodin -- new MODULE | build | generate | doctor").

fail(Message) -> throw({glodin, Message}).
str(B) when is_binary(B) -> binary_to_list(B);
str(L) when is_list(L) -> L.
env(Key, Default) -> case os:getenv(Key) of false -> Default; Value -> Value end.
root() -> filename:absname(env("GLEAM_PACKAGE_ROOT", ".")).
project_root() -> filename:absname(env("GLEAM_PROJECT_ROOT", root())).
app_name() ->
    {ok, Toml} = file:read_file(filename:join(root(), "gleam.toml")),
    case re:run(Toml, "(?m)^name\\s*=\\s*\"([a-z][a-z0-9_]*)\"", [{capture, [1], list}]) of
        {match, [Name]} -> Name;
        _ -> fail("gleam.toml must contain a package name")
    end.

toolkit() ->
    Here = filename:dirname(filename:absname(escript:script_name())),
    Base = project_root(),
    Candidates = [env("GLODIN_PRIV", ""), Here,
                  filename:join([Base, "build", "packages", "glodin", "priv"])] ++
                 filelib:wildcard(filename:join([Base, "build", "*", "erlang", "glodin", "priv"])),
    case [P || P <- Candidates, filelib:is_file(filename:join([P, "odin", "generator", "main.odin"]))] of
        [P | _] -> filename:absname(P);
        [] -> fail("cannot find Glodin toolkit; compile the glodin dependency or set GLODIN_PRIV")
    end.

run(Executable, Args, Cwd) ->
    Path = case os:find_executable(Executable) of
        false -> fail(io_lib:format("missing executable ~s; install the native toolchain", [Executable]));
        Found -> Found
    end,
    Port = open_port({spawn_executable, Path}, [{args, Args}, {cd, Cwd},
                     binary, use_stdio, stderr_to_stdout, exit_status]),
    collect(Port, []).
collect(Port, Acc) ->
    receive
        {Port, {data, Bytes}} -> collect(Port, [Bytes | Acc]);
        {Port, {exit_status, Status}} ->
            Output = iolist_to_binary(lists:reverse(Acc)),
            case Status of
                0 -> Output;
                _ -> fail(io_lib:format("command exited ~p:~n~ts", [Status, Output]))
            end
    end.

write(Path, Content) ->
    ok = filelib:ensure_dir(Path),
    case file:read_file(Path) of
        {ok, Existing} when Existing =:= Content -> ok;
        _ ->
            Temp = Path ++ ".tmp." ++ integer_to_list(erlang:unique_integer([positive])),
            ok = file:write_file(Temp, Content),
            ok = file:rename(Temp, Path)
    end.

scaffold(Name) ->
    case re:run(Name, "^[a-z][a-z0-9_]*$", [{capture, none}]) of
        match -> ok;
        _ -> fail("module names must be lowercase identifiers")
    end,
    App = app_name(),
    Native = filename:join([root(), "native", Name]),
    case filelib:is_dir(Native) of true -> fail("native module already exists"); false -> ok end,
    Config = #{name => list_to_binary(Name), module => list_to_binary(App ++ "_" ++ Name ++ "_ffi"),
               gleam_module => list_to_binary(App ++ "/" ++ Name), otp_app => list_to_binary(App)},
    write(filename:join(Native, "glodin.json"), iolist_to_binary(json:encode(Config))),
    write(filename:join(Native, "lib.odin"), iolist_to_binary([
        "package ", App, "_", Name, "\n\n@(glodin_nif)\nadd :: proc(a, b: i64) -> i64 {\n\treturn a + b\n}\n"])),
    {ok, Script} = file:read_file(filename:join(toolkit(), "glodin_build.escript")),
    write(filename:join(root(), "glodin_build.escript"), Script),
    TomlPath = filename:join(root(), "gleam.toml"),
    {ok, Toml} = file:read_file(TomlPath),
    WithHook = erlang_array(Toml, "build_hooks", [[<<"escript">>, <<"glodin_build.escript">>, <<"build">>, <<"--hook">>]]),
    WithSources = erlang_array(WithHook, "extra_files", [<<"native">>, <<"glodin_build.escript">>]),
    NewToml = erlang_array(WithSources, "exclude_files", [<<"priv/native">>]),
    write(TomlPath, NewToml),
    generate(),
    io:format("Created native/~s and src/~s/~s.gleam.~nUse the patched Gleam for automatic builds.~n", [Name, App, Name]).

%% Preserve the user's TOML and append to the three known array-valued fields.
%% This scanner tracks strings/comments so brackets in hook arguments are literal.
erlang_array(Toml, Key, Values) ->
    case re:run(Toml, "(?m)^\\[erlang\\][ \\t]*(?:#[^\\n]*)?$", [{capture,[0],index}]) of
        nomatch -> erlang_array(<<Toml/binary,"\n[erlang]\n">>,Key,Values);
        {match,[{Start,Length}]} ->
            Offset = Start + Length,
            Tail = binary:part(Toml,Offset,byte_size(Toml)-Offset),
            End = case re:run(Tail,"(?m)^\\[\\[?[a-zA-Z_][a-zA-Z_0-9.\\\" -]*\\]\\]?[ \\t]*(?:#[^\\n]*)?$",[{capture,[0],index}]) of
                {match,[{Next,_}]} -> Next;
                nomatch -> byte_size(Tail)
            end,
            Body = binary:part(Tail,0,End),
            Encoded = [iolist_to_binary(json:encode(V)) || V <- Values],
            Missing = [V || V <- Encoded, binary:match(Body,V) == nomatch],
            Skip = Key == "build_hooks" andalso binary:match(Body,<<"glodin_build.escript">>) =/= nomatch,
            case Missing == [] orelse Skip of
                true -> Toml;
                false ->
                    Added = iolist_to_binary(lists:join(<<", ">>,Missing)),
                    Updated = case re:run(Body,"(?m)^[ \\t]*" ++ Key ++ "[ \\t]*=[ \\t]*(\\[)",[{capture,[1],index}]) of
                        nomatch -> <<Body/binary,"\n",(list_to_binary(Key))/binary," = [",Added/binary,"]\n">>;
                        {match,[{Open,_}]} ->
                            {Close,Last} = array_close(Body,Open+1,1,normal,false,$[),
                            Before = binary:part(Body,0,Close),
                            After = binary:part(Body,Close,byte_size(Body)-Close),
                            Comma = case Last of $[ -> <<>>; $, -> <<>>; _ -> <<", ">> end,
                            <<Before/binary,Comma/binary,Added/binary,After/binary>>
                    end,
                    Prefix = binary:part(Toml,0,Offset),
                    Rest = binary:part(Tail,End,byte_size(Tail)-End),
                    <<Prefix/binary,Updated/binary,Rest/binary>>
            end
    end.

array_close(Bytes,Pos,_Depth,_Mode,_Escaped,_Last) when Pos >= byte_size(Bytes) -> fail("unterminated build configuration array");
array_close(Bytes,Pos,Depth,Mode,Escaped,Last) ->
    C = binary:at(Bytes,Pos),
    Next = Pos + 1,
    case Mode of
        comment -> array_close(Bytes,Next,Depth,case C of $\n -> normal; _ -> comment end,false,Last);
        double ->
            case {Escaped,C} of
                {true,_} -> array_close(Bytes,Next,Depth,double,false,Last);
                {false,$\\} -> array_close(Bytes,Next,Depth,double,true,Last);
                {false,$"} -> array_close(Bytes,Next,Depth,normal,false,$");
                _ -> array_close(Bytes,Next,Depth,double,false,Last)
            end;
        single -> array_close(Bytes,Next,Depth,case C of $' -> normal; _ -> single end,false,$');
        normal ->
            case C of
                $# -> array_close(Bytes,Next,Depth,comment,false,Last);
                $" -> array_close(Bytes,Next,Depth,double,false,$");
                $' -> array_close(Bytes,Next,Depth,single,false,$');
                $[ -> array_close(Bytes,Next,Depth+1,normal,false,$[);
                $] when Depth == 1 -> {Pos,Last};
                $] -> array_close(Bytes,Next,Depth-1,normal,false,$]);
                _ when C == $\s; C == $\t; C == $\r; C == $\n -> array_close(Bytes,Next,Depth,normal,false,Last);
                _ -> array_close(Bytes,Next,Depth,normal,false,C)
            end
    end.

modules() -> lists:sort(filelib:wildcard(filename:join([root(), "native", "*", "glodin.json"]))).
config(Path) ->
    {ok, Bytes} = file:read_file(Path),
    Map = json:decode(Bytes),
    lists:foreach(fun(Key) ->
        Value = maps:get(Key, Map),
        Pattern = case Key of <<"gleam_module">> -> "^[a-z][a-z0-9_/]*$"; _ -> "^[a-z][a-z0-9_]*$" end,
        case re:run(Value, Pattern, [{capture, none}]) of
            match -> ok;
            _ -> fail(io_lib:format("invalid ~s in ~s", [Key, Path]))
        end
    end, [<<"name">>, <<"module">>, <<"gleam_module">>, <<"otp_app">>]),
    case str(maps:get(<<"name">>, Map)) == filename:basename(filename:dirname(Path)) of
        true -> ok;
        false -> fail("native module name must match its directory")
    end,
    Map.

generator() ->
    Toolkit = toolkit(),
    Cache = filename:join(root(), ".glodin"),
    ok = filelib:ensure_dir(filename:join(Cache, "_")),
    Executable = filename:join(Cache, "generator"),
    Sources = tree(filename:join(Toolkit, "odin/generator")),
    Version = run(env("ODIN", "odin"), ["version"], root()),
    Hash = hash([Version | [read(P) || P <- Sources]]),
    Stamp = Executable ++ ".sha256",
    case {file:read_file(Stamp), filelib:is_file(Executable)} of
        {{ok, Hash}, true} -> ok;
        _ ->
            io:format("  Compiling Glodin generator~n"),
            run(env("ODIN", "odin"), ["build", filename:join(Toolkit, "odin/generator"),
                "-out:" ++ Executable, "-o:speed", "-vet-unused", "-vet-semicolon", "-vet-tabs"], root()),
            write(Stamp, Hash)
    end,
    Executable.

generate() ->
    Gen = generator(),
    Paths = modules(),
    lists:foreach(fun(Path) -> generate_module(Gen, Path, config(Path)) end, Paths),
    cleanup_generated(Paths).
generate_module(Gen, Path, Map) ->
    Native = filename:dirname(Path),
    Args = [Native, root(), str(maps:get(<<"module">>, Map)),
            str(maps:get(<<"gleam_module">>, Map)), str(maps:get(<<"otp_app">>, Map))] ++
           [str(K) ++ "=" ++ filename:absname(str(V), root()) || {K,V} <- maps:to_list(maps:get(<<"collections">>,Map,#{}))],
    Output = run(Gen, Args, root()),
    io:put_chars(Output),
    Loader = filename:join([root(), "src", str(maps:get(<<"module">>, Map)) ++ ".erl"]),
    case filelib:is_file(Loader) of
        true -> ok;
        false -> write(Loader, read(filename:join([root(), ".glodin", filename:basename(Native), "loader.erl"])))
    end.

build() ->
    Paths = modules(),
    Gen = case lists:any(fun(P) -> not maps:get(<<"skip_compilation">>,config(P),false) end,Paths) of
        true -> generator();
        false -> undefined
    end,
    lists:foreach(fun(Path) ->
        Map = config(Path),
        case maps:get(<<"skip_compilation">>,Map,false) of
            true ->
                Binding = filename:join([root(),"src",str(maps:get(<<"gleam_module">>,Map)) ++ ".gleam"]),
                case filelib:is_file(Binding) of
                    true -> ok;
                    false -> fail("supplied binaries require generated Gleam bindings in the package")
                end;
            false -> generate_module(Gen, Path, Map)
        end,
        build_module(Path, Map)
    end, Paths),
    cleanup_generated(Paths).

cleanup_generated(Paths) ->
    Expected = lists:append([begin
        M = config(P),
        [filename:join("src", str(maps:get(<<"gleam_module">>, M)) ++ ".gleam"),
         filename:join("src", str(maps:get(<<"module">>, M)) ++ ".erl")]
    end || P <- Paths]),
    case length(Expected) == length(lists:usort(Expected)) of
        true -> ok;
        false -> fail("native modules have conflicting generated module names")
    end,
    Manifest = filename:join([root(), ".glodin", "generated.json"]),
    Previous = case file:read_file(Manifest) of
        {ok, Bytes} -> [str(P) || P <- json:decode(Bytes)];
        _ -> []
    end,
    lists:foreach(fun(P) ->
        Absolute = filename:absname(P, root()),
        Prefix = filename:join(root(), "src") ++ "/",
        case lists:prefix(Prefix, Absolute) andalso not lists:member(P, Expected) of
            true ->
                case file:read_file(Absolute) of
                    {ok, <<"//// Generated by Glodin.", _/binary>>} -> file:delete(Absolute);
                    {ok, <<"%% Generated by Glodin.", _/binary>>} -> file:delete(Absolute);
                    {ok, <<"% Generated by Glodin.", _/binary>>} -> file:delete(Absolute);
                    _ -> ok
                end;
            false -> ok
        end
    end, Previous),
    write(Manifest, iolist_to_binary(json:encode([list_to_binary(P) || P <- Expected]))).

build_module(Path, Map) ->
    Native = filename:dirname(Path),
    Name = str(maps:get(<<"name">>, Map)),
    Module = str(maps:get(<<"module">>, Map)),
    Cache = filename:join([root(), ".glodin", Name]),
    ok = filelib:ensure_dir(filename:join(Cache, "_")),
    Artifact = filename:join([root(), "priv", "native", Module ++ ".so"]),
    ok = filelib:ensure_dir(Artifact),
    case maps:get(<<"skip_compilation">>, Map, false) of
        true ->
            Source = str(maps:get(<<"artifact">>, Map)),
            Bytes = read(filename:absname(Source, root())),
            write(Artifact, Bytes),
            finalize_loader(Cache, Module, Module, hash(Bytes), Map);
        false ->
            Toolkit = toolkit(),
            Include = filename:absname(str(maps:get(<<"otp_include">>,Map,filename:join(code:root_dir(), "usr/include"))), root()),
            Odin = str(maps:get(<<"odin">>, Map, env("ODIN", "odin"))),
            CC = str(maps:get(<<"cc">>, Map, env("CC", "cc"))),
            CompilerVersion = run(Odin, ["version"], root()),
            CCompilerVersion = run(CC, ["--version"], root()),
            Mode = str(maps:get(<<"mode">>, Map, env("GLEAM_BUILD_MODE", "dev"))),
            %% Conservatively include the whole package: imported local Odin packages,
            %% headers and configuration all invalidate the native artifact.
            Sources = lists:usort(tree(filename:join(root(), "native")) ++ tree(filename:join(Toolkit, "odin")) ++
                                  tree(filename:join(Toolkit, "c")) ++ tree(Include) ++
                                  lists:append([tree(filename:absname(str(P), root())) || P <- maps:get(<<"watch">>, Map, [])])),
            ComputeHash = fun() ->
              AllSources = lists:usort(Sources ++ dependency_files(Cache)),
              hash([CompilerVersion, CCompilerVersion, Mode, erlang:system_info(system_architecture),
                         read(Path), os:getenv("CFLAGS", ""), os:getenv("LDFLAGS", "") |
                         [[P, read(P)] || P <- AllSources]])
            end,
            Hash = ComputeHash(),
            Stamp = filename:join(Cache, "build_" ++ Mode ++ ".sha256"),
            Stem = Module ++ "_" ++ binary_to_list(Hash),
            HashedArtifact = filename:join([root(), "priv", "native", Stem ++ ".so"]),
            FinalHash = case {file:read_file(Stamp), filelib:is_file(HashedArtifact)} of
                {{ok, Hash}, true} -> Hash;
                _ ->
                    io:format("  Compiling Odin NIF ~s~n", [Name]),
                    Object = filename:join(Cache, "shim.o"),
                    prepare_api(Include, Cache),
                    run(CC, ["-std=c11", "-fPIC", "-c", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-I" ++ Include, "-I" ++ Cache, "-I" ++ filename:join(Toolkit, "c"),
                        "-o", Object, filename:join(Cache, "entry.c")] ++
                        [str(X) || X <- maps:get(<<"c_flags">>, Map, [])], root()),
                    Temp = HashedArtifact ++ ".tmp.so",
                    Optimize = case Mode of "prod" -> "-o:speed"; "release" -> "-o:speed"; _ -> "-debug" end,
                    Link = case os:type() of {unix, darwin} -> "-undefined dynamic_lookup"; _ -> "" end,
                    Flags = ["build", Native, "-build-mode:shared", "-no-entry-point", Optimize,
                        "-out:" ++ Temp, "-collection:glodin=" ++ filename:join(Toolkit, "odin"),
                        "-custom-attribute:glodin_nif,glodin_name,glodin_schedule,glodin_codec,glodin_tag,glodin_gleam,glodin_resource,glodin_load,glodin_upgrade,glodin_unload",
                        "-export-dependencies:json", "-export-dependencies-file:" ++ filename:join(Cache, "dependencies.json"),
                        "-collection:glodin_shim=" ++ Cache, "-extra-linker-flags:" ++ Link] ++
                        ["-collection:" ++ str(K) ++ "=" ++ filename:absname(str(V),root()) || {K,V} <- maps:to_list(maps:get(<<"collections">>,Map,#{}))] ++
                        case maps:get(<<"target">>,Map,undefined) of undefined -> []; Target -> ["-target:" ++ str(Target)] end ++
                        [str(X) || X <- maps:get(<<"odin_flags">>, Map, [])],
                    run(Odin, Flags, root()),
                    BuiltHash = ComputeHash(),
                    BuiltArtifact = filename:join([root(), "priv", "native", Module ++ "_" ++ binary_to_list(BuiltHash) ++ ".so"]),
                    ok = file:rename(Temp, BuiltArtifact),
                    write(Stamp, BuiltHash),
                    BuiltHash
            end,
            finalize_loader(Cache, Module, Module ++ "_" ++ binary_to_list(FinalHash), FinalHash, Map)
    end.

dependency_files(Cache) ->
    case file:read_file(filename:join(Cache,"dependencies.json")) of
        {ok, Bytes} ->
            Deps = json:decode(Bytes),
            %% Include directory contents so a newly added platform source is tracked.
            Dirs = lists:usort([filename:dirname(str(P)) || P <- maps:get(<<"source_files">>,Deps,[])]),
            lists:usort(lists:append([filelib:wildcard(filename:join(D,"*.odin")) || D <- Dirs]) ++
                        [str(P) || P <- maps:get(<<"load_files">>,Deps,[]), filelib:is_file(str(P))]);
        _ -> []
    end.

finalize_loader(Cache, Module, Stem, Hash, Map) ->
    Loader = case file:read_file(filename:join(Cache,"loader.erl")) of
        {ok, Template} -> Template;
        _ -> read(filename:join([root(),"src",Module ++ ".erl"]))
    end,
    Replacement = iolist_to_binary(["\"native\", \"", Stem, "\""]),
    Named = re:replace(Loader, "\"native\", \"[a-z0-9_]+\"", Replacement, [{return,binary}]),
    Versioned = re:replace(Named, "-vsn\\(\"[^\"]*\"\\)\\.", iolist_to_binary(["-vsn(\"", Hash, "\")."]), [{return,binary}]),
    LoadData = case maps:get(<<"load_data_fun">>, Map, undefined) of
        undefined -> io_lib:format("~p", [maps:get(<<"load_data">>, Map, 0)]);
        [M, F] ->
            lists:foreach(fun(X) ->
                case re:run(X,"^[a-z][a-z0-9_]*$",[{capture,none}]) of
                    match -> ok; _ -> fail("load_data_fun requires module and function identifiers") end
            end,[M,F]),
            [M, ":", F, "()"]
    end,
    Final = binary:replace(Versioned, <<"erlang:load_nif(Path, 0)">>, iolist_to_binary(["erlang:load_nif(Path, ", LoadData, ")"])),
    write(filename:join([root(), "src", Module ++ ".erl"]), Final).

prepare_api(Include, Cache) ->
    Header = read(filename:join(Include, "erl_nif_api_funcs.h")),
    {match, Matches} = re:run(Header, "ERL_NIF_API_FUNC_DECL\\([^,]*,\\s*(enif_[a-z0-9_]+)",
                             [global, {capture, [1], binary}]),
    Code = [["if (strcmp(name, \"", Name, "\") == 0) return (void *)(", Name, ");\n"] || [Name] <- Matches],
    write(filename:join(Cache, "glodin_api_lookup.inc"), iolist_to_binary(Code)).

read(Path) -> case file:read_file(Path) of {ok, Bytes} -> Bytes; {error, E} -> fail(io_lib:format("~s: ~p", [Path, E])) end.
tree(Path) ->
    case filelib:is_dir(Path) of
        false -> case filelib:is_file(Path) of true -> [Path]; false -> [] end;
        true ->
            {ok, Names} = file:list_dir(Path),
            lists:append([tree(filename:join(Path, N)) || N <- lists:sort(Names),
                          N =/= ".git", N =/= ".glodin", N =/= "build", N =/= "native.tmp"])
    end.
hash(Data) -> binary:encode_hex(crypto:hash(sha256, Data), lowercase).
