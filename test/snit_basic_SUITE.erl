-module(snit_basic_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").

groups() ->
    [].

all() ->
    [connect, connect_sni, proxy, in_mem_connect].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(snit),
    lager_common_test_backend:bounce(info),
    Config.

end_per_suite(_Config) ->
    application:stop(snit),
    ok.

init_per_group(_GroupName, Config) ->
    Config.

end_per_group(_GroupName, _Config) ->
    ok.

init_per_testcase(connect, Config) ->
    snit:start(connect, 2, 8001, fun test_sni_fun/1, snit_echo, []),
    ets:new(test_tab, [public, named_table]),
    ets:insert(test_tab, {"localhost", {?config(data_dir, Config) ++ "cacerts.pem",
                                        ?config(data_dir, Config) ++ "cert.pem",
                                        ?config(data_dir, Config) ++ "key.pem"}}
              ),
    Config;
init_per_testcase(connect_sni, Config) ->
    snit:start(connect_sni, 2, 8001, fun test_sni_fun/1, snit_echo, []),
    ets:new(test_tab, [public, named_table]),
    ets:insert(test_tab, {"snihost", {?config(data_dir, Config) ++ "cacerts.pem",
                                      ?config(data_dir, Config) ++ "cert.pem",
                                      ?config(data_dir, Config) ++ "key.pem"}}
              ),
    Config;
init_per_testcase(in_mem_connect, Config) ->
    snit:start(connect_sni, 2, 8001, fun test_sni_fun_mem/1, snit_echo, []),
    ets:new(test_tab, [public, named_table]),
    {ok, CaCert0} = file:read_file(?config(data_dir, Config) ++ "cacerts.pem"),
    [{_, CaCert}] = public_key:pem_decode(CaCert0),
    {ok, Cert0} = file:read_file(?config(data_dir, Config) ++ "cert.pem"),
    Cert = public_key:pem_decode(Cert0),
    {ok, Key0} = file:read_file(?config(data_dir, Config) ++ "key.pem"),
    Key = public_key:pem_decode(Key0),
    ets:insert(test_tab, {"memhost", {CaCert, Cert, Key}}),
    Config;
init_per_testcase(proxy, Config) ->
    {ok, Listen} = gen_tcp:listen(0, [{active, false}]),
    {ok, {{0,0,0,0}, Port}} = inet:sockname(Listen),
    IP = {127,0,0,1},
    Backend = spawn_link(fun() -> listen(Listen) end),
    snit:start(proxy, 2, 8001, fun test_sni_fun/1, snit_tcp_proxy, [{dest, {IP,Port}}]),
    ets:new(test_tab, [public, named_table]),
    ets:insert(test_tab, {"snihost", {?config(data_dir, Config) ++ "cacerts.pem",
                                      ?config(data_dir, Config) ++ "cert.pem",
                                      ?config(data_dir, Config) ++ "key.pem"}}
              ),
    [{backend, Backend} | Config];
init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(connect, _Config) ->
    snit:stop(connect),
    ets:delete(test_tab),
    ok;
end_per_testcase(connect_sni, _Config) ->
    snit:stop(connect_sni),
    ets:delete(test_tab),
    ok;
end_per_testcase(in_mem_connect, _Config) ->
    snit:stop(connect_sni),
    ets:delete(test_tab),
    ok;
end_per_testcase(proxy, Config) ->
    snit:stop(proxy),
    ets:delete(test_tab),
    Backend = ?config(backend, Config),
    unlink(Backend),
    exit(Backend, kill),
    ok.

connect(Config) ->
    {ok, S} = ssl:connect("localhost", 8001, [{active, true},binary]),
    ssl:send(S, <<"first">>),
    receive
        {ssl, S, <<"first">>} ->
            ok;
        Else ->
            lager:info("else ~p", [Else]),
            error(unexpected_message)
    after 500 ->
            error(timeout)
    end,
    Config.

connect_sni(Config) ->
    {ok, S} = ssl:connect("localhost", 8001,
                          [{active, true},binary,
                           {server_name_indication, "snihost"}]),
    ssl:send(S, <<"first">>),
    receive
        {ssl, S, <<"first">>} ->
            ok;
        Else ->
            lager:info("else ~p", [Else]),
            error(unexpected_message)
    after 500 ->
            error(timeout)
    end,
    Config.

in_mem_connect(Config) ->
    {ok, S} = ssl:connect("localhost", 8001,
                          [{active, true},binary,
                           {server_name_indication, "memhost"}]),
    ssl:send(S, <<"first">>),
    receive
        {ssl, S, <<"first">>} ->
            ok;
        Else ->
            lager:info("else ~p", [Else]),
            error(unexpected_message)
    after 500 ->
            error(timeout)
    end,
    Config.

proxy(Config) ->
    {ok, S} = ssl:connect("localhost", 8001,
                          [{active, true},binary,
                           {server_name_indication, "snihost"}]),
    ssl:send(S, <<"first">>),
    receive
        {ssl, S, <<"returned: first">>} ->
            ok;
        Else ->
            lager:info("else ~p", [Else]),
            error({unexpected_message, Else})
    after 500 ->
            error(timeout)
    end,
    Config.

test_sni_fun(SNIHostname) ->
    lager:debug("sni hostname: ~p", [SNIHostname]),
    [{_, {CaCertFile, CertFile, KeyFile}}] = ets:lookup(test_tab, SNIHostname),
    [{cacertfile, CaCertFile}, {certfile, CertFile}, {keyfile, KeyFile}].

test_sni_fun_mem(SNIHostname) ->
    lager:debug("sni hostname: ~p", [SNIHostname]),
    [{_, {CaCert, Cert, Key}}] = ets:lookup(test_tab, SNIHostname),
    [{cacert, CaCert}, {cert, Cert}, {key, Key}].

listen(Listen) ->
    {ok, Sock} = gen_tcp:accept(Listen),
    loop(Sock).

loop(Sock) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} ->
            lager:info("tcp test loop: ~p", [Data]),
            ok = gen_tcp:send(Sock, ["returned: ", Data]),
            loop(Sock);
        {error, closed} ->
            exit(normal)
    end.

