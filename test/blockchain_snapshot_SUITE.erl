-module(blockchain_snapshot_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("blockchain_vars.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).

-define(TEST_LOCATION, 631210968840687103).

-export([
    basic_test/1
]).

-import(blockchain_utils, [normalize_float/1]).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [
        basic_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------

init_per_testcase(_TestCase, Config) ->
    Config.

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(_, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------
basic_test(_Config) ->
    LedgerA = ledger(),
    case blockchain_ledger_v1:get_h3dex(LedgerA) of
        #{} ->
            LedgerBoot = blockchain_ledger_v1:new_context(LedgerA),
            blockchain:bootstrap_h3dex(LedgerBoot),
            blockchain_ledger_v1:commit_context(LedgerBoot);
        _ -> ok
    end,
    {ok, SnapshotA} = blockchain_ledger_snapshot_v1:snapshot(LedgerA, []),
    %% make a dir for the loaded snapshot
    {ok, Dir} = file:get_cwd(),
    PrivDir = filename:join([Dir, "priv"]),
    NewDir = PrivDir ++ "/ledger2/",
    ok = filelib:ensure_dir(NewDir),

    ?assertMatch(
        [_|_],
        maps:get(upgrades, SnapshotA, undefined),
        "New snapshot (A) has \"upgrades\" field."
    ),
    SnapshotAIOList = blockchain_ledger_snapshot_v1:serialize(SnapshotA),
    SnapshotABin = iolist_to_binary(SnapshotAIOList),
    ct:pal("dir: ~p", [os:cmd("pwd")]),
    {ok, BinGen} = file:read_file("../../../../test/genesis"),
    GenesisBlock = blockchain_block:deserialize(BinGen),
    {ok, Chain} = blockchain:new(NewDir, GenesisBlock, blessed_snapshot, undefined),
    {ok, SnapshotB} = blockchain_ledger_snapshot_v1:deserialize(SnapshotABin),
    ?assertMatch(
        [_|_],
        maps:get(upgrades, SnapshotB, undefined),
        "Deserialized snapshot (B) has \"upgrades\" field."
    ),
    ?assertEqual(
        snap_hash_without_field(upgrades, SnapshotA),
        snap_hash_without_field(upgrades, SnapshotB),
        "Hashes A and B are equal without \"upgrades\" field."
    ),
    LedgerB =
        blockchain_ledger_snapshot_v1:import(
            Chain,
            snap_hash_without_field(upgrades, SnapshotA),
            SnapshotB
        ),
    {ok, SnapshotC} = blockchain_ledger_snapshot_v1:snapshot(LedgerB, []),
    ?assertMatch(
        [_|_],
        maps:get(upgrades, SnapshotC, undefined),
        "New snapshot (C) has \"upgrades\" field."
    ),
    ?assertEqual(
        snap_hash_without_field(upgrades, SnapshotB),
        snap_hash_without_field(upgrades, SnapshotC),
        "Hashes B and C are equal without \"upgrades\" field."
    ),

    DiffAB = blockchain_ledger_snapshot_v1:diff(SnapshotA, SnapshotB),
    ct:pal("DiffAB: ~p", [DiffAB]),
    ?assertEqual([], DiffAB),
    ?assertEqual(SnapshotA, SnapshotB),
    DiffBC = blockchain_ledger_snapshot_v1:diff(SnapshotB, SnapshotC),
    ct:pal("DiffBC: ~p", [DiffBC]),

    %% TODO: C has new elements in upgrades. Should we assert something more specific?
    ?assertEqual([upgrades], DiffBC),
    %% Otherwise B and C should be the same:
    ?assertEqual(
        maps:remove(upgrades, SnapshotB),
        maps:remove(upgrades, SnapshotC)
    ),

    ok = blockchain:add_snapshot(SnapshotC, Chain),
    HashC = blockchain_ledger_snapshot_v1:hash(SnapshotC),
    {ok, SnapshotDBin} = blockchain:get_snapshot(HashC, Chain),
    {ok, SnapshotD} = blockchain_ledger_snapshot_v1:deserialize(HashC, SnapshotDBin),
    ?assertEqual(SnapshotC, SnapshotD),
    HashD = blockchain_ledger_snapshot_v1:hash(SnapshotD),
    ?assertEqual(HashC, HashD),
    ok.

%% utils
-spec snap_hash_without_field(atom(), map()) -> map().
snap_hash_without_field(Field, Snap) ->
    blockchain_ledger_snapshot_v1:hash(maps:remove(Field, Snap)).

ledger() ->
    %% Ledger at height: 194196
    %% ActiveGateway Count: 3023
    {ok, TestDir} = file:get_cwd(),  % this is deep in the test hierarchy

    Comps = filename:split(TestDir),
    Trimmed = lists:reverse(lists:sublist(lists:reverse(Comps), 5, length(Comps))),
    Dir = filename:join(Trimmed),
    %% Ensure priv dir exists
    PrivDir = filename:join([Dir, "priv"]),
    ok = filelib:ensure_dir(PrivDir ++ "/"),
    %% Path to static ledger tar
    LedgerTar = filename:join([PrivDir, "ledger.tar.gz"]),
    %% Extract ledger tar if required
    ok = extract_ledger_tar(PrivDir, LedgerTar),
    %% Get the ledger
    Ledger = blockchain_ledger_v1:new(PrivDir),
    Ledger1 = blockchain_ledger_v1:new_context(Ledger),
    %% If the hexes aren't on the ledger add them
    blockchain:bootstrap_hexes(Ledger1),
    blockchain_ledger_v1:commit_context(Ledger1),
    Ledger.

extract_ledger_tar(PrivDir, LedgerTar) ->
    case filelib:is_file(LedgerTar) of
        true ->
            %% if we have already unpacked it, no need to do it again
            LedgerDB = filename:join([PrivDir, "ledger.db"]),
            case filelib:is_dir(LedgerDB) of
                true ->
                    ok;
                false ->
                    %% ledger tar file present, extract
                    erl_tar:extract(LedgerTar, [compressed, {cwd, PrivDir}])
            end;
        false ->
            %% ledger tar file not found, download & extract
            ok = ssl:start(),
            {ok, {{_, 200, "OK"}, _, Body}} = httpc:request("https://blockchain-core.s3-us-west-1.amazonaws.com/ledger-387747.tar.gz"),
            ok = file:write_file(filename:join([PrivDir, "ledger.tar.gz"]), Body),
            erl_tar:extract(LedgerTar, [compressed, {cwd, PrivDir}])
    end.
