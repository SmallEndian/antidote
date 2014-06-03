%% @doc The coordinator for stat write opeartions.  This example will
%% show how to properly replicate your data in Riak Core by making use
%% of the _preflist_.
-module(floppy_rep_fsm).
-behavior(gen_fsm).
-include("floppy.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([start_link/5]).

%% Callbacks
-export([init/1, code_change/4, handle_event/3, handle_info/3,
         handle_sync_event/4, terminate/3]).

%% States
-export([prepare/2, execute/2, waitAppend/2, waitRead/2, repairRest/2 ]).

-record(state, {
                from :: pid(),
                op :: atom(),
                key,
                param = undefined :: term() | undefined,
		readresult,
                preflist :: riak_core_apl:preflist(),
		num_to_ack = 0 :: non_neg_integer(),
		opid,
		nodeOps}).

%%%===================================================================
%%% API
%%%===================================================================

%start_link(Key, Op) ->
%    start_link(Key, Op).

start_link(From, Op,  Key, Param, OpId) ->
    gen_fsm:start_link(?MODULE, [From, Op, Key, Param, OpId], []).


%%%===================================================================
%%% States
%%%===================================================================

%% @doc Initialize the state data.
init([From, Op,  Key, Param, OpId]) ->
    SD = #state{from=From,
                op=Op,
                key=Key,
                param=Param,
		opid= OpId,
		readresult=[],
		nodeOps =[]},
    {ok, prepare, SD, 0}.

%% @doc Prepare the write by calculating the _preference list_.
prepare(timeout, SD0=#state{key=Key}) ->
    DocIdx = riak_core_util:chash_key({?BUCKET,
                                       term_to_binary(Key)}),
    Preflist = riak_core_apl:get_primary_apl(DocIdx, ?N, logging),
    NewPref = [Node|| {Node,_} <- Preflist ],
    SD = SD0#state{preflist=NewPref},
    {next_state, execute, SD, 0}.

%% @doc Execute the write request and then go into waiting state to
%% verify it has meets consistency requirements.
execute(timeout, SD0=#state{op=Op,
                            key=Key,
                            param=Param,
                            preflist=Preflist,
			    opid=OpId}) ->
    case Op of 
	append ->
	    lager:info("FSM: Replicate append ~n"),
	    logging_vnode:dappend(Preflist, Key, Param, OpId),
	    SD1 = SD0#state{num_to_ack=?NUM_W},
	    {next_state, waitAppend, SD1};
%	create ->
%	    lager:info("replication propagating create!~w~n",[Preflist]),
%	    logging_vnode:dcreate(Preflist, Key, Param, OpClock),
%	    Num_w = SD0#state.num_w,
%	    SD1 = SD0#state{num_to_ack=Num_w},
%	    {next_state, waiting, SD1};
	read ->
	    lager:info("FSM: Replication read ~n"),
	    logging_vnode:dread(Preflist, Key),
	    SD1 = SD0#state{num_to_ack=?NUM_R},
	    {next_state, waitRead, SD1};
	_ ->
	    lager:info("FSM: Wrong command ~n"),
	   %%reply message to user
	    {stop, normal, SD0}
    end.


