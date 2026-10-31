#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).

main(Args) ->
    try dispatch(Args) catch
        throw:{glodin, Message} -> io:format(standard_error, "glodin: ~ts~n", [Message]), halt(1);
        throw:{exit_status, Status} -> halt(Status);
        error:Reason:Stack -> io:format(standard_error, "glodin: ~p~n~p~n", [Reason, Stack]), halt(1)
    end.

dispatch(["new", Name]) -> scaffold(Name);
dispatch(["init"]) -> install_wrapper();
dispatch(["native-build"]) -> build();
dispatch(["native-generate"]) ->
    case modules() of [] -> ok; _ -> generate() end;
dispatch(["doctor"]) -> doctor();
dispatch(["--help"]) -> usage();
dispatch(["help"]) -> usage();
dispatch([]) -> usage();
dispatch(Args) -> workflow(Args).

gleam() -> env("GLEAM", "gleam").

%% The wrapper is deliberately independent of Gleam compilation: declarations
%% and loaders must exist before Gleam discovers or checks application modules.
workflow([Command | Args]) when Command == "build"; Command == "run"; Command == "test" ->
    ensure_erlang(Args),
    prepare_native("native-build", "dev"),
    forward(gleam(), [Command | Args], root());
workflow(["generate"]) -> prepare_native("native-generate", "dev");
workflow(["export", "erlang-shipment"]) ->
    prepare_native("native-build", "prod"),
    forward(gleam(), ["export", "erlang-shipment"], root());
workflow(["export", "hex-tarball"]) -> source_release(false, []);
workflow(["publish" | Args]) -> source_release(true, Args);
workflow(_) -> usage(), fail("unsupported command; see the usage above").

ensure_erlang(["--" | _]) -> ok;
ensure_erlang([Flag, "javascript" | _]) when Flag == "--target"; Flag == "-t" ->
    fail("Glodin supports only the Erlang target");
ensure_erlang(["--target=javascript" | _]) -> fail("Glodin supports only the Erlang target");
ensure_erlang([_ | Args]) -> ensure_erlang(Args);
ensure_erlang([]) -> ok.

