%% @doc Node discovery logic
%% Joins table together when a new node appears
-module(cets_discovery).
-behaviour(gen_server).

-export([start/1, start_link/1, add_table/2, info/1]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-ignore_xref([start/1, start_link/1, add_table/2, info/1, behaviour_info/1]).

-include_lib("kernel/include/logger.hrl").

-type backend_state() :: term().
-type get_nodes_result() :: {ok, [node()]} | {error, term()}.

-export_type([get_nodes_result/0]).

-type from() :: {pid(), reference()}.
-type state() :: #{
    results := [term()],
    nodes := [node()],
    tables := [atom()],
    backend_module := module(),
    backend_state := state(),
    get_nodes_status := not_running | running,
    should_retry_get_nodes := boolean(),
    join_status := not_running | running,
    should_retry_join := boolean(),
    timer_ref := reference() | undefined
}.

%% Backend could define its own options
-type opts() :: #{name := atom(), _ := _}.
-type start_result() :: {ok, pid()} | {error, term()}.
-type server() :: pid() | atom().

-callback init(map()) -> backend_state().
-callback get_nodes(backend_state()) -> {get_nodes_result(), backend_state()}.

-spec start(opts()) -> start_result().
start(Opts) ->
    start_common(start, Opts).

-spec start_link(opts()) -> start_result().
start_link(Opts) ->
    start_common(start_link, Opts).

start_common(F, Opts) ->
    Args =
        case Opts of
            #{name := Name} ->
                [{local, Name}, ?MODULE, Opts, []];
            _ ->
                [?MODULE, Opts, []]
        end,
    apply(gen_server, F, Args).

-spec add_table(server(), cets:table_name()) -> ok.
add_table(Server, Table) ->
    gen_server:cast(Server, {add_table, Table}).

-spec get_tables(server()) -> {ok, [cets:table_name()]}.
get_tables(Server) ->
    gen_server:call(Server, get_tables).

-spec info(server()) -> [cets:info()].
info(Server) ->
    {ok, Tables} = get_tables(Server),
    [cets:info(Tab) || Tab <- Tables].

-spec init(term()) -> {ok, state()}.
init(Opts) ->
    %% Sends nodeup / nodedown
    ok = net_kernel:monitor_nodes(true),
    Mod = maps:get(backend_module, Opts, cets_discovery_file),
    self() ! check,
    Tables = maps:get(tables, Opts, []),
    BackendState = Mod:init(Opts),
    {ok, #{
        results => [],
        nodes => [],
        tables => Tables,
        backend_module => Mod,
        backend_state => BackendState,
        get_nodes_status => not_running,
        should_retry_get_nodes => false,
        join_status => not_running,
        should_retry_join => false,
        timer_ref => undefined
    }}.

