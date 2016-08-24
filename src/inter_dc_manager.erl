%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 SyncFree Consortium.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(inter_dc_manager).
-include("antidote.hrl").
-include("inter_dc_repl.hrl").

%% ===================================================================
%% Public API
%% ===================================================================

-export([
  get_descriptor/0,
  start_bg_processes/1,
  observe_dc/1,
  observe_dc_sync/1,
  observe/1,
  observe_dcs/1,
  observe_dcs_sync/1,
  dc_successfully_started/0,
  check_node_restart/0,
  forget_dc/1,
  forget_dcs/1,
  drop_ping/1]).

-spec get_descriptor() -> {ok, #descriptor{}}.
get_descriptor() ->
  %% Wait until all needed vnodes are spawned, so that the heartbeats are already being sent
  ok = dc_utilities:ensure_all_vnodes_running_master(inter_dc_log_sender_vnode_master),
  Nodes = dc_utilities:get_my_dc_nodes(),
  Publishers = lists:map(fun(Node) -> rpc:call(Node, inter_dc_pub, get_address_list, []) end, Nodes),
  LogReaders = lists:map(fun(Node) -> rpc:call(Node, inter_dc_query_receive_socket, get_address_list, []) end, Nodes),
  {ok, #descriptor{
    dcid = dc_meta_data_utilities:get_my_dc_id(),
    partition_list = dc_meta_data_utilities:get_my_partitions_list(),
    partition_num = dc_utilities:get_partitions_num(),
    publishers = Publishers,
    logreaders = LogReaders
  }}.

-spec observe_dc(#descriptor{}) -> ok | inter_dc_conn_err().
observe_dc(Desc = #descriptor{dcid = DCID, partition_num = PartitionsNumRemote, publishers = Publishers, logreaders = LogReaders,
			     partition_list = ExternalPartitions}) ->
    PartitionsNumLocal = dc_utilities:get_partitions_num(),
    case (PartitionsNumRemote == PartitionsNumLocal) or ?IS_PARTIAL() of
	false ->
	    lager:error("Cannot observe remote DC: partition number mismatch"),
	    {error, {partition_num_mismatch, PartitionsNumRemote, PartitionsNumLocal}};
	true ->
	    case DCID == dc_utilities:get_my_dc_id() of
		true -> ok;
		false ->
		    lager:info("Observing DC ~p", [DCID]),
		    dc_utilities:ensure_all_vnodes_running_master(inter_dc_log_sender_vnode_master),
		    %% Announce the new publisher addresses to all subscribers in this DC.
		    %% Equivalently, we could just pick one node in the DC and delegate all the subscription work to it.
		    %% But we want to balance the work, so all nodes take part in subscribing.
		    Nodes = lists:sort(dc_utilities:get_my_dc_nodes()),
		    %% Get the partitions that are different from this DC to the other DC
		    %% and assign them in a deterministic way to nodes here
		    MyPartitions = dc_meta_data_utilities:get_my_partitions_list(),
		    DifferentPartitions = lists:subtract(ExternalPartitions,MyPartitions),
		    NodePartitionDict = 
			lists:foldl(fun(Partition,{[FirstNode|RestNode],AccDict}) ->
					    {RestNode ++ [FirstNode], dict:append(FirstNode,Partition,AccDict)}
				    end, dict:new(), DifferentPartitions),
		    connect_nodes(Nodes, NodePartitionDict, DCID, LogReaders, Publishers, Desc)
	    end
    end.