%% @doc Waits for W write reqs to respond.
waitAppend({_Node, Result}, SD=#state{op=Op, from= From, key=Key, num_to_ack= NumToAck}) ->
    if NumToAck == 1 -> 
    	lager:info("FSM: Finish collecting replies for ~w ~n", [Op]),
	floppy_coord_fsm:finishOp(From,  Key, Result),	
	{stop, normal, SD};
	true ->
         lager:info("FSM: Keep collecting replies~n"),
	{next_state, waitAppend, SD#state{num_to_ack= NumToAck-1 }}
    end.

%% @doc Waits for R read reqs to respond and union returned operations.
%% Then send vnodes operations if they haven't seen some.
%% Finally reply the unioned operation list to the coord fsm.
waitRead({Node, Result}, SD=#state{op=Op, from= From, nodeOps = NodeOps, key=Key, readresult= ReadResult , num_to_ack= NumToAck}) ->
    NodeOps1 = lists:append([{Node, Result}], NodeOps),
    Result1 = union_ops(ReadResult, [], Result),
    %lager:info("FSM: Get reply ~w ~n, unioned reply ~w ~n",[Result,Result1]),
    if NumToAck == 1 -> 
    	lager:info("FSM: Finish reading for ~w ~w ~n", [Op, Key]),
	repair(NodeOps1, Result1),
	floppy_coord_fsm:finishOp(From,  Key, Result1),	
	{next_state, repairRest, SD#state{num_to_ack = ?N-?NUM_R, nodeOps=NodeOps1, readresult = Result1}, ?INDC_TIMEOUT};
	true ->
         lager:info("FSM: Keep collecting replies~n"),
	{next_state, waitRead, SD#state{num_to_ack= NumToAck-1, nodeOps= NodeOps1, readresult = Result1}}
    end;

waitRead({error, no_key}, SD) ->
    lager:info("FSM: No key!~n"),
    {stop, normal, SD}.

%% @doc Keeps waiting for read replies from vnodes after replying to coord fsm.
%% Do read repair if any of them haven't seen some ops.
repairRest(timeout, SD= #state{nodeOps=NodeOps, readresult = ReadResult}) ->
    lager:info("FSM: read repair timeout! Start repair anyway~n"),
    repair(NodeOps, ReadResult),
    {stop, normal, SD};

repairRest({Node, Result}, SD=#state{num_to_ack = NumToAck, nodeOps = NodeOps, readresult = ReadResult}) ->
    NodeOps1 = lists:append([{Node, Result}], NodeOps),
    Result1 = union_ops(ReadResult, [], Result),
    %lager:info("FSM: Get reply ~w ~n, unioned reply ~w ~n",[Result,Result1]),
    if NumToAck == 1 -> 
    	lager:info("FSM: Finish collecting replies, start read repair ~n"),
	repair(NodeOps, ReadResult),
	{stop, normal, SD};
    	true ->
         lager:info("FSM: Keep collecting replies~n"),
	{next_state, repairRest, SD#state{num_to_ack= NumToAck-1, nodeOps= NodeOps1, readresult = Result1}, ?INDC_TIMEOUT}
    end.

handle_info(_Info, _StateName, StateData) ->
    {stop,badmsg,StateData}.

handle_event(_Event, _StateName, StateData) ->
    {stop,badmsg,StateData}.

handle_sync_event(_Event, _From, _StateName, StateData) ->
    {stop,badmsg,StateData}.

code_change(_OldVsn, StateName, State, _Extra) -> {ok, StateName, State}.

terminate(_Reason, _SN, _SD) ->
    ok.

%%%===================================================================
%%% Internal Functions
%%%===================================================================

%% @doc Find operations that are in List2 but not in List1
find_diff_ops(List1, List2) ->
    lists:filter(fun(X)-> lists:member(X, List1) == false end , List2).

%% @doc Make a union of operations in L1 and L2
%% TODO: Possible to simplify?
union_ops(L1, L2, []) ->
    lists:append(L1, L2);
union_ops(L1, L2, [Op|T]) ->
    {_, #operation{op_number= OpId}} = Op,
    L3 = remove_dup(L1, OpId,[]),
    L4 = lists:append(L2, [Op]),
    union_ops(L3, L4, T).

%% @doc Send logging vnodes with operations that they havn't seen
repair([], _) ->
    ok;
repair([H|T], FullOps) ->
    {Node, Ops} = H,
    DiffOps = find_diff_ops(Ops, FullOps),
    if DiffOps /= [] ->
    	logging_vnode:append_list(Node, DiffOps),
    	repair(T, FullOps);
	true ->
    	repair(T, FullOps)
    end.

%% @doc Remove duplicate ops with OpId from a list (the first param)
%% and return a list with only one operation with OpId
remove_dup([], _OpId, Set2) ->
    Set2;
remove_dup([H|T], OpId, Set2) ->
    {_, #operation{op_number= OpNum}} = H,
    if OpNum /= OpId ->
	Set3 = lists:append(Set2, [H]);
       true ->
	Set3 = Set2
    end,
    remove_dup(T, OpId, Set3).


-ifdef(TEST).
   union_test()-> 
	Result = union_ops([{nothing, {operation,1,dwaf}}, {nothing, {operation,2,fasd}}],[],[{nothing, {operation,1, dwaf}}, {nothing, {operation,3, dafds}}]),
	?assertEqual(Result, [{nothing, {operation, 2, fasd}}, {nothing, {operation,1, dwaf}}, {nothing, {operation, 3, dafds}}]),
	Result1 = union_ops([{nothing, {operation,2,fasd}}], [], [{nothing, {operation,1, dwaf}}, {nothing, {operation,3, dafds}}]),
	?assertEqual(Result1, [{nothing, {operation, 2, fasd}}, {nothing, {operation,1, dwaf}}, {nothing, {operation, 3, dafds}}]),
	Result2 = union_ops([{nothing, {operation,2,fasd}}], [], [{nothing, {operation,2, fasd}}]),
	?assertEqual(Result2, [{nothing, {operation, 2, fasd}}]).
-endif.    