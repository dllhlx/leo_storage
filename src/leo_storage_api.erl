%%======================================================================
%%
%% LeoFS Storage
%%
%% Copyright (c) 2012-2015 Rakuten, Inc.
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
%% ---------------------------------------------------------------------
%% LeoFS Storage
%% @doc
%% @end
%%======================================================================
-module(leo_storage_api).

-author('Yosuke Hara').

-include("leo_storage.hrl").
-include_lib("leo_commons/include/leo_commons.hrl").
-include_lib("leo_logger/include/leo_logger.hrl").
-include_lib("leo_mq/include/leo_mq.hrl").
-include_lib("leo_object_storage/include/leo_object_storage.hrl").
-include_lib("leo_redundant_manager/include/leo_redundant_manager.hrl").
-include_lib("leo_watchdog/include/leo_watchdog.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([register_in_monitor/1, register_in_monitor/2,
         get_routing_table_chksum/0,
         update_manager_nodes/1, recover_remote/2,
         start/1, start/2, start/3, stop/0, attach/1,
         synchronize/1, synchronize/2,
         compact/1, compact/3, diagnose_data/0,
         get_node_status/0,
         rebalance/1, rebalance/3,
         get_disk_usage/0
        ]).
-export([get_mq_consumer_state/0,
         get_mq_consumer_state/1,
         mq_suspend/1,
         mq_resume/1
        ]).

%% interval to notify to leo_manager
-define(CHECK_INTERVAL, 3000).

%%--------------------------------------------------------------------
%% API for Admin and System#1
%%--------------------------------------------------------------------
%% @doc register into the manager's monitor.
%%
-spec(register_in_monitor(RequestedTimes) ->
             ok | {error, not_found} when RequestedTimes::first|again).
register_in_monitor(RequestedTimes) ->
    case whereis(leo_storage_sup) of
        undefined ->
            {error, not_found};
        Pid ->
            register_in_monitor(Pid, RequestedTimes)
    end.

-spec(register_in_monitor(Pid, RequestedTimes) ->
             ok | {error, any()} when Pid::pid(),
                                      RequestedTimes::first|again).
register_in_monitor(Pid, RequestedTimes) ->
    case register_in_monitor_1(?env_manager_nodes(leo_storage),
                               Pid, RequestedTimes) of
        true ->
            ok;
        false ->
            timer:apply_after(?CHECK_INTERVAL, ?MODULE, register_in_monitor,
                              [Pid, RequestedTimes]),
            ok
    end.

%% private
register_in_monitor_1([],_Pid,_RequestedTimes) ->
    false;
register_in_monitor_1([Node|Rest], Pid, RequestedTimes) ->
    Node_1 = case is_atom(Node) of
                true  -> Node;
                false -> list_to_atom(Node)
            end,

    Ret = case leo_misc:node_existence(Node_1) of
              true ->
                  GroupL_1   = ?env_grp_level_1(),
                  GroupL_2   = ?env_grp_level_2(),
                  NumOfNodes = ?env_num_of_vnodes(),
                  RPCPort    = ?env_rpc_port(),

                  case rpc:call(Node_1, leo_manager_api, register,
                                [RequestedTimes, Pid, erlang:node(), ?PERSISTENT_NODE,
                                 GroupL_1, GroupL_2, NumOfNodes, RPCPort], ?DEF_REQ_TIMEOUT) of
                      {ok, SystemConf} ->
                          case leo_cluster_tbl_conf:update(SystemConf) of
                              ok ->
                                  Options = lists:zip(
                                              record_info(
                                                fields, ?SYSTEM_CONF),
                                              tl(tuple_to_list(SystemConf))),
                                  ok = leo_redundant_manager_api:set_options(Options),
                                  true;
                              _ ->
                                  false
                          end;
                      Error ->
                          ?error("register_in_monitor/1",
                                 "manager:~w, cause:~p", [Node_1, Error]),
                          false
                  end;
              false ->
                  false
          end,

    case Ret of
        false ->
            register_in_monitor_1(Rest, Pid, RequestedTimes);
        _ ->
            Ret
    end.


