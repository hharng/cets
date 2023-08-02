%% CETS Ack Helper Process
%%
%% Contains a list of processes, that are waiting for writes to finish.
%% Collects acks from nodes in the cluster.
%% When one of the remote nodes go down, the server stops waiting for acks from it.
-module(cets_ack).
-behaviour(gen_server).

%% API functions
-export([
    start_link/1,
    add/3,
    ack/3,
    send_remote_down/2
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-include_lib("kernel/include/logger.hrl").

-type from() :: gen_server:from().
-type state() :: #{
    from() => [pid(), ...]
}.

%% API functions

-spec start_link(cets:table_name()) -> {ok, pid()}.
start_link(Tab) ->
    Name = list_to_atom(atom_to_list(Tab) ++ "_ack"),
    gen_server:start_link({local, Name}, ?MODULE, [], []).

-spec add(pid(), from(), [pid()]) -> ok.
add(AckPid, From, Servers) ->
    AckPid ! {add, From, Servers},
    ok.

%% Called by a remote server after an operation is applied.
-spec ack(pid(), from(), pid()) -> ok.
ack(AckPid, From, RemotePid) ->
    %% nosuspend makes message sending unreliable
    erlang:send(AckPid, {ack, From, RemotePid}, [noconnect]),
    ok.

%% Calls ack(AckPid, From, RemotePid) for all locally tracked From entries
-spec send_remote_down(pid(), pid()) -> ok.
send_remote_down(AckPid, RemotePid) ->
    AckPid ! {cets_remote_down, RemotePid},
    ok.

%% gen_server callbacks

-spec init(atom()) -> {ok, state()}.
init(_) ->
    State = #{},
    {ok, State}.

-spec handle_call(term(), _From, state()) -> {reply, state()}.
handle_call(Msg, From, State) ->
    ?LOG_ERROR(#{what => unexpected_call, msg => Msg, from => From}),
    {reply, {error, unexpected_call}, State}.

handle_cast(Msg, State) ->
    ?LOG_ERROR(#{what => unexpected_cast, msg => Msg}),
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({ack, From, RemotePid}, State) ->
    {noreply, handle_updated(From, RemotePid, State)};
handle_info({add, From, Servers}, State) ->
    {noreply, maps:put(From, Servers, State)};
handle_info({cets_remote_down, RemotePid}, State) ->
    {noreply, handle_remote_down(RemotePid, State)};
handle_info(Msg, State) ->
    ?LOG_ERROR(#{what => unexpected_info, msg => Msg}),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions

-spec handle_remote_down(pid(), state()) -> state().
handle_remote_down(RemotePid, State) ->
    %% Call handle_updated for all pending operations
    F = fun(From, Servers, State2) ->
        handle_updated(From, RemotePid, Servers, State2)
    end,
    maps:fold(F, State, State).

-spec handle_updated(from(), pid(), state()) -> state().
handle_updated(From, RemotePid, State) ->
    case State of
        #{From := Servers} ->
            handle_updated(From, RemotePid, Servers, State);
        _ ->
            %% Ignore unknown From
            State
    end.

-spec handle_updated(from(), pid(), [pid(), ...], state()) -> state().
handle_updated(From, RemotePid, Servers, State) ->
    %% Removes the remote server from a waiting list
    case lists:delete(RemotePid, Servers) of
        [] ->
            %% Send reply to our client
            %% confirming that the operation has finished
            gen_server:reply(From, ok),
            maps:remove(From, State);
        Servers2 ->
            %% Set an updated waiting list
            State#{From := Servers2}
    end.