prepare_native(Command, Mode) ->
    forward(gleam(), ["deps", "download"], root()),
    {Packages, _} = with_env([{"GLODIN_BUILD_MODE", Mode}], fun() -> package_order(root(), true, #{}, []) end),
    Toolkit = toolkit(),
    lists:foreach(fun(Package) ->
        case filelib:wildcard(filename:join([Package,"priv","glodin","native","*","glodin.json"])) of
            [] -> ok;
            _ ->
                with_env([{"GLODIN_PACKAGE_ROOT", Package}, {"GLODIN_PROJECT_ROOT", root()},
                          {"GLODIN_PRIV", Toolkit}, {"GLODIN_BUILD_MODE", Mode}], fun() ->
                    forward("escript", [filename:join(Toolkit,"glodin.escript"), Command], Package)
                end)
        end
    end, Packages).

package_info(Package) ->
    maps:get(<<"gleam.toml">>, json:decode(run(gleam(), ["export","package-information"], Package))).

%% Hex and Git packages are resolved by Gleam into the root build/packages.
%% Path requirements are relative to the package declaring the requirement.
package_order(Package0, IsRoot, Seen, Order) ->
    Package = absolute(Package0),
    case maps:get(Package, Seen, unseen) of
        done -> {Order, Seen};
        visiting -> fail("cyclic package dependency");
        unseen ->
            Info = package_info(Package),
            Deps = maps:get(<<"dependencies">>, Info, #{}),
            All = case IsRoot andalso env("GLODIN_BUILD_MODE", "dev") =/= "prod" of
                true -> maps:merge(Deps, maps:get(<<"dev_dependencies">>, Info, #{}));
                false -> Deps
            end,
            {Previous, Visited} = lists:foldl(fun({Name, Requirement}, {Acc, State}) ->
                Dependency = case maps:get(<<"path">>, Requirement, undefined) of
                    undefined -> filename:join([root(), "build", "packages", str(Name)]);
                    Path -> filename:absname(str(Path), Package)
                end,
                case filelib:is_file(filename:join(Dependency,"gleam.toml")) of
                    true -> package_order(Dependency, false, State, Acc);
                    false -> {Acc, State} % Non-Gleam packages cannot contain Glodin modules.
                end
            end, {Order, Seen#{Package => visiting}}, lists:sort(maps:to_list(All))),
            {Previous ++ [Package], Visited#{Package => done}}
    end.

with_env(Values, Fun) ->
    Previous = [{Key, os:getenv(Key)} || {Key,_} <- Values],
    lists:foreach(fun({Key,Value}) -> os:putenv(Key, Value) end, Values),
    try Fun() after
        lists:foreach(fun({Key,false}) -> os:unsetenv(Key);
                         ({Key,Value}) -> os:putenv(Key,Value) end, Previous)
    end.

absolute(Path) ->
    Parts = lists:foldl(fun(".", Acc) -> Acc;
                          ("..", [_]) -> ["/"];
                          ("..", [_|Acc]) -> Acc;
                          (Part, Acc) -> [Part|Acc] end, [], filename:split(filename:absname(Path))),
    filename:join(lists:reverse(Parts)).

inside(Path, Directory) ->
    A = absolute(Path), D = absolute(Directory),
    lists:prefix(filename:split(D), filename:split(A)).

%% Stock Gleam includes all of priv, including ignored binaries. Always export
%% native source packages from a separate source-only tree, never by deleting
%% artifacts from the working application.
source_release(Publish, Args) ->
    with_env([{"GLODIN_BUILD_MODE", "prod"}], fun() -> prepare_native("native-build", "prod") end),
    validate_sources(),
    Stage = filename:join([root(), ".glodin", "release_" ++ str(binary:encode_hex(crypto:strong_rand_bytes(12)))]),
    ok = filelib:ensure_dir(filename:join(Stage,"_")),
    try
        lists:foreach(fun(Name) ->
            Source = filename:join(root(),Name),
            case filelib:is_file(Source) orelse filelib:is_dir(Source) of
                true -> copy_source(Source, filename:join(Stage,Name));
                false -> ok
            end
        end, ["gleam.toml", "manifest.toml", "README", "README.md", "README.txt", "LICENSE", "LICENSE.md", "LICENSE.txt",
              "LICENCE", "LICENCE.md", "LICENCE.txt", "NOTICE", "NOTICE.md", "NOTICE.txt", "src", "priv", "docs"]),
        %% Generate afresh so archived loaders never embed this host's artifact hash.
        with_env([{"GLODIN_PACKAGE_ROOT", Stage}, {"GLODIN_PRIV", toolkit()}], fun() ->
            case modules() of [] -> ok; _ -> generate() end
        end),
        forward(gleam(), ["export","hex-tarball"], Stage),
        Info = package_info(Stage),
        Name = str(maps:get(<<"name">>,Info)), Version = str(maps:get(<<"version">>,Info)),
        Archive = Name ++ "-" ++ Version ++ ".tar",
        Destination = filename:join([root(),"build",Archive]),
        write(Destination, read(filename:join([Stage,"build",Archive]))),
        io:format("Verified source archive: ~s~n", [Destination]),
        case Publish of
            true -> forward(gleam(), ["publish" | Args], Stage);
            false -> ok
        end
    after file:del_dir_r(Stage) end.

copy_source(Source, Destination) ->
    case file:read_link(Source) of
        {ok,_} -> fail(io_lib:format("source releases cannot contain symlinks: ~s",[Source]));
        _ -> ok
    end,
    Name = filename:basename(Source),
    Excluded = lists:member(Name,["native", "build", ".glodin", ".git", ".jj", "__pycache__"])
        andalso (Name =/= "native" orelse absolute(Source) == absolute(filename:join([root(),"priv","native"]))),
    Binary = lists:member(filename:extension(Name),[".so",".dylib",".o",".a",".dll",".pdb",".lib",".exp",".beam",".pyc",".dSYM"]),
    case Excluded orelse Binary of
        true -> ok;
        false ->
            case filelib:is_dir(Source) of
                true ->
                    {ok, Names} = file:list_dir(Source),
                    lists:foreach(fun(N) -> copy_source(filename:join(Source,N),filename:join(Destination,N)) end,Names);
                false -> write(Destination,read(Source))
            end
    end.

validate_sources() ->
    case modules() of
        [] -> ok;
        Paths ->
            OdinRoot = string:trim(str(run(env("ODIN","odin"),["root"],root()))),
            lists:foreach(fun(Path) ->
                Map = config(Path),
                case maps:get(<<"skip_compilation">>,Map,false) of
                    true -> fail("publishing supplied binary packages is not supported; publish native sources");
                    false -> ok
                end,
                Values = maps:values(maps:get(<<"collections">>,Map,#{})) ++ maps:get(<<"watch">>,Map,[]),
                lists:foreach(fun(P) -> require_packaged(filename:absname(str(P),root())) end,Values),
                Cache = filename:join([root(),".glodin",str(maps:get(<<"name">>,Map))]),
                {ok,Bytes} = file:read_file(filename:join(Cache,"dependencies.json")),
                Deps = json:decode(Bytes),
                Files = maps:get(<<"source_files">>,Deps,[]) ++ maps:get(<<"load_files">>,Deps,[]),
                lists:foreach(fun(P) ->
                    File = str(P),
                    case inside(File,OdinRoot) orelse inside(File,toolkit()) orelse
                         inside(File,filename:join(root(),".glodin")) of
                        true -> ok;
                        false -> require_packaged(File)
                    end
                end,Files)
            end,Paths)
    end.

require_packaged(Path) ->
    case inside(Path,filename:join(root(),"priv")) andalso
         not inside(Path,filename:join([root(),"priv","native"])) of
        true -> ok;
        false -> fail(io_lib:format("native source dependency must be packaged under priv/: ~s",[Path]))
    end.

doctor() ->
    lists:foreach(fun({Name,Args}) ->
        Output = run(Name, Args, root()), io:format("~s: ~ts~n",[Name,Output])
    end,[{gleam(),["--version"]},{env("ODIN","odin"),["version"]},{env("CC","cc"),["--version"]}]),
    io:format("OTP: ~s~nNIF headers: ~s~n",[erlang:system_info(otp_release),filename:join(code:root_dir(),"usr/include")]).

forward(Executable, Args, Cwd) ->
    Path = case os:find_executable(Executable) of
        false -> fail(io_lib:format("missing executable ~s",[Executable]));
        Found -> Found
    end,
    Port = open_port({spawn_executable,Path},[{args,Args},{cd,Cwd},binary,use_stdio,stderr_to_stdout,exit_status]),
    forward_output(Port).

forward_output(Port) ->
    receive
        {Port,{data,Bytes}} -> io:put_chars(Bytes), forward_output(Port);
        {Port,{exit_status,0}} -> ok;
        {Port,{exit_status,Status}} -> throw({exit_status,Status})
    end.

usage() ->
    io:format("Glodin 0.1.0 (stock Gleam, Erlang target)~n"
              "Bootstrap: gleam run -m glodin -- init | new MODULE~n"
              "Usage: escript glodin_build.escript build | run | test | generate | doctor~n"
              "       escript glodin_build.escript export hex-tarball | export erlang-shipment~n"
              "       escript glodin_build.escript publish~n"
              "GLEAM, ODIN and CC select toolchain executables.~n").

fail(Message) -> throw({glodin, Message}).
str(B) when is_binary(B) -> binary_to_list(B);
str(L) when is_list(L) -> L.
env(Key, Default) -> case os:getenv(Key) of false -> Default; Value -> Value end.
root() -> filename:absname(env("GLODIN_PACKAGE_ROOT", ".")).
project_root() -> filename:absname(env("GLODIN_PROJECT_ROOT", root())).
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
    Native = filename:join([root(), "priv", "glodin", "native", Name]),
    case filelib:is_dir(Native) of true -> fail("native module already exists"); false -> ok end,
    Config = #{schema_version => 1, name => list_to_binary(Name), module => list_to_binary(App ++ "_" ++ Name ++ "_ffi"),
               gleam_module => list_to_binary(App ++ "/" ++ Name), otp_app => list_to_binary(App)},
    write(filename:join(Native, "glodin.json"), iolist_to_binary(json:encode(Config))),
    write(filename:join(Native, "lib.odin"), iolist_to_binary([
        "package ", App, "_", Name, "\n\n@(glodin_nif)\nadd :: proc(a, b: i64) -> i64 {\n\treturn a + b\n}\n"])),
    install_wrapper(),
    generate(),
    io:format("Created priv/glodin/native/~s and src/~s/~s.gleam.~n"
              "Run escript glodin_build.escript test to build native code and test.~n", [Name, App, Name]).

install_wrapper() ->
    Source = read(filename:join(toolkit(), "glodin_build.escript")),
    write(filename:join(root(), "glodin_build.escript"), Source).

modules() -> lists:sort(filelib:wildcard(filename:join([root(), "priv", "glodin", "native", "*", "glodin.json"]))).
config(Path) ->
    {ok, Bytes} = file:read_file(Path),
    Map = try json:decode(Bytes) catch error:_ -> config_error(Path, "invalid JSON") end,
    case is_map(Map) of true -> ok; false -> config_error(Path, "expected a JSON object") end,
    Allowed = [<<"schema_version">>, <<"name">>, <<"module">>, <<"gleam_module">>, <<"otp_app">>,
               <<"mode">>, <<"odin">>, <<"cc">>, <<"odin_flags">>, <<"c_flags">>, <<"collections">>,
               <<"watch">>, <<"load_data">>, <<"load_data_fun">>, <<"target">>, <<"otp_include">>,
               <<"skip_compilation">>, <<"artifact">>],
    lists:foreach(fun(Key) ->
        case lists:member(Key, Allowed) of
            true -> ok;
            false -> config_error(Path, ["unknown field ", Key])
        end
    end, maps:keys(Map)),
    case maps:get(<<"schema_version">>, Map, 1) of
        1 -> ok;
        _ -> config_error(Path, "schema_version must be 1")
    end,
    lists:foreach(fun(Key) ->
        Value = maps:get(Key, Map, undefined),
        Pattern = case Key of
            <<"gleam_module">> -> "^[a-z][a-z0-9_]*(/[a-z][a-z0-9_]*)*$";
            _ -> "^[a-z][a-z0-9_]*$"
        end,
        require_identifier(Path, Key, Value, Pattern)
    end, [<<"name">>, <<"module">>, <<"gleam_module">>, <<"otp_app">>]),
    lists:foreach(fun(Key) ->
        case maps:find(Key, Map) of
            {ok, Value} -> require_string(Path, Key, Value);
            error -> ok
        end
    end, [<<"odin">>, <<"cc">>, <<"target">>, <<"otp_include">>, <<"artifact">>]),
    lists:foreach(fun(Key) ->
        Values = maps:get(Key, Map, []),
        case is_list(Values) of true -> ok; false -> config_error(Path, [Key, " must be an array"]) end,
        lists:foreach(fun(Value) -> require_string(Path, Key, Value) end, Values)
    end, [<<"odin_flags">>, <<"c_flags">>, <<"watch">>]),
    case maps:get(<<"mode">>, Map, <<"dev">>) of
        Mode when Mode == <<"dev">>; Mode == <<"debug">>; Mode == <<"prod">>; Mode == <<"release">> -> ok;
        _ -> config_error(Path, "mode must be dev, debug, prod, or release")
    end,
    Collections = maps:get(<<"collections">>, Map, #{}),
    case is_map(Collections) of true -> ok; false -> config_error(Path, "collections must be an object") end,
    lists:foreach(fun({Key, Value}) ->
        require_identifier(Path, <<"collection name">>, Key, "^[a-z][a-z0-9_]*$"),
        case lists:member(Key, [<<"glodin">>, <<"glodin_shim">>]) of
            true -> config_error(Path, "glodin and glodin_shim collections are reserved");
            false -> ok
        end,
        require_string(Path, <<"collection path">>, Value)
    end, maps:to_list(Collections)),
    case maps:get(<<"skip_compilation">>, Map, false) of
        true -> require_string(Path, <<"artifact">>, maps:get(<<"artifact">>, Map, undefined));
        false -> ok;
        _ -> config_error(Path, "skip_compilation must be a boolean")
    end,
    case maps:is_key(<<"load_data">>, Map) andalso maps:is_key(<<"load_data_fun">>, Map) of
        true -> config_error(Path, "load_data and load_data_fun are mutually exclusive");
        false -> ok
    end,
    case maps:find(<<"load_data_fun">>, Map) of
        error -> ok;
        {ok, [M, F]} -> lists:foreach(fun(Value) ->
            require_identifier(Path, <<"load_data_fun">>, Value, "^[a-z][a-z0-9_]*$")
        end, [M, F]);
        _ -> config_error(Path, "load_data_fun must contain module and function identifiers")
    end,
    case str(maps:get(<<"name">>, Map)) == filename:basename(filename:dirname(Path)) of
        true -> ok;
        false -> fail("native module name must match its directory")
    end,
    Map.

config_error(Path, Message) -> fail(io_lib:format("~s: ~ts", [Path, Message])).
require_string(Path, Key, Value) ->
    case is_binary(Value) andalso byte_size(Value) > 0 andalso binary:match(Value, <<0>>) == nomatch of
        true -> ok;
        false -> config_error(Path, [Key, " must be a nonempty string without NUL bytes"])
    end.
require_identifier(Path, Key, Value, Pattern) ->
    require_string(Path, Key, Value),
    case re:run(Value, Pattern, [{capture, none}]) of
        match -> ok;
        _ -> config_error(Path, ["invalid ", Key])
    end.

%% Reject every configuration and output collision before generation changes files.
module_configs() ->
    Configs = [{Path, config(Path)} || Path <- modules()],
    Outputs = lists:append([[<<"src/", (maps:get(<<"gleam_module">>, Map))/binary, ".gleam">>,
                            <<"src/", (maps:get(<<"module">>, Map))/binary, ".erl">>] || {_, Map} <- Configs]),
    case length(Outputs) == length(lists:usort(Outputs)) of
        true -> Configs;
        false -> fail("native modules have conflicting generated module names")
    end.

generator() ->
    Toolkit = toolkit(),
    Cache = filename:join(root(), ".glodin"),
    ok = filelib:ensure_dir(filename:join(Cache, "_")),
    Executable = filename:join(Cache, case os:type() of {win32,_} -> "generator.exe"; _ -> "generator" end),
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
    Configs = module_configs(),
    Gen = generator(),
    lists:foreach(fun({Path, Map}) ->
        generate_module(Gen, Path, Map),
        Template = filename:join([root(), ".glodin", filename:basename(filename:dirname(Path)), "loader.erl"]),
        write(filename:join([root(), "src", str(maps:get(<<"module">>, Map)) ++ ".erl"]), read(Template))
    end, Configs),
    cleanup_generated([Path || {Path, _} <- Configs]).
generate_module(Gen, Path, Map) ->
    Native = filename:dirname(Path),
    Args = [Native, root(), str(maps:get(<<"module">>, Map)),
            str(maps:get(<<"gleam_module">>, Map)), str(maps:get(<<"otp_app">>, Map))] ++
           case maps:get(<<"target">>,Map,undefined) of undefined -> []; Target -> ["--target=" ++ str(Target)] end ++
           [str(K) ++ "=" ++ filename:absname(str(V), root()) || {K,V} <- maps:to_list(maps:get(<<"collections">>,Map,#{}))],
    Output = run(Gen, Args, root()),
    io:put_chars(Output),
    Binding = filename:join([root(), ".glodin", filename:basename(Native), "bindings.gleam"]),
    run(gleam(), ["format", Binding], root()),
    write(filename:join([root(), "src", str(maps:get(<<"gleam_module">>, Map)) ++ ".gleam"]), read(Binding)),
    Loader = filename:join([root(), "src", str(maps:get(<<"module">>, Map)) ++ ".erl"]),
    case filelib:is_file(Loader) of
        true -> ok;
        false -> write(Loader, read(filename:join([root(), ".glodin", filename:basename(Native), "loader.erl"])))
    end.

build() ->
    Configs = module_configs(),
    Gen = case lists:any(fun({_, M}) -> not maps:get(<<"skip_compilation">>,M,false) end,Configs) of
        true -> generator();
        false -> undefined
    end,
    lists:foreach(fun({Path, Map}) ->
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
    end, Configs),
    cleanup_generated([Path || {Path, _} <- Configs]).

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
        case inside(Absolute, filename:join(root(), "src")) andalso not lists:member(P, Expected) of
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
    Extension = library_extension(Map),
    Artifact = filename:join([root(), "priv", "native", Module ++ Extension]),
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
            Mode = str(maps:get(<<"mode">>, Map, env("GLODIN_BUILD_MODE", "dev"))),
            %% Conservatively include the whole package: imported local Odin packages,
            %% headers and configuration all invalidate the native artifact.
            Sources = lists:usort(tree(filename:join([root(), "priv", "glodin", "native"])) ++ tree(filename:join(Toolkit, "odin")) ++
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
            HashedArtifact = filename:join([root(), "priv", "native", Stem ++ Extension]),
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
                    Temp = HashedArtifact ++ ".tmp" ++ Extension,
                    Optimize = case Mode of "prod" -> "-o:speed"; "release" -> "-o:speed"; _ -> "-debug" end,
                    LinkFlags = case os:type() of
                        {unix, darwin} -> ["-extra-linker-flags:-undefined dynamic_lookup"];
                        _ -> []
                    end,
                    Flags = ["build", Native, "-build-mode:shared", "-no-entry-point", Optimize,
                        "-out:" ++ Temp, "-collection:glodin=" ++ filename:join(Toolkit, "odin"),
                        "-custom-attribute:glodin_nif,glodin_name,glodin_schedule,glodin_codec,glodin_tag,glodin_gleam,glodin_resource,glodin_load,glodin_upgrade,glodin_unload",
                        "-export-dependencies:json", "-export-dependencies-file:" ++ filename:join(Cache, "dependencies.json"),
                        "-collection:glodin_shim=" ++ Cache] ++ LinkFlags ++
                        ["-collection:" ++ str(K) ++ "=" ++ filename:absname(str(V),root()) || {K,V} <- maps:to_list(maps:get(<<"collections">>,Map,#{}))] ++
                        case maps:get(<<"target">>,Map,undefined) of undefined -> []; Target -> ["-target:" ++ str(Target)] end ++
                        [str(X) || X <- maps:get(<<"odin_flags">>, Map, [])],
                    run(Odin, Flags, root()),
                    BuiltHash = ComputeHash(),
                    BuiltArtifact = filename:join([root(), "priv", "native", Module ++ "_" ++ binary_to_list(BuiltHash) ++ Extension]),
                    ok = file:rename(Temp, BuiltArtifact),
                    write(Stamp, BuiltHash),
                    BuiltHash
            end,
            finalize_loader(Cache, Module, Module ++ "_" ++ binary_to_list(FinalHash), FinalHash, Map)
    end.

library_extension(Map) ->
    case maps:get(<<"target">>, Map, undefined) of
        <<"windows_", _/binary>> -> ".dll";
        undefined -> case os:type() of {win32,_} -> ".dll"; _ -> ".so" end;
        _ -> ".so"
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