-spec handle_call(term(), from(), state()) -> {reply, term(), state()}.
handle_call(get_tables, _From, State = #{tables := Tables}) ->
    {reply, {ok, Tables}, State};
handle_call(Msg, From, State) ->
    ?LOG_ERROR(#{what => unexpected_call, msg => Msg, from => From}),
    {reply, {error, unexpected_call}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast({add_table, Table}, State = #{tables := Tables}) ->
    case lists:member(Table, Tables) of
        true ->
            {noreply, State};
        false ->
            self() ! check,
            State2 = State#{tables := [Table | Tables]},
            {noreply, State2}
    end;
handle_cast(Msg, State) ->
    ?LOG_ERROR(#{what => unexpected_cast, msg => Msg}),
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(check, State) ->
    {noreply, handle_check(State)};
handle_info({handle_check_result, Res, BackendState}, State) ->
    {noreply, handle_get_nodes_result(Res, BackendState, State)};
handle_info({nodeup, _Node}, State) ->
    {noreply, try_joining(State)};
handle_info({nodedown, _Node}, State) ->
    {noreply, State};
handle_info({joining_finished, Results}, State) ->
    {noreply, handle_joining_finished(Results, State)};
handle_info(Msg, State) ->
    ?LOG_ERROR(#{what => unexpected_info, msg => Msg}),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-spec handle_check(state()) -> state().
handle_check(State = #{tables := []}) ->
    %% No tables to track, skip
    schedule_check(State);
handle_check(State = #{get_nodes_status := running}) ->
    State#{should_retry_get_nodes := true};
handle_check(State = #{backend_module := Mod, backend_state := BackendState}) ->
    Self = self(),
    spawn_link(fun() ->
        Info = #{task => cets_discovery_get_nodes, backend_module => Mod},
        F = fun() -> Mod:get_nodes(BackendState) end,
        {Res, BackendState2} = cets_long:run_tracked(Info, F),
        Self ! {handle_check_result, Res, BackendState2}
    end),
    State#{get_nodes_status := running}.

handle_get_nodes_result(Res, BackendState, State) ->
    State2 = State#{backend_state := BackendState, get_nodes_status := not_running},
    State3 = set_nodes(Res, State2),
    schedule_check(State3).

set_nodes({error, _Reason}, State) ->
    State;
set_nodes({ok, Nodes}, State) ->
    ping_not_connected_nodes(Nodes),
    try_joining(State#{nodes := Nodes}).

%% Called when:
%% - a list of connected nodes changes (i.e. nodes() call result)
%% - a list of nodes is received from the discovery backend
try_joining(State = #{join_status := running}) ->
    State#{should_retry_join := true};
try_joining(State = #{join_status := not_running, nodes := Nodes, tables := Tables}) ->
    Self = self(),
    AvailableNodes = nodes(),
    spawn_link(fun() ->
        %% We only care about connected nodes here
        %% We do not wanna try to connect here - we do it in ping_not_connected_nodes/1
        Results = [
            do_join(Tab, Node)
         || Node <- Nodes, lists:member(Node, AvailableNodes), Tab <- Tables
        ],
        Self ! {joining_finished, Results}
    end),
    State#{join_status := running, should_retry_join := false}.

%% Called when try_joining finishes the async task
-spec handle_joining_finished(list(), state()) -> state().
handle_joining_finished(Results, State = #{should_retry_join := Retry}) ->
    report_results(Results, State),
    State2 = State#{results := Results},
    case Retry of
        true ->
            try_joining(State2);
        false ->
            State
    end.

ping_not_connected_nodes(Nodes) ->
    NotConNodes = Nodes -- [node() | nodes()],
    [spawn(fun() -> net_adm:ping(Node) end) || Node <- lists:sort(NotConNodes)],
    ok.

schedule_check(State = #{should_retry_get_nodes := true, get_nodes_status := not_running}) ->
    %% Retry without any delay
    self() ! check,
    State#{should_retry_get_nodes := false};
schedule_check(State) ->
    cancel_old_timer(State),
    TimerRef = erlang:send_after(5000, self(), check),
    State#{timer_ref := TimerRef}.

cancel_old_timer(#{timer_ref := OldRef}) when is_reference(OldRef) ->
    %% Match result to prevent from Dialyzer warning
    _ = erlang:cancel_timer(OldRef),
    flush_all_checks(),
    ok;
cancel_old_timer(_State) ->
    ok.

flush_all_checks() ->
    receive
        check -> flush_all_checks()
    after 0 -> ok
    end.

do_join(Tab, Node) ->
    LocalPid = whereis(Tab),
    %% That would trigger autoconnect for the first time
    case rpc:call(Node, erlang, whereis, [Tab]) of
        Pid when is_pid(Pid), is_pid(LocalPid) ->
            Result = cets_join:join(cets_discovery, #{table => Tab}, LocalPid, Pid),
            #{what => join_result, result => Result, node => Node, table => Tab};
        Other ->
            #{what => pid_not_found, reason => Other, node => Node, table => Tab}
    end.

report_results(Results, _State = #{results := OldResults}) ->
    Changed = Results -- OldResults,
    lists:foreach(fun report_result/1, Changed),
    ok.

report_result(Map) ->
    ?LOG_INFO(Map).