%% @doc get routing_table's checksum.
%%
-spec(get_routing_table_chksum() ->
             {ok, integer()}).
get_routing_table_chksum() ->
    leo_redundant_manager_api:checksum(?CHECKSUM_RING).

%% @doc update manager nodes
%%
-spec(update_manager_nodes(Managers) ->
             ok when Managers::[atom()]).
update_manager_nodes(Managers) ->
    ?update_env_manager_nodes(leo_storage, Managers),
    leo_membership_cluster_local:update_manager_nodes(Managers).


%% recover a remote cluster's object
-spec(recover_remote(AddrId, Key) ->
             ok | {error, any()} when AddrId::integer(),
                                      Key::binary()).
recover_remote(AddrId, Key) ->
    case leo_object_storage_api:get({AddrId, Key}) of
        {ok, _Metadata, Object} ->
            leo_sync_remote_cluster:defer_stack(Object);
        not_found = Cause ->
            {error, Cause};
        {error, Cause} ->
            {error, Cause}
    end.


%% @doc start storage-server.
%%
-spec(start(MembersCur) ->
             {ok, {atom(), integer()}} |
             {error, {atom(), any()}} when MembersCur::[#member{}]).
start(MembersCur) ->
    start(MembersCur, undefined).
start([], _) ->
    {error, 'empty_members'};
start(MembersCur, SystemConf) ->
    start(MembersCur, [], SystemConf).

start(MembersCur, MembersPrev, SystemConf) ->
    case SystemConf of
        undefined -> ok;
        [] -> ok;
        _ ->
            Options = lists:zip(
                        record_info(
                          fields, ?SYSTEM_CONF),
                        tl(tuple_to_list(SystemConf))),
            ok = leo_redundant_manager_api:set_options(Options)
    end,
    start_1(MembersCur, MembersPrev).

%% @private
start_1(MembersCur, MembersPrev) ->
    case leo_redundant_manager_api:synchronize(
           ?SYNC_TARGET_MEMBER, [{?VER_CUR,  MembersCur },
                                 {?VER_PREV, MembersPrev}]) of
        {ok,_MembersChecksum} ->
            case leo_redundant_manager_api:create() of
                {ok,_,_} ->
                    {ok, Chksums} = leo_redundant_manager_api:checksum(?CHECKSUM_RING),
                    {ok, {node(), Chksums}};
                {error, Cause} ->
                    {error, {node(), Cause}}
            end;
        {error, Cause} ->
            {error, {node(), Cause}}
    end.


%% @doc
%%
-spec(stop() -> any()).
stop() ->
    Target = case init:get_argument(node) of
                 {ok, [[Node]]} ->
                     list_to_atom(Node);
                 error ->
                     erlang:node()
             end,

    _ = rpc:call(Target, leo_storage, stop, [], ?DEF_REQ_TIMEOUT),
    init:stop().


%% @doc attach a cluster.
%%
-spec(attach(SystemConf) ->
             ok | {error, any()} when SystemConf::#?SYSTEM_CONF{}).
attach(SystemConf) ->
    ok = leo_redundant_manager_api:set_options(
           [{cluster_id, SystemConf#?SYSTEM_CONF.cluster_id},
            {dc_id,      SystemConf#?SYSTEM_CONF.dc_id},
            {n, SystemConf#?SYSTEM_CONF.n},
            {r, SystemConf#?SYSTEM_CONF.r},
            {w, SystemConf#?SYSTEM_CONF.w},
            {d, SystemConf#?SYSTEM_CONF.d},
            {bit_of_ring, SystemConf#?SYSTEM_CONF.bit_of_ring},
            {num_of_dc_replicas,   SystemConf#?SYSTEM_CONF.num_of_dc_replicas},
            {num_of_rack_replicas, SystemConf#?SYSTEM_CONF.num_of_rack_replicas}]).


%%--------------------------------------------------------------------
%% API for Admin and System#3
%%--------------------------------------------------------------------
%% @doc synchronize a data.
%%
-spec(synchronize(Node) ->
             ok | {error, any()} when Node::atom()).
synchronize(Node) ->
    leo_storage_mq:publish(?QUEUE_TYPE_RECOVERY_NODE, Node).

-spec(synchronize(SyncTarget, SyncVal) ->
             ok |
             not_found |
             {error, any()} when SyncTarget::[atom()]|binary(),
                                 SyncVal::#?METADATA{}|atom()).
synchronize(InconsistentNodes, #?METADATA{addr_id = AddrId,
                                          key     = Key}) ->
    leo_storage_handler_object:replicate(InconsistentNodes, AddrId, Key);

synchronize(Key, ErrorType) ->
    {ok, #redundancies{vnode_id_to = VNodeId}} =
        leo_redundant_manager_api:get_redundancies_by_key(Key),
    leo_storage_mq:publish(?QUEUE_TYPE_PER_OBJECT, VNodeId, Key, ErrorType).


%%--------------------------------------------------------------------
%% API for Admin and System#4
%%--------------------------------------------------------------------
%% @doc Execute data-compaction
-spec(compact(start, NumOfTargets, MaxProc) ->
             ok |
             {error, any()} when NumOfTargets::'all' | integer(),
                                 MaxProc:: integer()).
compact(start, NumOfTargets, MaxProc) ->
    case leo_redundant_manager_api:get_member_by_node(erlang:node()) of
        {ok, #member{state = ?STATE_RUNNING}} ->
            TargetPids1 =
                case leo_compact_fsm_controller:state() of
                    {ok, #compaction_stats{status = Status,
                                           pending_targets = PendingTargets}}
                      when Status == ?ST_SUSPENDING;
                           Status == ?ST_IDLING ->
                        PendingTargets;
                    _ ->
                        []
                end,

            case TargetPids1 of
                [] ->
                    {error, "Not exists compaction-targets"};
                _ ->
                    TargetPids2 =
                        case NumOfTargets of
                            'all' ->
                                TargetPids1;
                            _Other ->
                                lists:sublist(TargetPids1, NumOfTargets)
                        end,
                    leo_object_storage_api:compact_data(
                      TargetPids2, MaxProc,
                      fun leo_redundant_manager_api:has_charge_of_node/2)
            end;
        _ ->
            {error,'not_running'}
    end.

-spec(compact(Method) ->
             ok |
             {error, any()} when Method::atom()).
compact(Method) ->
    case leo_redundant_manager_api:get_member_by_node(erlang:node()) of
        {ok, #member{state = ?STATE_RUNNING}} ->
            compact_1(Method);
        _ ->
            {error,'not_running'}
    end.

%% @private
compact_1(suspend) ->
    leo_compact_fsm_controller:suspend();
compact_1(resume) ->
    leo_compact_fsm_controller:resume();
compact_1(status) ->
    leo_compact_fsm_controller:state().


%% @doc Diagnose the data
-spec(diagnose_data() ->
             ok | {error, any()}).
diagnose_data() ->
    leo_compact_fsm_controller:diagnose().


%%--------------------------------------------------------------------
%% Maintenance
%%--------------------------------------------------------------------
%% @doc Retrieve the current node status
-spec(get_node_status() ->
             {ok, [tuple()]}).
get_node_status() ->
    Version = case application:get_key(leo_storage, vsn) of
                  {ok, _Version} -> _Version;
                  _ -> "undefined"
              end,

    {RingHashCur, RingHashPrev} =
        case leo_redundant_manager_api:checksum(?CHECKSUM_RING) of
            {ok, {Chksum0, Chksum1}} -> {Chksum0, Chksum1};
            _ -> {[], []}
        end,

    QueueDir  = case application:get_env(leo_storage, queue_dir) of
                    {ok, EnvQueueDir} -> EnvQueueDir;
                    _ -> []
                end,
    SNMPAgent = case application:get_env(leo_storage, snmp_agent) of
                    {ok, EnvSNMPAgent} -> EnvSNMPAgent;
                    _ -> []
                end,
    Directories = [{log,        ?env_log_dir(leo_storage)},
                   {mnesia,     []},
                   {queue,      QueueDir},
                   {snmp_agent, SNMPAgent}
                  ],
    RingHashes  = [{ring_cur,  RingHashCur},
                   {ring_prev, RingHashPrev }
                  ],

    NumOfQueue1 = case catch leo_mq_api:status(?QUEUE_ID_PER_OBJECT) of
                      {ok, Res_1} ->
                          leo_misc:get_value(?MQ_CNS_PROP_NUM_OF_MSGS, Res_1, 0);
                      _ -> 0
                  end,
    NumOfQueue2 = case catch leo_mq_api:status(?QUEUE_ID_SYNC_BY_VNODE_ID) of
                      {ok, Res_2} ->
                          leo_misc:get_value(?MQ_CNS_PROP_NUM_OF_MSGS, Res_2, 0);
                      _ -> 0
                  end,
    NumOfQueue3 = case catch leo_mq_api:status(?QUEUE_ID_REBALANCE) of
                      {ok, Res_3} ->
                          leo_misc:get_value(?MQ_CNS_PROP_NUM_OF_MSGS, Res_3, 0);
                      _ -> 0
                  end,

    Statistics  = [{vm_version,       erlang:system_info(version)},
                   {total_mem_usage,  erlang:memory(total)},
                   {system_mem_usage, erlang:memory(system)},
                   {proc_mem_usage,   erlang:memory(processes)},
                   {ets_mem_usage,    erlang:memory(ets)},
                   {num_of_procs,     erlang:system_info(process_count)},
                   {process_limit,    erlang:system_info(process_limit)},
                   {kernel_poll,      erlang:system_info(kernel_poll)},
                   {thread_pool_size, erlang:system_info(thread_pool_size)},
                   {storage,
                    [
                     {num_of_replication_msg, NumOfQueue1},
                     {num_of_sync_vnode_msg,  NumOfQueue2},
                     {num_of_rebalance_msg,   NumOfQueue3}
                    ]}
                  ],
    {ok, [
          {type,          storage},
          {version,       Version},
          {num_of_vnodes, ?env_num_of_vnodes()},
          {grp_level_2,   ?env_grp_level_2()},
          {dirs,          Directories},
          {avs,           ?env_storage_device()},
          {ring_checksum, RingHashes},
          {watchdog,
           [{cpu_enabled,    ?env_wd_cpu_enabled()},
            {io_enabled,     ?env_wd_io_enabled()},
            {disk_enabled,   ?env_wd_disk_enabled()},
            {rex_interval,   ?env_wd_rex_interval()},
            {cpu_interval,   ?env_wd_cpu_interval()},
            {io_interval,    ?env_wd_io_interval()},
            {disk_interval,  ?env_wd_disk_interval()},
            {rex_threshold_mem_capacity, ?env_wd_threshold_mem_capacity()},
            {cpu_threshold_cpu_load_avg, ?env_wd_threshold_cpu_load_avg()},
            {cpu_threshold_cpu_util,     ?env_wd_threshold_cpu_util()},
            {cpu_raised_error_times,     ?env_wd_cpu_raised_error_times()},
            {io_threshold_input_per_sec,  ?env_wd_threshold_input_per_sec()},
            {io_threshold_output_per_sec, ?env_wd_threshold_output_per_sec()},
            {disk_threshold_use,     ?env_wd_threshold_disk_use()},
            {disk_threshold_util,    ?env_wd_threshold_disk_util()},
            {disk_threshold_rkb,     ?env_wd_threshold_disk_rkb()},
            {disk_threshold_wkb,     ?env_wd_threshold_disk_wkb()},
            {disk_target_devices,         ?env_wd_disk_target_devices()},
            {disk_target_paths,           ?env_wd_disk_target_paths()},
            {disk_raised_error_times,     ?env_wd_disk_raised_error_times()}
           ]
          },
          %% mq-related
          {mq_num_of_procs, ?env_num_of_mq_procs()},
          {mq_num_of_batch_process_step, ?env_mq_num_of_batch_process_step()},
          {mq_num_of_batch_process_reg,  ?env_mq_num_of_batch_process_reg()},
          {mq_num_of_batch_process_max,  ?env_mq_num_of_batch_process_max()},
          {mq_num_of_batch_process_min,  ?env_mq_num_of_batch_process_min()},
          {mq_interval_between_batch_procs_step, ?env_mq_interval_between_batch_procs_step()},
          {mq_interval_between_batch_procs_reg,  ?env_mq_interval_between_batch_procs_reg()},
          {mq_interval_between_batch_procs_max,  ?env_mq_interval_between_batch_procs_max()},
          {mq_interval_between_batch_procs_min,  ?env_mq_interval_between_batch_procs_min()},
          %% auto-compaction-related
          {auto_compaction_enabled, ?env_auto_compaction_enabled()},
          {auto_compaction_warn_active_size_ratio,      ?env_warn_active_size_ratio()},
          {auto_compaction_threshold_active_size_ratio, ?env_threshold_active_size_ratio()},
          {auto_compaction_interval,                    ?env_auto_compaction_interval()},
          {auto_compaction_parallel_procs,              ?env_auto_compaction_parallel_procs()},
          %% compaction-related
          {limit_num_of_compaction_procs, ?env_limit_num_of_compaction_procs()},
          {compaction_num_of_batch_procs_min,            ?env_compaction_num_of_batch_procs_min()},
          {compaction_num_of_batch_procs_max,            ?env_compaction_num_of_batch_procs_max()},
          {compaction_num_of_batch_procs_reg,            ?env_compaction_num_of_batch_procs_reg()},
          {compaction_num_of_batch_procs_step,           ?env_compaction_num_of_batch_procs_step()},
          {compaction_interval_between_batch_procs_min,  ?env_compaction_interval_min()},
          {compaction_interval_between_batch_procs_max,  ?env_compaction_interval_max()},
          {compaction_interval_between_batch_procs_reg,  ?env_compaction_interval_reg()},
          {compaction_interval_between_batch_procs_step, ?env_compaction_interval_step()},
          %% others
          {statistics, Statistics}
         ]}.


%% @doc Do rebalance which means "Objects are copied to the specified node".
%% @param RebalanceInfo: [{VNodeId, DestNode}]
-spec(rebalance(RebalanceList) ->
             ok | {error, any()} when RebalanceList::[tuple()]).
rebalance(RebalanceList) ->
    catch leo_redundant_manager_api:force_sync_workers(),
    rebalance_1(RebalanceList).


-spec(rebalance(RebalanceList, MembersCur, MembersPrev) ->
             ok |
             {error, any()} when RebalanceList::[tuple()],
                                 MembersCur::[#member{}],
                                 MembersPrev::[#member{}]).
rebalance(RebalanceList, MembersCur, MembersPrev) ->
    case leo_redundant_manager_api:synchronize(
           ?SYNC_TARGET_BOTH, [{?VER_CUR,  MembersCur},
                               {?VER_PREV, MembersPrev}]) of
        {ok, Hashes} ->
            ok = rebalance(RebalanceList),
            {ok, Hashes};
        Error ->
            Error
    end.

%% @private
-spec(rebalance_1([tuple()]) ->
             ok).
rebalance_1([]) ->
    ok;
rebalance_1([{VNodeId, Node}|T]) ->
    QId = ?QUEUE_TYPE_SYNC_BY_VNODE_ID,
    case leo_storage_mq:publish(QId, VNodeId, Node) of
        ok ->
            rebalance_1(T);
        {error, Cause} ->
            ?warn("rebalance_1/1", "qid:~p, vnodeid:~p, node:~p, cause:~p",
                  [QId, VNodeId, Node, Cause]),
            {error, Cause}
    end.


%% @doc Get the disk usage(Total, Free) on leo_storage in KByte
-spec(get_disk_usage() ->
             {ok, {Total, Free}} when Total::pos_integer(),
                                      Free::pos_integer()).
get_disk_usage() ->
    PathList = case ?env_storage_device() of
                   [] -> [];
                   Devices ->
                       lists:map(fun(Item) ->
                                         leo_misc:get_value(path, Item)
                                 end, Devices)
               end,
    get_disk_usage(PathList, dict:new()).
get_disk_usage([], Dict) ->
    Ret = dict:fold(fun(_MountPath, {Total, Free}, {SumTotal, SumFree}) ->
                            {SumTotal + Total, SumFree + Free}
                    end,
                    {0, 0},
                    Dict),
    {ok, Ret};
get_disk_usage([Path|Rest], Dict) ->
    case leo_file:file_get_mount_path(Path) of
        {ok, {MountPath, TotalSize, UsedPercentage}} ->
            FreeSize = TotalSize * (100 - UsedPercentage) / 100,
            NewDict = dict:store(MountPath, {TotalSize, FreeSize}, Dict),
            get_disk_usage(Rest, NewDict);
        Error ->
            {error, Error}
    end.


%%--------------------------------------------------------------------
%% MQ-related
%%--------------------------------------------------------------------
%% @doc Retrieve mq-consumer state
-spec(get_mq_consumer_state() ->
             {ok, StateList} | not_found when StateList::{MQId, State, MsgCount},
                                              MQId::atom(),
                                              State::atom(),
                                              MsgCount::non_neg_integer()).
get_mq_consumer_state() ->
    case leo_mq_api:consumers() of
        {ok,  []} ->
            not_found;
        {ok, StateList} ->
            StateList_1 =
                lists:flatten(
                  lists:map(
                    fun(#mq_state{id = MQId} = S) ->
                            case leo_misc:get_value(MQId, ?mq_id_and_alias, []) of
                                [] ->
                                    [];
                                Desc ->
                                    S#mq_state{desc = Desc}
                            end
                    end, StateList)),
            {ok, StateList_1}
    end.

-spec(get_mq_consumer_state(MQId) ->
             {ok, StateList} | not_found when MQId::atom(),
                                              StateList::{Id, State, MsgCount},
                                              Id::atom(),
                                              State::atom(),
                                              MsgCount::non_neg_integer()).
get_mq_consumer_state(MQId) ->
    case leo_mq_api:consumers() of
        {ok,  []} ->
            not_found;
        {ok, Consumers} ->
            get_mq_consumer_state_1(Consumers, MQId)
    end.

%% @private
get_mq_consumer_state_1([],_MQId) ->
    not_found;
get_mq_consumer_state_1([#mq_state{id = MQId} = State|_], MQId) ->
    Desc = leo_misc:get_value(MQId, ?mq_id_and_alias, []),
    {ok, State#mq_state{desc = Desc}};
get_mq_consumer_state_1([_|Rest], MQId) ->
    get_mq_consumer_state_1(Rest, MQId).


%% @doc Suspend comsumption msg of the mq-consumer
-spec(mq_suspend(MQId) ->
             ok when MQId::atom()).
mq_suspend(MQId) ->
    leo_mq_api:suspend(MQId).


%% @doc Resume comsumption msg of the mq-consumer
-spec(mq_resume(MQId) ->
             ok when MQId::atom()).
mq_resume(MQId) ->
    leo_mq_api:resume(MQId).