-spec connect_nodes([node()], dict(), dcid(), [socket_address()], [socket_address()], #descriptor{}) -> ok | {error, connection_error}.
connect_nodes([], _MyNodes, _DCID, _LogReaders, _Publishers, _Desc) ->
    ok;
connect_nodes([Node|Rest], NodePartitionDict, DCID, LogReaders, Publishers, Desc) ->
    case rpc:call(Node, inter_dc_query, add_dc, [DCID, LogReaders], ?COMM_TIMEOUT) of
	ok ->
	    OtherPart = case dict:find(Node,NodePartitionDict) of
			    {ok,Value} -> Value;
			    error -> [] end,
	    case rpc:call(Node, inter_dc_sub, add_dc, [DCID, Publishers, OtherPart], ?COMM_TIMEOUT) of
		ok ->
		    connect_nodes(Rest, NodePartitionDict, DCID, LogReaders, Publishers, Desc);
		_ ->
		    lager:error("Unable to connect to publisher ~p", [DCID]),
		    ok = forget_dc(Desc),
		    {error, connection_error}
	    end;
	_ ->
	    lager:error("Unable to connect to log reader ~p", [DCID]),
	    ok = forget_dc(Desc),
	    {error, connection_error}
    end.

%% This should not be called untilt the local dc's ring is merged
-spec start_bg_processes(atom()) -> ok.
start_bg_processes(MetaDataName) ->
    %% Start the meta-data senders
    Nodes = dc_utilities:get_my_dc_nodes(),
    %% Ensure vnodes are running and meta_data
    ok = dc_utilities:ensure_all_vnodes_running_master(inter_dc_log_sender_vnode_master),
    ok = dc_utilities:ensure_all_vnodes_running_master(clocksi_vnode_master),
    ok = dc_utilities:ensure_all_vnodes_running_master(logging_vnode_master),
    ok = dc_utilities:ensure_all_vnodes_running_master(materializer_vnode_master),
    lists:foreach(fun(Node) -> 
			  true = wait_init:wait_ready(Node),
			  ok = rpc:call(Node, dc_utilities, check_registered, [meta_data_sender_sup]),
			  ok = rpc:call(Node, dc_utilities, check_registered, [meta_data_manager_sup]),
			  ok = rpc:call(Node, dc_utilities, check_registered_global, [stable_meta_data_server:generate_server_name(Node)]),
			  ok = rpc:call(Node, meta_data_sender, start, [MetaDataName]) end, Nodes),
    %% Load the internal meta-data
    _MyDCId = dc_meta_data_utilities:reset_my_dc_id(),
    _MyDesc = dc_meta_data_utilities:get_my_dc_descriptor(),
    ok = dc_meta_data_utilities:load_partition_meta_data(),
    ok = dc_meta_data_utilities:store_meta_data_name(MetaDataName),
    %% Start the timers sending the heartbeats
    lager:info("Starting heartbeat sender timers"),
    Responses = dc_utilities:bcast_vnode_sync(logging_vnode_master, {start_timer,undefined}),
    %% Be sure they all started ok, crash otherwise
    ok = lists:foreach(fun({_, ok}) ->
			       ok
		       end, Responses),
    lager:info("Starting read servers"),
    Responses2 = dc_utilities:bcast_vnode_sync(clocksi_vnode_master, {check_servers_ready}),
    %% Be sure they all started ok, crash otherwise
    ok = lists:foreach(fun({_, true}) ->
			       ok
		       end, Responses2),
    ok.

%% This should be called once the DC is up and running successfully
%% It sets a flag on disk to true.  When this is true on fail and
%% restart the DC will load its state from disk
-spec dc_successfully_started() -> ok.
dc_successfully_started() ->
    dc_meta_data_utilities:dc_start_success().

%% Checks is the node is restarting when it had already been running
%% If it is then all the background processes and connections are restarted
-spec check_node_restart() -> boolean().
check_node_restart() ->
    case dc_meta_data_utilities:is_restart() of
	true ->
	    lager:info("This node was previously configured, will restart from previous config"),
	    MyNode = node(),
	    %% Ensure vnodes are running and meta_data
	    ok = dc_utilities:ensure_local_vnodes_running_master(inter_dc_log_sender_vnode_master),
	    ok = dc_utilities:ensure_local_vnodes_running_master(clocksi_vnode_master),
	    ok = dc_utilities:ensure_local_vnodes_running_master(logging_vnode_master),
	    ok = dc_utilities:ensure_local_vnodes_running_master(materializer_vnode_master),
	    wait_init:wait_ready(MyNode),
	    ok = dc_utilities:check_registered(meta_data_sender_sup),
	    ok = dc_utilities:check_registered(meta_data_manager_sup),
	    ok = dc_utilities:check_registered_global(stable_meta_data_server:generate_server_name(MyNode)),
	    {ok, MetaDataName} = dc_meta_data_utilities:get_meta_data_name(),
	    ok = meta_data_sender:start(MetaDataName),
	    %% Start the timers sending the heartbeats
	    lager:info("Starting heartbeat sender timers"),
	    Responses = dc_utilities:bcast_my_vnode_sync(logging_vnode_master, {start_timer,undefined}),
	    %% Be sure they all started ok, crash otherwise
	    ok = lists:foreach(fun({_, ok}) ->
				       ok
			       end, Responses),
	    lager:info("Starting read servers"),
	    Responses2 = dc_utilities:bcast_my_vnode_sync(clocksi_vnode_master, {check_servers_ready}),
	    %% Be sure they all started ok, crash otherwise
	    ok = lists:foreach(fun({_, true}) ->
				       ok
			       end, Responses2),
	    %% Reconnect this node to other DCs
	    OtherDCs = dc_meta_data_utilities:get_dc_descriptors(),
	    Responses3 = reconnect_dcs_after_restart(OtherDCs),
	    %% Ensure all connections were successful, crash otherwise
	    Responses3 = [X = ok || X <- Responses3],
	    true;
	false ->
	    false
    end.

-spec reconnect_dcs_after_restart([#descriptor{}]) -> [ok | inter_dc_conn_err()].
reconnect_dcs_after_restart(Descriptors) ->
    ok = forget_dcs(Descriptors),
    observe_dcs_sync(Descriptors).

-spec observe_dcs([#descriptor{}]) -> [ok | inter_dc_conn_err()].
observe_dcs(Descriptors) -> lists:map(fun observe_dc/1, Descriptors).

-spec observe_dcs_sync([#descriptor{}]) -> [ok | inter_dc_conn_err()].
observe_dcs_sync(Descriptors) ->
    {ok, SS} = dc_utilities:get_stable_snapshot(),
    DCs = lists:map(fun(DC) ->
			    {observe_dc(DC), DC}
		    end, Descriptors),
    lists:foreach(fun({Res, Desc = #descriptor{dcid = DCID, partition_list = PartitionList}}) ->
			  case Res of
			      ok ->
				  Value = vectorclock:get_clock_of_dc(DCID, SS),
				  wait_for_stable_snapshot(DCID, Value),
				  case DCID == dc_utilities:get_my_dc_id() of
				      true -> ok;
				      false ->
					  ok = dc_meta_data_utilities:set_dc_partitions(PartitionList, DCID),
					  ok = dc_meta_data_utilities:store_dc_descriptors([Desc])
				  end;
			      _ ->
				  ok
			  end
		  end, DCs),
    [Result1 || {Result1, _DC1} <- DCs].

-spec observe_dc_sync(#descriptor{}) -> ok | inter_dc_conn_err().
observe_dc_sync(Descriptor) ->
    [Res] = observe_dcs_sync([Descriptor]),
    Res.

-spec forget_dc(#descriptor{}) -> ok.
forget_dc(#descriptor{dcid = DCID}) ->
  case DCID == dc_meta_data_utilities:get_my_dc_id() of
    true -> ok;
    false ->
      lager:info("Forgetting DC ~p", [DCID]),
      Nodes = dc_utilities:get_my_dc_nodes(),
      lists:foreach(fun(Node) -> ok = rpc:call(Node, inter_dc_query, del_dc, [DCID]) end, Nodes),
      lists:foreach(fun(Node) -> ok = rpc:call(Node, inter_dc_sub, del_dc, [DCID]) end, Nodes)
  end.

-spec forget_dcs([#descriptor{}]) -> ok.
forget_dcs(Descriptors) -> lists:foreach(fun forget_dc/1, Descriptors).

%% Tell nodes within the DC to drop heartbeat ping messages from other
%% DCs, used for debugging
-spec drop_ping(boolean()) -> ok.
drop_ping(DropPing) ->
    Responses = dc_utilities:bcast_vnode_sync(inter_dc_dep_vnode_master, {drop_ping, DropPing}),
    %% Be sure they all returned ok, crash otherwise
    ok = lists:foreach(fun({_, ok}) ->
			       ok
		       end, Responses).    

%%%%%%%%%%%%%
%% Utils

observe(DcNodeAddress) ->
  {ok, Desc} = rpc:call(DcNodeAddress, inter_dc_manager, get_descriptor, []),
  observe_dc(Desc).

wait_for_stable_snapshot(DCID, MinValue) ->
  case DCID == dc_meta_data_utilities:get_my_dc_id() of
    true -> ok;
    false ->
      {ok, SS} = dc_utilities:get_stable_snapshot(),
      Value = vectorclock:get_clock_of_dc(DCID, SS),
      case Value > MinValue of
        true ->
          lager:info("Connected to DC ~p", [DCID]),
          ok;
        false ->
          lager:info("Waiting for DC ~p", [DCID]),
          timer:sleep(1000),
          wait_for_stable_snapshot(DCID, MinValue)
      end
  end.
