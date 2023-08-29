%% @doc Cluster join logic.
%% Checkpoints are used for testing and do not affect the joining logic.
-module(cets_join).
-export([join/4]).
-export([join/5]).
-include_lib("kernel/include/logger.hrl").

-type lock_key() :: term().
-type join_ref() :: reference().
-type server_pid() :: cets:server_pid().

%% Critical events during the joining procedure
-type checkpoint() ::
    join_start
    | before_retry
    | before_get_pids
    | before_check_fully_connected
    | before_unpause
    | {before_send_dump, server_pid()}.

-type checkpoint_handler() :: fun((checkpoint()) -> ok).
-type join_opts() :: #{checkpoint_handler => checkpoint_handler()}.

-export_type([join_ref/0]).

-ignore_xref([join/5]).

%% Adds a node to a cluster.
%% Writes from other nodes would wait for join completion.
%% LockKey should be the same on all nodes.
-spec join(lock_key(), cets_long:log_info(), server_pid(), server_pid()) ->
    ok | {error, term()}.
join(LockKey, Info, LocalPid, RemotePid) ->
    join(LockKey, Info, LocalPid, RemotePid, #{}).

-spec join(lock_key(), cets_long:log_info(), pid(), pid(), join_opts()) -> ok | {error, term()}.
join(_LockKey, _Info, Pid, Pid, _JoinOpts) when is_pid(Pid) ->
    {error, join_with_the_same_pid};
join(LockKey, Info, LocalPid, RemotePid, JoinOpts) when is_pid(LocalPid), is_pid(RemotePid) ->
    Info2 = Info#{
        local_pid => LocalPid,
        remote_pid => RemotePid,
        remote_node => node(RemotePid)
    },
    F = fun() -> join1(LockKey, Info2, LocalPid, RemotePid, JoinOpts) end,
    try
        cets_long:run_tracked(Info2#{long_task_name => join}, F)
    catch
        error:Reason:_ ->
            {error, Reason};
        %% Exits are thrown by gen_server:call API
        exit:Reason:_ ->
            {error, Reason}
    end.

join1(LockKey, Info, LocalPid, RemotePid, JoinOpts) ->
    OtherPids = cets:other_pids(LocalPid),
    case lists:member(RemotePid, OtherPids) of
        true ->
            {error, already_joined};
        false ->
            Start = erlang:system_time(millisecond),
            join_loop(LockKey, Info, LocalPid, RemotePid, Start, JoinOpts)
    end.

join_loop(LockKey, Info, LocalPid, RemotePid, Start, JoinOpts) ->
    %% Only one join at a time:
    %% - for performance reasons, we don't want to cause too much load for active nodes
    %% - to avoid deadlocks, because joining does gen_server calls
    F = fun() ->
        Diff = erlang:system_time(millisecond) - Start,
        %% Getting the lock could take really long time in case nodes are
        %% overloaded or joining is already in progress on another node
        ?LOG_INFO(Info#{what => join_got_lock, after_time_ms => Diff}),
        %% Do joining in a separate process to reduce GC
        cets_long:run_spawn(Info, fun() -> join2(LocalPid, RemotePid, JoinOpts) end)
    end,
    LockRequest = {LockKey, self()},
    %% Just lock all nodes, no magic here :)
    Nodes = [node() | nodes()],
    Retries = 1,
    case global:trans(LockRequest, F, Nodes, Retries) of
        aborted ->
            checkpoint(before_retry, JoinOpts),
            ?LOG_ERROR(Info#{what => join_retry, reason => lock_aborted}),
            join_loop(LockKey, Info, LocalPid, RemotePid, Start, JoinOpts);
        Result ->
            Result
    end.

%% Exchanges data and a list of servers.
%% Pauses new operations during the exchange.
-spec join2(server_pid(), server_pid(), join_opts()) -> ok.
join2(LocalPid, RemotePid, JoinOpts) ->
    checkpoint(join_start, JoinOpts),
    JoinRef = make_ref(),
    %% Joining is a symmetrical operation here - both servers exchange information between each other.
    %% We still use LocalPid/RemotePid in names
    %% (they are local and remote pids as passed from the cets_join and from the cets_discovery).
    #{opts := ServerOpts} = cets:info(LocalPid),
    checkpoint(before_get_pids, JoinOpts),
    LocPids = get_pids(LocalPid),
    RemPids = get_pids(RemotePid),
    check_pids(LocPids, RemPids, JoinOpts),
    AllPids = LocPids ++ RemPids,
    Paused = [{Pid, cets:pause(Pid)} || Pid <- AllPids],
    %% Merges data from two partitions together.
    %% Each entry in the table is allowed to be updated by the node that owns
    %% the key only, so merging is easy.
    try
        cets:sync(LocalPid),
        cets:sync(RemotePid),
        {ok, LocalDump} = remote_or_local_dump(LocalPid),
        {ok, RemoteDump} = remote_or_local_dump(RemotePid),
        %% Check that still fully connected after getting the dumps
        %% and before making any changes
        check_fully_connected(LocPids),
        check_fully_connected(RemPids),
        {LocalDump2, RemoteDump2} = maybe_apply_resolver(LocalDump, RemoteDump, ServerOpts),
        RemF = fun(Pid) -> send_dump(Pid, LocPids, JoinRef, LocalDump2, JoinOpts) end,
        LocF = fun(Pid) -> send_dump(Pid, RemPids, JoinRef, RemoteDump2, JoinOpts) end,
        lists:foreach(LocF, LocPids),
        lists:foreach(RemF, RemPids),
        ok
    after
        checkpoint(before_unpause, JoinOpts),
        %% If unpause fails, there would be log messages
        lists:foreach(fun({Pid, Ref}) -> catch cets:unpause(Pid, Ref) end, Paused)
    end.

send_dump(Pid, Pids, JoinRef, Dump, JoinOpts) ->
    checkpoint({before_send_dump, Pid}, JoinOpts),
    %% Error reporting would be done by cets_long:call_tracked
    catch cets:send_dump(Pid, Pids, JoinRef, Dump).

remote_or_local_dump(Pid) when node(Pid) =:= node() ->
    {ok, Tab} = cets:table_name(Pid),
    %% Reduce copying
    {ok, cets:dump(Tab)};
remote_or_local_dump(Pid) ->
    %% We actually need to ask the remote process
    cets:remote_dump(Pid).

maybe_apply_resolver(LocalDump, RemoteDump, ServerOpts = #{handle_conflict := F}) ->
    Type = maps:get(type, ServerOpts, ordered_set),
    Pos = maps:get(keypos, ServerOpts, 1),
    apply_resolver(Type, LocalDump, RemoteDump, F, Pos);
maybe_apply_resolver(LocalDump, RemoteDump, _ServerOpts) ->
    {LocalDump, RemoteDump}.

%% Bags do not have conflicts, so do not define a resolver for them.
apply_resolver(ordered_set, LocalDump, RemoteDump, F, Pos) ->
    %% Both dumps are sorted by the key (the lowest key first)
    apply_resolver_for_sorted(LocalDump, RemoteDump, F, Pos, [], []).

apply_resolver_for_sorted([X | LocalDump], [X | RemoteDump], F, Pos, LocalAcc, RemoteAcc) ->
    %% Presents in both dumps, skip it at all (we don't need to insert it, it is already inserted)
    apply_resolver_for_sorted(LocalDump, RemoteDump, F, Pos, LocalAcc, RemoteAcc);
apply_resolver_for_sorted(
    [L | LocalDump] = LocalDumpFull,
    [R | RemoteDump] = RemoteDumpFull,
    F,
    Pos,
    LocalAcc,
    RemoteAcc
) ->
    LKey = element(Pos, L),
    RKey = element(Pos, R),
    if
        LKey =:= RKey ->
            New = F(L, R),
            apply_resolver_for_sorted(LocalDump, RemoteDump, F, Pos, [New | LocalAcc], [
                New | RemoteAcc
            ]);
        LKey < RKey ->
            %% Record exists only in the local dump
            apply_resolver_for_sorted(LocalDump, RemoteDumpFull, F, Pos, [L | LocalAcc], RemoteAcc);
        true ->
            %% Record exists only in the remote dump
            apply_resolver_for_sorted(LocalDumpFull, RemoteDump, F, Pos, LocalAcc, [R | RemoteAcc])
    end;
apply_resolver_for_sorted(LocalDump, RemoteDump, _F, _Pos, LocalAcc, RemoteAcc) ->
    {lists:reverse(LocalAcc, LocalDump), lists:reverse(RemoteAcc, RemoteDump)}.

get_pids(Pid) ->
    [Pid | cets:other_pids(Pid)].

check_pids(LocPids, RemPids, JoinOpts) ->
    check_do_not_overlap(LocPids, RemPids),
    checkpoint(before_check_fully_connected, JoinOpts),
    check_fully_connected(LocPids),
    check_fully_connected(RemPids).

-spec check_do_not_overlap([server_pid()], [server_pid()]) -> ok.
check_do_not_overlap(LocPids, RemPids) ->
    LocSet = ordsets:from_list(LocPids),
    RemSet = ordsets:from_list(RemPids),
    case ordsets:intersection(LocSet, RemSet) of
        [] ->
            ok;
        Overlap ->
            ?LOG_ERROR(#{
                what => check_do_not_overlap_failed,
                local_servers => LocSet,
                remote_servers => RemSet,
                overlapped_servers => Overlap
            }),
            error(check_do_not_overlap_failed)
    end.

%% Checks that other_pids lists match for all nodes
%% If they are not matching - the node removal process could be in progress
-spec check_fully_connected([server_pid()]) -> ok.
check_fully_connected(Pids) ->
    Lists = [get_pids(Pid) || Pid <- Pids],
    case are_fully_connected_lists([Pids | Lists]) of
        true ->
            check_same_join_ref(Pids);
        false ->
            ?LOG_ERROR(#{
                what => check_fully_connected_failed,
                expected_pids => Pids,
                server_lists => Lists
            }),
            error(check_fully_connected_failed)
    end.

%% Check that all elements of the list match (if sorted)
are_fully_connected_lists(Lists) ->
    length(lists:usort([lists:sort(List) || List <- Lists])) =:= 1.

%% Check if all nodes have the same join_ref
%% If not - we don't want to continue joining
check_same_join_ref(Pids) ->
    Refs = [pid_to_join_ref(Pid) || Pid <- Pids],
    case lists:usort(Refs) of
        [_] ->
            ok;
        _ ->
            ?LOG_ERROR(#{
                what => check_same_join_ref_failed,
                refs => lists:zip(Pids, Refs)
            }),
            error(check_same_join_ref_failed)
    end.

pid_to_join_ref(Pid) ->
    #{join_ref := JoinRef} = cets:info(Pid),
    JoinRef.

%% Checkpoints are used for testing
%% Checkpoints do nothing in production
-spec checkpoint(checkpoint(), join_opts()) -> ok.
checkpoint(CheckPointName, #{checkpoint_handler := F}) ->
    F(CheckPointName);
checkpoint(_CheckPointName, _Opts) ->
    ok.
