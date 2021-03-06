-module(sgi_fcgi).

%%-behavior(gateway_behaviour).
-behaviour(gen_server).

%% API
-export([request_pid/1]).

-export([start/0, start/2, params/2, end_req/1, stop/1, init_fcgi/0, end_fcgi/0]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-define(ARBITER, sgi_arbiter).
-define(MULTIPLEXER, sgi_multiplexer).
-define(REQUEST_ID_MAX, 65535).

%% Maximum number of bytes in the content portion of a FastCGI record.
-define(FCGI_MAX_CONTENT_LEN, 65535).

-define(FCGI_LISTENSOCK_FILENO, 0).

-define(FCGI_HEADER_LEN,8).

-define(FCGI_VERSION_1, 1).

-define(FCGI_BEGIN_REQUEST, 1).
-define(FCGI_ABORT_REQUEST, 2).
-define(FCGI_END_REQUEST, 3).
-define(FCGI_PARAMS, 4).
-define(FCGI_STDIN, 5).
-define(FCGI_STDOUT, 6).
-define(FCGI_STDERR, 7).
-define(FCGI_DATA, 8).
-define(FCGI_GET_VALUES, 9).
-define(FCGI_GET_VALUES_RESULT, 10).
-define(FCGI_UNKNOWN_TYPE, 11).
-define(FCGI_MAXTYPE, ?FCGI_UNKNOWN_TYPE).

-define(FCGI_NULL_REQUEST_ID, 0).

-define(FCGI_KEEP_CONN, 1).

-define(FCGI_RESPONDER, 1).
-define(FCGI_AUTHORIZER, 2).
-define(FCGI_FILTER, 3).

-define(FCGI_REQUEST_COMPLETE, 0).
-define(FCGI_CANT_MPX_CONN, 1).
-define(FCGI_OVERLOADED, 2).
-define(FCGI_UNKNOWN_ROLE, 3).

-define(FCGI_MAX_CONNS, "FCGI_MAX_CONNS").
-define(FCGI_MAX_REQS, "FCGI_MAX_REQS").
-define(FCGI_MPXS_CONNS, "FCGI_MPXS_CONNS").

-define(FCGI_MULTIPLEXED_YES, 1).
-define(FCGI_MULTIPLEXED_NO, 0).
-define(FCGI_MULTIPLEXED_UNKNOWN, unknown).

-define(REQUESTS, sgi_fcgi_requests).
-define(REQUEST_ID, sgi_fcgi_request_id).


-record(state, {parent :: pid(),
                role = ?FCGI_RESPONDER :: integer(),
                req_id :: integer(),
                pool_pid :: pid(),
%%                multiplexed = unknown :: string() | unknown,
                buff = <<>> :: binary()}).

-record(sgi_fcgi_requests, {req_id, pid, timer}).
-record(sgi_fcgi_request_id, {req_id}).

%%%===================================================================
%%% export
%%%===================================================================

start() ->
    gen_server:start(?MODULE, [], []).
start(Role, KeepConn) ->
    {ok, Pid} = gen_server:start(?MODULE, [], []),
    case gen_server:call(Pid, {?FCGI_BEGIN_REQUEST, Role, KeepConn}, 60000) of
        ok -> {ok, Pid};
        {error, Reason} -> {error, Reason, Pid}
    end.
stop(Pid) ->
    case sgi:is_alive(Pid) of
        true -> gen_server:stop(Pid);
        _ -> ok
    end.

params(Pid, P) ->
    Pid ! {?FCGI_PARAMS, P}.
end_req(Pid) ->
    Pid ! <<>>.

init_fcgi() ->
    ets:new(?REQUESTS, [public, named_table, {keypos, #sgi_fcgi_requests.req_id}]),
    ets:new(?REQUEST_ID, [public, named_table]),
    ets:insert(?REQUEST_ID, {req_id, 0}),
    spawn(fun () -> check_multiplex(), start_multiplexer() end),
    ok.

end_fcgi() ->
    ets:delete(?REQUESTS),
    ets:delete(?REQUEST_ID),
    wf:info(?MODULE, "fcgi ended: ~n", []),
    ok.

-spec request_pid(Data :: binary()) -> pid() | undefined.
request_pid(Data) ->
    case erlang:decode_packet(fcgi, Data, []) of
        {ok, <<?FCGI_VERSION_1, _Type, ReqId:16, _>>, _Rest} ->
            [Req] = find_req(ReqId),
            Req#sgi_fcgi_requests.pid;
        {more, More} -> % undefined
            wf:error(?MODULE, "!!!!!!!!!!!!!!!!!!!!!!request_pid, exception, MORE!!!!!!!!!!!!!!!!!!!!!!!!!!!: ~p~n", [More]),
            undefined;
        {error, invalid} ->
            undefined
    end.



%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    {ok, #state{}}.

%%=============================================================
%% Send management request and getting connection data of server
%%=============================================================
handle_call(?FCGI_GET_VALUES, {_From, _Tag}, State) ->
    Params = [{<<?FCGI_MAX_CONNS>>, <<>>}, {<<?FCGI_MAX_REQS>>, <<>>}, {<<?FCGI_MPXS_CONNS>>, <<>>}],
    Data = encode(?FCGI_GET_VALUES, 0, encode_pairs(Params)),
    RetData =
    case sgi_pool:once_call(Data) of
        {ok, Return} -> Return;
        {error, Reason} ->
            wf:error(?MODULE, "Request return error: ~p~n", [Reason]),
            <<>>
    end,
    case decode(RetData) of
        {?FCGI_GET_VALUES_RESULT, Packet, _Rest} ->
            Pairs = decode_pairs(Packet),
            {reply, {ok, Pairs}, State};
        _ ->
            {reply, {ok, []}, State}
    end;

%%===================================
%% Send data
%%===================================
% Send first request
% {?FCGI_BEGIN_REQUEST, ?FCGI_RESPONDER, ?FCGI_KEEP_CONN}
handle_call({?FCGI_BEGIN_REQUEST, Role, KeepConn}, {From, _Tag}, State) ->
    case ?ARBITER:alloc() of
        {ok, PoolPid} ->
            R = req_id(),
            save_req(R),
            Data = encode(?FCGI_BEGIN_REQUEST, R, <<Role:16, KeepConn, 0:40>>),
            case is_mult() of
                ?FCGI_MULTIPLEXED_YES -> ?MULTIPLEXER ! {send, Data, PoolPid};
                _ -> PoolPid ! {send, Data, self()}
            end,
            case is_mult() of ?FCGI_MULTIPLEXED_YES -> ?ARBITER:free(PoolPid); _ -> ok end,
            State1 = State#state{parent = From, req_id = R, pool_pid = PoolPid},
            {reply, ok, State1};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, ok, State}.


handle_cast(_Request, State) ->
    {noreply, State}.


handle_info({?FCGI_PARAMS, Params}, State) ->
    P = <<(encode(?FCGI_PARAMS, State#state.req_id, encode_pairs(Params)))/binary, (encode(?FCGI_PARAMS, State#state.req_id, <<>>))/binary>>,
    case is_mult() of
        ?FCGI_MULTIPLEXED_YES -> ?MULTIPLEXER ! {send, P, State#state.pool_pid};
        _ -> State#state.pool_pid ! {send, P, self()}
    end,
    {noreply, State};
% Send body
handle_info({?FCGI_STDIN, Request}, State) ->
    case is_mult() of
        ?FCGI_MULTIPLEXED_YES -> ?MULTIPLEXER ! {send, encode(?FCGI_STDIN, State#state.req_id, Request), State#state.pool_pid};
        _ -> State#state.pool_pid ! {send, encode(?FCGI_STDIN, State#state.req_id, Request), self()}
    end,
    {noreply, State};
handle_info(<<>>, State) -> %% send empty string as end of request
    case is_mult() of
        ?FCGI_MULTIPLEXED_YES -> ?MULTIPLEXER ! {send, encode(?FCGI_STDIN, State#state.req_id, <<>>), State#state.pool_pid};
        _ -> State#state.pool_pid ! {send, encode(?FCGI_STDIN, State#state.req_id, <<>>), self()}
    end,
    {noreply, State};
handle_info(?FCGI_ABORT_REQUEST, State) ->
    case is_mult() of
        ?FCGI_MULTIPLEXED_YES -> ?MULTIPLEXER ! {send, encode(?FCGI_ABORT_REQUEST, State#state.req_id, <<>>), State#state.pool_pid};
        _ -> State#state.pool_pid ! {send, encode(?FCGI_ABORT_REQUEST, State#state.req_id, <<>>), self()}
    end,
    {noreply, State};
%% This event send a message by one request, what is much faster than separately
%% @todo Need some refactoring...!!!
handle_info({overall, From, Params, HasBody, Body}, State) ->
    R = req_id(),
    save_req(R),
    case ?ARBITER:alloc() of
        {ok, PoolPid} ->
            Data1 = <<(encode(?FCGI_BEGIN_REQUEST, R, <<1:16, 1, 0:40>>))/binary, (encode(?FCGI_PARAMS, R, encode_pairs(Params)))/ binary, (encode(?FCGI_PARAMS, R, <<>>))/binary>>,
            case HasBody of
                true ->
                    case is_mult() of
                        ?FCGI_MULTIPLEXED_YES -> ?MULTIPLEXER ! {send, <<Data1/binary, (encode(?FCGI_STDIN, R, Body))/binary, (encode(?FCGI_STDIN, R, <<>>))/binary>>, PoolPid};
                        _ -> PoolPid ! {send, <<Data1/binary, (encode(?FCGI_STDIN, R, Body))/binary, (encode(?FCGI_STDIN, R, <<>>))/binary>>, self()}
                    end;
                _ ->
                    case is_mult() of
                        ?FCGI_MULTIPLEXED_YES -> ?MULTIPLEXER ! {send, <<Data1/binary, (encode(?FCGI_STDIN, R, <<>>))/binary>>, PoolPid};
                        _ -> PoolPid ! {send, <<Data1/binary, (encode(?FCGI_STDIN, R, <<>>))/binary>>, self()}
                    end
            end,
            {noreply, State#state{parent = From, req_id = R, pool_pid = PoolPid}};
        {error, _Reason} ->
            {noreply, State}
    end;


%%===================================
%% Receive data
%%===================================

handle_info({socket_return, Data}, State) ->
    State1 = send_back(Data, State),
    {noreply, State1};
handle_info({socket_error, Data}, State) ->
    State#state.parent ! {sgi_fcgi_return_error, Data},
    {noreply, State};


%%===================================
%% Other methods
%%===================================

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    case State#state.req_id of
        undefined -> ok;
        Id -> del_req(Id)
    end,
    case is_mult() of ?FCGI_MULTIPLEXED_YES -> ok; _ -> case State#state.pool_pid of undefined -> ok; Pid -> ?ARBITER:free(Pid) end end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

check_multiplex() ->
    case is_mult() of
        ?FCGI_MULTIPLEXED_UNKNOWN ->
            {ok, Pid} = ?SERVER:start(),
            {ok, Ret} = gen_server:call(Pid, ?FCGI_GET_VALUES),
            ?SERVER:stop(Pid),
            MPXS1 = case lists:keyfind(wf:to_binary(?FCGI_MPXS_CONNS), 1, Ret) of
                {_, <<"0">>} -> ?FCGI_MULTIPLEXED_NO;
                {_, <<"1">>} -> ?FCGI_MULTIPLEXED_YES;
                _ -> ?FCGI_MULTIPLEXED_NO
            end,
            application:set_env(sgi, multiplexed, MPXS1);
        _ -> ok
    end.

start_multiplexer() -> % we don't need multiplexer if we don't use multiplex connection
    case is_mult() of
        V when V == ?FCGI_MULTIPLEXED_YES ->
            {ok, _} = sgi_sup:start_child(?MULTIPLEXER, {?MODULE, request_pid}), ok;
        _ ->
            ok
    end.

req_id() ->
    ets:update_counter(?REQUEST_ID, req_id, {2, 1, ?REQUEST_ID_MAX, 1}).
save_req(ReqId) ->
    ets:insert_new(?REQUESTS, #sgi_fcgi_requests{req_id = ReqId, pid = self()}).
find_req(ReqId) ->
    ets:lookup(?REQUESTS, ReqId).
del_req(ReqId) ->
    ets:delete(?REQUESTS, ReqId).

encode(Type, ReqId, Content = <<>>) ->
    encode_add_header(Type, ReqId, Content);
encode(Type, ReqId, Content) ->
    encode(Type, ReqId, iolist_to_binary(Content), []).
encode(_, _, <<>>, Bin) ->
    iolist_to_binary(lists:reverse(Bin));
encode(Type, ReqId, <<Content:(?FCGI_MAX_CONTENT_LEN - 8)/binary, Rest/binary>>, Bin) ->
    encode(Type, ReqId, Rest, [encode_add_header(Type, ReqId, Content) | Bin]);
encode(Type, ReqId, Content, Bin) ->
    encode(Type, ReqId, <<>>, [encode_add_header(Type, ReqId, Content) | Bin]).
encode_add_header(Type, ReqId, Content) ->
    <<?FCGI_VERSION_1, Type, ReqId:16, (iolist_size(Content)):16, 0, 0, Content/binary>>.

-spec encode_pairs(list()) -> list().
encode_pairs(P) ->
    encode_pairs(P, []).
encode_pairs([H|T], Res) ->
    encode_pairs(T, [encode_pair(H)|Res]);
encode_pairs([], Res) ->
    lists:reverse(Res).
encode_pair({N, V}) ->
    NL = encode_pair_len(N),
    VL = encode_pair_len(V),
    <<NL/binary, VL/binary, N/binary, V/binary>>.
encode_pair_len(D) ->
    case iolist_size(D) of
        L when L < 128 -> <<0:1, L:7>>;
        L1 -> <<1:1, L1:31>>
    end.

send_back(<<>>, State) ->
    State;
send_back(Data, State = #state{buff = B}) ->
    Data1 = <<B/binary, Data/binary>>,
    case decode(Data1) of
        {?FCGI_STDERR, E, Rest} ->
%%            wf:info(?MODULE, "socket_return, FCGI_STDERR: ~p~n", [E]),
            State#state.parent ! {sgi_fcgi_return, <<>>, stream_body(E)},
            send_back(Rest, State#state{buff = <<>>});
        {?FCGI_STDOUT, Packet, Rest} ->
            State#state.parent ! {sgi_fcgi_return, Packet, <<>>},
            send_back(Rest, State#state{buff = <<>>});
        {?FCGI_DATA, Packet, Rest} ->
            State#state.parent ! {sgi_fcgi_return, Packet, <<>>},
            send_back(Rest, State#state{buff = <<>>});
        {?FCGI_END_REQUEST, <<_AppStatus:32, _ProtocolStatus, _Reserved:24>>, Rest} ->
%%            wf:info(?MODULE, "socket_return, FCGI_END_REQUEST, AppStatus:~p~n, ProtocolStatus:~p~n", [AppStatus, ProtocolStatus]),
            State#state.parent ! sgi_fcgi_return_end,
            del_req(State#state.req_id),
            send_back(Rest, State#state{buff = <<>>, req_id = 0});
        more ->
            State#state{buff = Data1};
        <<>> ->
            State
    end.

decode(<<>>) ->
    <<>>;
decode(Data) ->
    case erlang:decode_packet(fcgi, Data, []) of
        {ok, <<?FCGI_VERSION_1, Type, _ReqId:16, PacketLength:16, _PaddingLength, _Reserved, Packet:PacketLength/binary>>, Rest} ->
            {Type, Packet, Rest};
        {more, undefined} ->
            more;
        {more, _More} ->
            more;
        {error, invalid} ->
            <<>>
    end.

decode_pairs(B) -> decode_pairs(B, []).
decode_pairs(<<>>, Pairs) -> lists:reverse(Pairs);
decode_pairs(<<0:1, NL:7,  0:1, VL:7,  B/binary>>, Pairs) -> decode_pairs(NL, VL, B, Pairs);
decode_pairs(<<1:1, NL:31, 0:1, VL:7,  B/binary>>, Pairs) -> decode_pairs(NL, VL, B, Pairs);
decode_pairs(<<0:1, NL:7,  1:1, VL:31, B/binary>>, Pairs) -> decode_pairs(NL, VL, B, Pairs);
decode_pairs(<<1:1, NL:31, 1:1, VL:31, B/binary>>, Pairs) -> decode_pairs(NL, VL, B, Pairs).
decode_pairs(NL, VL, B, Pairs) ->
    <<N:NL/binary, V:VL/binary, T/binary>> = B,
    decode_pairs(T, [{N, V} | Pairs]).

stream_body(<<>>) ->
    eof;
stream_body(Bin) ->
    Bin.

is_mult() ->
    wf:config(sgi, multiplexed, ?FCGI_MULTIPLEXED_UNKNOWN).