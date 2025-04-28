module vip::vip {
    use std::bcs;
    use std::error;
    use std::event;
    use std::hash::sha3_256;
    use std::option::{Self, Option};
    use std::signer;
    use std::string;
    use std::vector;

    use initia_std::block;
    use initia_std::coin;
    use initia_std::bigdecimal::{Self, BigDecimal};
    use initia_std::dex;
    use initia_std::fungible_asset::{Self, FungibleAsset, Metadata};
    use initia_std::object::{Self, Object};
    use initia_std::primary_fungible_store;
    use initia_std::simple_map::{Self, SimpleMap};
    use initia_std::stableswap;
    use initia_std::table::{Self, Table};
    use initia_std::table_key;

    use vip::lock_staking;
    use vip::operator;
    use vip::tvl_manager;
    use vip::utils;
    use vip::vault;
    use vip::vesting::{Self, UserVestingClaimInfo, OperatorVestingClaimInfo};

    friend vip::weight_vote;

    //
    // Errors
    //
    // PERMISSION ERROR
    const EUNAUTHORIZED: u64 = 1;
    // ALREADY EXISTS ERROR
    const EBRIDGE_ALREADY_REGISTERED: u64 = 2;
    const ESNAPSHOT_ALREADY_EXISTS: u64 = 3;
    // NOT FOUND ERROR
    const ESTAGE_DATA_NOT_FOUND: u64 = 4;
    const EBRIDGE_NOT_FOUND: u64 = 5;
    const ESNAPSHOT_NOT_FOUND: u64 = 6;
    const EBRIDGE_NOT_REGISTERED: u64 = 7;
    const EPREV_STAGE_SNAPSHOT_NOT_FOUND: u64 = 8;
    const EFUNDED_REWARD_NOT_FOUND: u64 = 9;
    // EINVLAID ERROR
    const EINVALID_MERKLE_PROOFS: u64 = 10;
    const EINVALID_PROOF_LENGTH: u64 = 11;
    const EINVALID_VEST_PERIOD: u64 = 12;
    const EINVALID_RATIO: u64 = 14;
    const EINVALID_CLAIMABLE_STAGE: u64 = 16;
    const EINVALID_BATCH_ARGUMENT: u64 = 17;
    const EINVALID_TOTAL_REWARD: u64 = 18;
    const EINVALID_WEIGHT: u64 = 19;
    const EINVALID_STAGE_ORDER: u64 = 20;
    const EINVALID_CLAIMABLE_PERIOD: u64 = 21;
    const EINVALID_CHALLENGE_PERIOD: u64 = 22;
    const EINVALID_CHALLENGE_STAGE: u64 = 23;
    const EINVALID_STAGE_INTERVAL: u64 = 24;
    const EINVALID_STAGE_SNAPSHOT: u64 = 25;
    const EINVALID_VM_TYPE: u64 = 26;

    // FUND
    const ETOO_EARLY_FUND: u64 = 27;
    // LOCK STAKING
    const EALREADY_FINALIZED: u64 = 28;
    const ESTAKELISTED_NOT_ENOUGH: u64 = 29;
    const EINVALID_LOCK_STAKING_AMOUNT: u64 = 30;
    const EINVALID_LOCK_STKAING_PERIOD: u64 = 31;
    const EINVALID_POOL: u64 = 32;

    // CLAIM
    const ECLAIMABLE_REWARD_CAN_BE_EXIST: u64 = 33;

    // MIN ELIGIBLE TVL
    const EMIN_ELIGIBLE_TVL: u64 = 34;

    //
    //  Constants
    //
    const PROOF_LENGTH: u64 = 32;
    const DEFAULT_POOL_SPLIT_RATIO: u64 = 4; // with 10 as the denominator
    const DEFAULT_MIN_SCORE_RATIO: u64 = 5; // with 10 as the denominator
    const DEFAULT_VESTING_PERIOD: u64 = 26; // 26 stages
    const DEFAULT_STAGE_INTERVAL: u64 = 60 * 60 * 24 * 7 * 2; // 2 weeks
    const DEFAULT_MINIMUM_ELIGIBLE_TVL: u64 = 0;
    const DEFAULT_MAXIMUM_TVL_RATIO: u64 = 10; // with 10 as the denominator
    const DEFAULT_MAXIMUM_WEIGHT_RATIO: u64 = 10; // with 10 as the denominator
    const DEFAULT_VIP_START_STAGE: u64 = 0;
    const DEFAULT_CHALLENGE_PERIOD: u64 = 60 * 60 * 24; // 1 day
    const DEFAULT_LOCK_STAKE_PERIOD: u64 = 60 * 60 * 24 * 7 * 26; // 26 weeks

    // vm type
    const MOVEVM: u64 = 0;
    const WASMVM: u64 = 1;
    const EVM: u64 = 2;

    struct ModuleStore has key {
        // current stage
        stage: u64,
        // stage start time
        stage_start_time: u64,
        // stage end time
        stage_end_time: u64,
        // governance-defined vesting period in stage unit
        stage_interval: u64,
        // the number of times vesting is divided
        vesting_period: u64,
        // minimum lock stake preiod
        minimum_lock_staking_period: u64,
        // interval time of vesting
        challenge_period: u64,
        // agent for snapshot taker and VIP reward funder
        agent_data: AgentData,
        // governance-defined minimum_score_ratio to decrease overhead of keeping the L2 INIT balance.
        // a user only need to keep the `vesting.l2_score * minimum_score_ratio` amount of INIT token
        // to vest whole vesting rewards.
        minimum_score_ratio: BigDecimal,
        // if pool_split_ratio is 0.4,
        // balance pool takes 0.4 and voting weight pool takes 0.6
        pool_split_ratio: BigDecimal,
        // DEPRECATED
        maximum_tvl_ratio: BigDecimal,
        // minimum eligible TVL of L2 INIT token to receive the reward.
        minimum_eligible_tvl: u64,
        // maximum weight (voting weight + tvl) of VIP reward
        maximum_weight_ratio: BigDecimal,
        // a set of stage data
        stage_data: Table<vector<u8> /* stage */, StageData>,
        // a set of bridge info
        bridges: Table<BridgeInfoKey, Bridge>,
        challenges: Table<vector<u8>, ExecutedChallenge>
    }

    struct BridgeInfoKey has drop, copy {
        is_registered: bool,
        bridge_id: vector<u8>,
        version: vector<u8>
    }

    struct SnapshotKey has drop, copy {
        bridge_id: vector<u8>,
        version: vector<u8>
    }

    struct AgentData has store, drop {
        agent: address,
        api_uri: string::String
    }

    struct StageData has store {
        stage_start_time: u64,
        stage_end_time: u64,
        pool_split_ratio: BigDecimal,
        total_operator_funded_reward: u64,
        operator_funded_rewards: Table<u64 /* bridge id */, u64>,
        total_user_funded_reward: u64,
        user_funded_rewards: Table<u64 /* bridge id */, u64>,
        vesting_period: u64,
        minimum_score_ratio: BigDecimal,
        snapshots: Table<SnapshotKey, Snapshot>
    }

    struct Snapshot has store, drop {
        create_time: u64,
        upsert_time: u64,
        merkle_root: vector<u8>,
        total_l2_score: u64
    }

    struct Bridge has store, drop {
        init_stage: u64, // stage to start scoring and distribution reward
        end_stage: u64, // if 0, registered else deregistered bridge.
        bridge_addr: address,
        operator_addr: address,
        vip_l2_score_contract: string::String,
        vip_weight: BigDecimal,
        vm_type: u64
    }

    struct ExecutedChallenge has store, drop {
        challenge_id: u64,
        bridge_id: u64,
        version: u64,
        stage: u64,
        new_l2_total_score: u64,
        title: string::String,
        summary: string::String,
        api_uri: string::String,
        new_agent: address,
        merkle_root: vector<u8>
    }

    //
    // Responses
    //
    struct BridgeResponse has drop {
        init_stage: u64,
        bridge_id: u64,
        version: u64,
        bridge_addr: address,
        operator_addr: address,
        vip_l2_score_contract: string::String,
        vip_weight: BigDecimal,
        vm_type: u64
    }

    struct TotalL2ScoreResponse has drop {
        bridge_id: u64,
        version: u64,
        total_l2_score: u64
    }

    //
    // Events
    //
    #[event]
    struct FundEvent has drop, store {
        stage: u64,
        total_operator_funded_reward: u64,
        total_user_funded_reward: u64
    }

    #[event]
    struct RewardDistributionEvent has drop, store {
        stage: u64,
        bridge_id: u64,
        version: u64,
        user_reward_amount: u64,
        operator_reward_amount: u64
    }

    #[event]
    struct StageAdvanceEvent has drop, store {
        stage: u64,
        stage_start_time: u64,
        stage_end_time: u64,
        pool_split_ratio: BigDecimal,
        total_operator_funded_reward: u64,
        total_user_funded_reward: u64,
        vesting_period: u64,
        minimum_score_ratio: BigDecimal
    }

    // DEPRECATED
    #[event]
    struct ReleaseTimeUpdateEvent has drop, store {
        stage: u64
    }

    #[event]
    struct ExecuteChallengeEvent has drop, store {
        challenge_id: u64,
        bridge_id: u64,
        version: u64,
        stage: u64,
        title: string::String,
        summary: string::String,
        api_uri: string::String,
        new_agent: address,
        merkle_root: vector<u8>
    }

    #[event]
    struct SubmitSnapshotEvent has drop, store {
        bridge_id: u64,
        version: u64,
        stage: u64,
        total_l2_score: u64,
        merkle_root: vector<u8>,
        create_time: u64
    }

    //
    // Implementations
    //
    public entry fun initialize(
        chain: &signer,
        stage_start_time: u64,
        agent: address,
        api: string::String
    ) {
        utils::check_chain_permission(chain);
        move_to(
            chain,
            ModuleStore {
                stage: DEFAULT_VIP_START_STAGE,
                stage_start_time: stage_start_time,
                stage_end_time: stage_start_time,
                stage_interval: DEFAULT_STAGE_INTERVAL,
                vesting_period: DEFAULT_VESTING_PERIOD,
                minimum_lock_staking_period: DEFAULT_LOCK_STAKE_PERIOD,
                challenge_period: DEFAULT_CHALLENGE_PERIOD,
                minimum_score_ratio: bigdecimal::from_ratio_u64(
                    DEFAULT_MIN_SCORE_RATIO, 10
                ),
                pool_split_ratio: bigdecimal::from_ratio_u64(
                    DEFAULT_POOL_SPLIT_RATIO, 10
                ),
                agent_data: AgentData { agent: agent, api_uri: api },
                maximum_tvl_ratio: bigdecimal::from_ratio_u64(0, 1), // DEPRECATED
                minimum_eligible_tvl: DEFAULT_MINIMUM_ELIGIBLE_TVL,
                maximum_weight_ratio: bigdecimal::from_ratio_u64(
                    DEFAULT_MAXIMUM_WEIGHT_RATIO, 10
                ),
                stage_data: table::new<vector<u8>, StageData>(),
                bridges: table::new<BridgeInfoKey, Bridge>(),
                challenges: table::new<vector<u8>, ExecutedChallenge>()
            }
        );
    }

    // Compare bytes and return a following result number:
    // 0: equal
    // 1: v1 is greator than v2
    // 2: v1 is less than v2
    fun bytes_cmp(v1: &vector<u8>, v2: &vector<u8>): u8 {
        assert!(
            vector::length(v1) == PROOF_LENGTH,
            error::invalid_argument(EINVALID_PROOF_LENGTH)
        );
        assert!(
            vector::length(v2) == PROOF_LENGTH,
            error::invalid_argument(EINVALID_PROOF_LENGTH)
        );

        let i = 0;
        while (i < 32) {
            let e1 = *vector::borrow(v1, i);
            let e2 = *vector::borrow(v2, i);
            if (e1 > e2) {
                return 1
            } else if (e2 > e1) {
                return 2
            };
            i = i + 1;
        };

        0
    }

    fun score_hash(
        bridge_id: u64,
        stage: u64,
        account_addr: address,
        l2_score: u64,
        total_l2_score: u64
    ): vector<u8> {
        let target_hash = {
            let score_data = vector::empty<u8>();
            vector::append(&mut score_data, bcs::to_bytes(&bridge_id));
            vector::append(&mut score_data, bcs::to_bytes(&stage));
            vector::append(&mut score_data, bcs::to_bytes(&account_addr));
            vector::append(&mut score_data, bcs::to_bytes(&l2_score));
            vector::append(
                &mut score_data,
                bcs::to_bytes(&total_l2_score)
            );

            sha3_256(score_data)
        };
        target_hash
    }

    // merkle proofs can be empty vector
    fun assert_merkle_proofs(
        merkle_proofs: vector<vector<u8>>,
        merkle_root: vector<u8>,
        target_hash: vector<u8>
    ) {
        // must use sorted merkle tree
        let i = 0;
        let len = vector::length(&merkle_proofs);
        let root_seed = target_hash;

        while (i < len) {
            let proof = vector::borrow(&merkle_proofs, i);

            let cmp = bytes_cmp(&root_seed, proof);
            root_seed =
                if (cmp == 2 /* less */) {
                    let tmp = vector::empty();
                    vector::append(&mut tmp, root_seed);
                    vector::append(&mut tmp, *proof);

                    sha3_256(tmp)
                } else /* greator or equals */ {
                    let tmp = vector::empty();
                    vector::append(&mut tmp, *proof);
                    vector::append(&mut tmp, root_seed);

                    sha3_256(tmp)
                };

            i = i + 1;
        };
        let root_hash = root_seed;
        assert!(
            merkle_root == root_hash,
            error::invalid_argument(EINVALID_MERKLE_PROOFS)
        );
    }

    fun check_agent_permission(agent: &signer) acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        assert!(
            signer::address_of(agent) == module_store.agent_data.agent,
            error::permission_denied(EUNAUTHORIZED)
        );
    }

    // check if the previous stage snapshot exists to prevent skipping stage
    fun check_previous_stage_snapshot(
        imut_module_store: &ModuleStore,
        bridge_id: u64,
        version: u64,
        stage: u64
    ) {
        let bridge_vec = table_key::encode_u64(bridge_id);
        let version_vec = table_key::encode_u64(version);
        let registered_key = BridgeInfoKey {
            is_registered: true,
            bridge_id: bridge_vec,
            version: version_vec
        };
        let is_registered = table::contains(&imut_module_store.bridges, registered_key);
        let key =
            if (is_registered) {
                registered_key
            } else {
                registered_key.is_registered = false;

                assert!(
                    table::contains(&imut_module_store.bridges, registered_key),
                    error::not_found(EBRIDGE_NOT_FOUND)
                );

                registered_key
            };
        // if current stage is init stage of bridge, then skip this check
        let bridge_info = table::borrow(&imut_module_store.bridges, key);
        let init_stage = bridge_info.init_stage;
        if (stage != init_stage) {
            let prev_stage_data =
                table::borrow(
                    &imut_module_store.stage_data,
                    table_key::encode_u64(stage - 1)
                );
            assert!(
                table::contains(
                    &prev_stage_data.snapshots,
                    SnapshotKey { bridge_id: bridge_vec, version: version_vec }
                ),
                error::not_found(EPREV_STAGE_SNAPSHOT_NOT_FOUND)
            );
        };

        // check end stage
        assert!(
            bridge_info.end_stage == 0 || bridge_info.end_stage >= stage,
            error::unavailable(EBRIDGE_NOT_REGISTERED)
        );
    }

    fun lock_stake(
        account: &signer,
        lp_metadata: Object<Metadata>,
        min_liquidity: option::Option<u64>,
        validator: string::String,
        esinit: FungibleAsset,
        stakelisted_metadata: Object<Metadata>,
        stakelisted_amount: u64,
        release_time_option: Option<u64>
    ) acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        let account_addr = signer::address_of(account);
        assert!(
            primary_fungible_store::balance(account_addr, stakelisted_metadata)
                >= stakelisted_amount,
            error::invalid_argument(ESTAKELISTED_NOT_ENOUGH)
        );
        assert!(
            fungible_asset::amount(&esinit) > 0 && stakelisted_amount > 0,
            error::invalid_argument(EINVALID_LOCK_STAKING_AMOUNT)
        );

        let stakelisted =
            primary_fungible_store::withdraw(
                account,
                stakelisted_metadata,
                stakelisted_amount
            );

        let release_time = get_release_time(module_store, release_time_option);

        let pair = object::convert<Metadata, dex::Config>(lp_metadata);
        let esinit_metadata = fungible_asset::asset_metadata(&esinit);

        let (coin_a_metadata, coin_b_metadata) = dex::pool_metadata(pair);

        // if pair is reversed, swap coin_a and coin_b
        let (coin_a, coin_b) =
            if (coin_a_metadata == esinit_metadata) {
                (esinit, stakelisted)
            } else if (coin_b_metadata == esinit_metadata) {
                (stakelisted, esinit)
            } else {
                abort error::invalid_argument(EINVALID_POOL)
            };

        let liquidity = dex::provide_liquidity(pair, coin_a, coin_b, min_liquidity);
        lock_staking::delegate_internal(account, liquidity, release_time, validator);
    }

    fun stableswap_lock_stake(
        account: &signer,
        lp_metadata: Object<Metadata>,
        min_liquidity: option::Option<u64>,
        validator: string::String,
        esinit: FungibleAsset,
        release_time_option: Option<u64>
    ) acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        assert!(
            fungible_asset::amount(&esinit) > 0,
            error::invalid_argument(EINVALID_LOCK_STAKING_AMOUNT)
        );

        let pool = object::convert<Metadata, stableswap::Pool>(lp_metadata);
        let (coin_metadata, pool_amounts, _, _) = stableswap::pool_info(pool);
        let esinit_amount = fungible_asset::amount(&esinit);
        let esinit_metadata = fungible_asset::asset_metadata(&esinit);
        let (found, esinit_index) = vector::find(
            &coin_metadata, |metadata| { *metadata == esinit_metadata }
        );

        assert!(found, error::invalid_argument(EINVALID_POOL));

        let i = 0;
        let len = vector::length(&coin_metadata);
        let coins: vector<FungibleAsset> = vector[];

        while (i < len) {
            let coin =
                if (i == esinit_index) {
                    fungible_asset::extract(&mut esinit, esinit_amount)
                } else {
                    let amount =
                        (esinit_amount as u128)
                            * (*vector::borrow(&pool_amounts, i) as u128)
                            / (*vector::borrow(&pool_amounts, esinit_index) as u128);
                    primary_fungible_store::withdraw(
                        account,
                        *vector::borrow(&coin_metadata, i),
                        (amount as u64)
                    )
                };

            vector::push_back(&mut coins, coin);
            i = i + 1;
        };
        fungible_asset::destroy_zero(esinit);

        let release_time = get_release_time(module_store, release_time_option);

        let liquidity = stableswap::provide_liquidity(pool, coins, min_liquidity);
        lock_staking::delegate_internal(account, liquidity, release_time, validator);
    }

    fun get_release_time(
        module_store: &ModuleStore, release_time_option: Option<u64>
    ): u64 {
        let (_, curr_time) = block::get_block_info();
        if (option::is_some(&release_time_option)) {
            assert!(
                *option::borrow(&release_time_option) - curr_time
                    >= module_store.minimum_lock_staking_period,
                error::invalid_argument(EINVALID_LOCK_STKAING_PERIOD)
            );
            *option::borrow(&release_time_option)
        } else {
            curr_time + module_store.minimum_lock_staking_period
        }
    }

    fun withdraw_esinit_for_lock_stake(
        account: &signer,
        bridge_id: u64,
        version: u64,
        stage: vector<u64>,
        esinit_amount: vector<u64>
    ): FungibleAsset acquires ModuleStore {
        let account_addr = signer::address_of(account);

        assert!(
            vector::length(&esinit_amount) == vector::length(&stage),
            error::invalid_argument(EINVALID_BATCH_ARGUMENT)
        );

        let esinit_metadata = vault::reward_metadata();
        let esinit = fungible_asset::zero(esinit_metadata);

        vector::enumerate_ref(
            &stage,
            |i, s| {
                check_lock_stakable(account_addr, bridge_id, version, *s);
                let amount = *vector::borrow(&esinit_amount, i);
                let withdrawn_asset =
                    vesting::withdraw_vesting(
                        account_addr, bridge_id, version, *s, amount
                    );

                fungible_asset::merge(&mut esinit, withdrawn_asset);
            }
        );

        esinit
    }

    fun calc_operator_and_user_reward_amount(
        bridge_id: u64, version: u64, reward_amount: u64
    ): (u64, u64) {
        let commission_rate = operator::get_operator_commission(bridge_id, version);
        let operator_reward_amount =
            bigdecimal::mul_by_u64_truncate(commission_rate, reward_amount);
        let user_reward_amount = reward_amount - operator_reward_amount;
        (operator_reward_amount, user_reward_amount)
    }

    fun split_reward(
        stage: u64,
        shares: &SimpleMap<u64, BigDecimal>,
        total_reward_amount: u64,
        bridge_ids: vector<u64>,
        versions: vector<u64>
    ): (u64, u64, Table<u64, u64>, Table<u64, u64>) {
        let total_user_funded_reward = 0;
        let total_operator_funded_reward = 0;
        let user_funded_reward_table = table::new();
        let operator_funded_reward_table = table::new();
        vector::enumerate_ref(
            &bridge_ids,
            |i, bridge_id| {
                let version = *vector::borrow(&versions, i);
                // split the reward of balance pool
                let reward_amount =
                    split_reward_with_share_internal(
                        shares, *bridge_id, total_reward_amount
                    );

                // (weight + balance) reward splited to operator and user reward
                let (operator_funded_reward, user_funded_reward) =
                    calc_operator_and_user_reward_amount(
                        *bridge_id, version, reward_amount
                    );
                total_operator_funded_reward =
                    total_operator_funded_reward + operator_funded_reward;
                total_user_funded_reward = total_user_funded_reward
                    + user_funded_reward;
                event::emit(
                    RewardDistributionEvent {
                        stage,
                        bridge_id: *bridge_id,
                        version,
                        user_reward_amount: user_funded_reward,
                        operator_reward_amount: operator_funded_reward
                    }
                );

                table::add(&mut user_funded_reward_table, *bridge_id, user_funded_reward);
                table::add(
                    &mut operator_funded_reward_table,
                    *bridge_id,
                    operator_funded_reward
                );
            }
        );

        event::emit(
            FundEvent { stage, total_operator_funded_reward, total_user_funded_reward }
        );
        (
            total_operator_funded_reward,
            total_user_funded_reward,
            operator_funded_reward_table,
            user_funded_reward_table
        )
    }

    fun split_reward_with_share_internal(
        shares: &SimpleMap<u64, BigDecimal>,
        bridge_id: u64,
        total_reward_amount: u64
    ): u64 {
        let share_ratio = *simple_map::borrow(shares, &bridge_id);
        let split_amount =
            bigdecimal::mul_by_u64_truncate(share_ratio, total_reward_amount);
        split_amount
    }

    fun get_user_funded_reward_internal(
        module_store: &ModuleStore, bridge_id: u64, stage: u64
    ): u64 {
        let stage_key = table_key::encode_u64(stage);
        assert!(
            table::contains(&module_store.stage_data, stage_key),
            error::not_found(ESTAGE_DATA_NOT_FOUND)
        );
        let stage_data = table::borrow(&module_store.stage_data, stage_key);

        assert!(
            table::contains(&stage_data.user_funded_rewards, bridge_id),
            error::not_found(EFUNDED_REWARD_NOT_FOUND)
        );
        *table::borrow(&stage_data.user_funded_rewards, bridge_id)
    }

    fun get_operator_funded_reward_internal(
        module_store: &ModuleStore, bridge_id: u64, stage: u64
    ): u64 {
        let stage_key = table_key::encode_u64(stage);
        assert!(
            table::contains(&module_store.stage_data, stage_key),
            error::not_found(ESTAGE_DATA_NOT_FOUND)
        );
        let stage_data = table::borrow(&module_store.stage_data, stage_key);

        assert!(
            table::contains(&stage_data.operator_funded_rewards, bridge_id),
            error::not_found(EFUNDED_REWARD_NOT_FOUND)
        );
        *table::borrow(&stage_data.operator_funded_rewards, bridge_id)
    }

    // fund reward to distribute to operators and users and distribute previous stage rewards
    fun fund_reward(
        module_store: &mut ModuleStore, stage: u64, initial_reward_amount: u64
    ): (u64, u64, Table<u64, u64>, Table<u64, u64>) {
        let (bridge_ids, versions) = get_whitelisted_bridge_ids_internal(module_store);
        let shares = calculate_share(module_store);

        let (
            total_operator_funded_reward,
            total_user_funded_reward,
            operator_funded_rewards,
            user_funded_rewards
        ) = split_reward(
            stage,
            &shares,
            initial_reward_amount,
            bridge_ids,
            versions
        );

        (
            total_operator_funded_reward,
            total_user_funded_reward,
            operator_funded_rewards,
            user_funded_rewards
        )
    }

    fun calculate_share(module_store: &ModuleStore): SimpleMap<u64, BigDecimal> {
        let bridge_balances: SimpleMap<u64, u64> = simple_map::new();
        let total_balance = 0;
        let shares: SimpleMap<u64, BigDecimal> = simple_map::new<u64, BigDecimal>();
        let weight_vote_ratio =
            bigdecimal::sub(bigdecimal::one(), module_store.pool_split_ratio);
        utils::walk(
            &module_store.bridges,
            option::some(
                BridgeInfoKey {
                    is_registered: true,
                    bridge_id: table_key::encode_u64(0),
                    version: table_key::encode_u64(0)
                }
            ),
            option::none(),
            1,
            |key, bridge| {
                let (is_registered, bridge_id, _) = unpack_bridge_info_key(key);
                if (is_registered) {
                    simple_map::add(
                        &mut shares,
                        bridge_id,
                        bigdecimal::mul(bridge.vip_weight, weight_vote_ratio)
                    );
                    let bridge_balance =
                        tvl_manager::get_average_tvl(module_store.stage, bridge_id);
                    total_balance = total_balance + bridge_balance;
                    simple_map::add(
                        &mut bridge_balances,
                        bridge_id,
                        bridge_balance
                    );
                };
                false
            }
        );

        let bridge_ids = simple_map::keys(&shares);
        // calculate balance share by total balance
        vector::for_each_ref(
            &bridge_ids,
            |bridge_id| {
                let bridge_balance = *simple_map::borrow(&bridge_balances, bridge_id);
                let balance_share =
                    if (total_balance == 0) {
                        bigdecimal::zero()
                    } else {
                        bigdecimal::from_ratio_u64(bridge_balance, total_balance)
                    };
                let share = simple_map::borrow_mut(&mut shares, bridge_id);
                *share = bigdecimal::add(
                    *share,
                    bigdecimal::mul(balance_share, module_store.pool_split_ratio)
                );
                if (bigdecimal::gt(*share, module_store.maximum_weight_ratio)) {
                    *share = module_store.maximum_weight_ratio;
                };

                // make zero share if tvl is less than `minimum_eligible_tvl`
                if (bridge_balance < module_store.minimum_eligible_tvl) {
                    *share = bigdecimal::zero();
                };
            }
        );

        shares
    }

    fun validate_vip_weights(module_store: &ModuleStore) {
        let total_weight = bigdecimal::zero();
        utils::walk(
            &module_store.bridges,
            option::some(
                BridgeInfoKey {
                    is_registered: true,
                    bridge_id: table_key::encode_u64(0),
                    version: table_key::encode_u64(0)
                }
            ),
            option::none(),
            1,
            |_key, bridge| {
                total_weight = bigdecimal::add(total_weight, bridge.vip_weight);
                false
            }
        );

        assert!(
            bigdecimal::le(total_weight, bigdecimal::one()),
            error::invalid_argument(EINVALID_WEIGHT)
        );
    }

    fun get_whitelisted_bridge_ids_internal(
        module_store: &ModuleStore
    ): (vector<u64>, vector<u64>) {
        let bridge_ids = vector::empty<u64>();
        let versions = vector::empty<u64>();
        utils::walk(
            &module_store.bridges,
            option::some(
                BridgeInfoKey {
                    is_registered: true,
                    bridge_id: table_key::encode_u64(0),
                    version: table_key::encode_u64(0)
                }
            ),
            option::none(),
            1,
            |key, _v| {
                let (_, bridge_id, version) = unpack_bridge_info_key(key);
                vector::push_back(&mut bridge_ids, bridge_id);

                vector::push_back(&mut versions, version);

                false
            }
        );
        (bridge_ids, versions)
    }

    fun check_user_reward_claimable(
        module_store: &mut ModuleStore,
        account: &signer,
        bridge_id: u64,
        version: u64,
        start_stage: u64,
        end_stage: u64
    ) {
        let account_addr = signer::address_of(account);

        // check claimable on final stage by challenge period
        assert!(
            is_after_challenge_period(module_store, bridge_id, version, end_stage),
            error::permission_denied(EINVALID_CLAIMABLE_PERIOD)
        );
        let (is_registered, last_version) =
            get_last_bridge_version(module_store, bridge_id);
        let is_bridge_registered = is_registered && last_version == version;

        // check if the claim is attempted from a position that has not been finalized.
        let bridge_info =
            table::borrow(
                &module_store.bridges,
                BridgeInfoKey {
                    is_registered: is_bridge_registered,
                    bridge_id: table_key::encode_u64(bridge_id),
                    version: table_key::encode_u64(version)
                }
            );
        let init_stage = bridge_info.init_stage;
        let is_vesting_store_registered =
            vesting::is_user_vesting_store_registered(account_addr, bridge_id, version);
        // hypothesis: for a claimed vesting position, all its previous stages must also be claimed.
        // so if vesting position of prev stage is claimed, then it will be okay but if it's not, make the error
        if (start_stage >= init_stage + 1) {
            assert!(
                // first claim of vesting position (vesting_store doesn't exist)
                !is_vesting_store_registered
                    // or not the next claim must be the stage immediately following the last claimed stage
                    || vesting::get_user_last_claimed_stage(
                        account_addr, bridge_id, version
                    ) == start_stage - 1,
                error::invalid_argument(EINVALID_CLAIMABLE_STAGE)
            );
        };
        // if there is no vesting store, register it
        if (!is_vesting_store_registered) {
            vesting::register_user_vesting_store(account, bridge_id, version);
        };
    }

    fun check_lock_stakable(
        account_addr: address,
        bridge_id: u64,
        version: u64,
        stage: u64
    ) acquires ModuleStore {
        // check if it is already finalized
        assert!(
            vesting::has_user_vesting_position(account_addr, bridge_id, version, stage),
            error::invalid_state(EALREADY_FINALIZED)
        );

        // check if there is claimable reward remaining
        let last_claimed_stage =
            vesting::get_user_last_claimed_stage(account_addr, bridge_id, version);
        let last_submitted_stage = get_last_submitted_stage(bridge_id, version);
        let module_store = borrow_global<ModuleStore>(@vip);
        let has_claimable_reward =
            last_claimed_stage < last_submitted_stage
                && is_after_challenge_period(
                    module_store,
                    bridge_id,
                    version,
                    last_claimed_stage + 1
                );
        assert!(
            !has_claimable_reward,
            error::not_implemented(ECLAIMABLE_REWARD_CAN_BE_EXIST)
        );
    }

    public(friend) fun update_vip_weights_for_friend(
        bridge_ids: vector<u64>, weights: vector<BigDecimal>
    ) acquires ModuleStore {
        let module_store = borrow_global_mut<ModuleStore>(@vip);

        assert!(
            vector::length(&bridge_ids) == vector::length(&weights),
            error::invalid_argument(EINVALID_BATCH_ARGUMENT)
        );

        vector::enumerate_ref(
            &bridge_ids,
            |i, bridge_id_ref| {
                let bridge_id_key = table_key::encode_u64(*bridge_id_ref);
                let (is_registered, version) =
                    get_last_bridge_version(module_store, *bridge_id_ref);
                if (is_registered) {
                    let key = BridgeInfoKey {
                        is_registered: true,
                        bridge_id: bridge_id_key,
                        version: table_key::encode_u64(version)
                    };
                    let bridge = table::borrow_mut(&mut module_store.bridges, key);
                    bridge.vip_weight = *vector::borrow(&weights, i);
                }
            }
        );

        validate_vip_weights(module_store);
    }

    //
    // Entry Functions
    //
    public entry fun execute_challenge(
        chain: &signer,
        bridge_id: u64,
        challenge_stage: u64,
        challenge_id: u64,
        title: string::String,
        summary: string::String,
        new_api_uri: string::String,
        new_agent: address,
        new_merkle_root: vector<u8>,
        new_l2_total_score: u64
    ) acquires ModuleStore {
        utils::check_chain_permission(chain);
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        assert!(
            module_store.stage >= challenge_stage,
            error::permission_denied(EINVALID_CHALLENGE_STAGE)
        );
        let challenge_period = module_store.challenge_period;
        let (_, execution_time) = block::get_block_info();
        //check challenge period
        let (is_registered, version) = get_last_bridge_version(module_store, bridge_id);
        assert!(is_registered, error::unavailable(EBRIDGE_NOT_REGISTERED));

        let snapshot = load_snapshot_mut(
            module_store,
            challenge_stage,
            bridge_id,
            version
        );

        assert!(
            snapshot.create_time + challenge_period > execution_time,
            error::permission_denied(EINVALID_CHALLENGE_PERIOD)
        );

        let create_time = snapshot.create_time;
        // upsert snapshot data
        *snapshot = Snapshot {
            create_time: create_time,
            upsert_time: execution_time,
            merkle_root: new_merkle_root,
            total_l2_score: new_l2_total_score
        };

        // replace agent
        module_store.agent_data = AgentData { agent: new_agent, api_uri: new_api_uri };
        // make key of executed_challenge
        let key = table_key::encode_u64(challenge_id);
        // add executed_challenge
        table::add(
            &mut module_store.challenges,
            key,
            ExecutedChallenge {
                challenge_id,
                bridge_id,
                version,
                stage: challenge_stage,
                new_l2_total_score,
                title,
                summary,
                api_uri: new_api_uri,
                new_agent,
                merkle_root: new_merkle_root
            }
        );
        event::emit(
            ExecuteChallengeEvent {
                challenge_id,
                bridge_id,
                version,
                stage: challenge_stage,
                title,
                summary,
                api_uri: new_api_uri,
                new_agent,
                merkle_root: new_merkle_root
            }
        );
    }

    // register L2 by gov
    public entry fun register(
        chain: &signer,
        operator: address,
        bridge_id: u64,
        bridge_address: address,
        vip_l2_score_contract: string::String,
        operator_commission_max_rate: BigDecimal,
        operator_commission_max_change_rate: BigDecimal,
        operator_commission_rate: BigDecimal,
        vm_type: u64
    ) acquires ModuleStore {
        utils::check_chain_permission(chain);

        let module_store = borrow_global_mut<ModuleStore>(@vip);
        let (is_registered, version) = get_last_bridge_version(module_store, bridge_id);
        assert!(!is_registered, error::unavailable(EBRIDGE_ALREADY_REGISTERED));

        let new_version = if (version != 0) {
            version + 1
        } else { 1 };
        // register chain stores
        if (!operator::is_bridge_registered(bridge_id, new_version)) {
            operator::register_operator_store(
                chain,
                operator,
                bridge_id,
                new_version,
                module_store.stage,
                operator_commission_max_rate,
                operator_commission_max_change_rate,
                operator_commission_rate
            );
        };
        // check vm type valid
        assert!(
            vm_type == MOVEVM || vm_type == WASMVM || vm_type == EVM,
            error::unavailable(EINVALID_VM_TYPE)
        );
        assert!(
            primary_fungible_store::balance(bridge_address, vault::reward_metadata())
                >= module_store.minimum_eligible_tvl,
            error::unavailable(EMIN_ELIGIBLE_TVL)
        );
        // bridge info
        table::add(
            &mut module_store.bridges,
            BridgeInfoKey {
                is_registered: true,
                bridge_id: table_key::encode_u64(bridge_id),
                version: table_key::encode_u64(new_version)
            },
            Bridge {
                init_stage: module_store.stage + 1,
                end_stage: 0,
                bridge_addr: bridge_address,
                operator_addr: operator,
                vip_l2_score_contract,
                vip_weight: bigdecimal::zero(),
                vm_type
            }
        );
    }

    public entry fun deregister(chain: &signer, bridge_id: u64) acquires ModuleStore {
        utils::check_chain_permission(chain);
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        let (is_registered, version) = get_last_bridge_version(module_store, bridge_id);
        assert!(is_registered, error::unavailable(EBRIDGE_NOT_REGISTERED));

        let bridge_id_vec = table_key::encode_u64(bridge_id);
        let version_vec = table_key::encode_u64(version);
        let bridge =
            table::remove(
                &mut module_store.bridges,
                BridgeInfoKey {
                    is_registered: true,
                    bridge_id: bridge_id_vec,
                    version: version_vec
                }
            );
        table::add(
            &mut module_store.bridges,
            BridgeInfoKey {
                is_registered: false,
                bridge_id: bridge_id_vec,
                version: version_vec
            },
            Bridge {
                init_stage: bridge.init_stage,
                end_stage: module_store.stage,
                bridge_addr: bridge.bridge_addr,
                operator_addr: bridge.operator_addr,
                vip_l2_score_contract: bridge.vip_l2_score_contract,
                vip_weight: bigdecimal::zero(),
                vm_type: bridge.vm_type
            }
        );
    }

    public entry fun update_agent(
        old_agent: &signer, new_agent: address, new_api_uri: string::String
    ) acquires ModuleStore {
        check_agent_permission(old_agent);
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        module_store.agent_data = AgentData { agent: new_agent, api_uri: new_api_uri };
    }

    public entry fun update_agent_by_chain(
        chain: &signer, new_agent: address, new_api_uri: string::String
    ) acquires ModuleStore {
        utils::check_chain_permission(chain);
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        module_store.agent_data = AgentData { agent: new_agent, api_uri: new_api_uri };
    }

    // add tvl snapshot of all bridges on this stage
    public entry fun add_tvl_snapshot() acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        add_tvl_snapshot_internal(module_store);
    }

    fun add_tvl_snapshot_internal(module_store: &ModuleStore) {
        let current_stage = module_store.stage;
        // check addable to reduce gas cost
        if (!tvl_manager::is_snapshot_addable(current_stage)) { return };
        let bridge_ids: vector<u64> = vector[];
        let tvls: vector<u64> = vector[];
        utils::walk(
            &module_store.bridges,
            option::some(
                BridgeInfoKey {
                    is_registered: true,
                    bridge_id: table_key::encode_u64(0),
                    version: table_key::encode_u64(0)
                }
            ),
            option::none(),
            1,
            |key, bridge| {
                let (_, bridge_id, _) = unpack_bridge_info_key(key);
                let bridge_tvl =
                    primary_fungible_store::balance(
                        bridge.bridge_addr, vault::reward_metadata()
                    );
                vector::push_back(&mut bridge_ids, bridge_id);
                vector::push_back(&mut tvls, bridge_tvl);

                false
            }
        );
        tvl_manager::add_snapshot(current_stage, bridge_ids, tvls);
    }

    // update reward record data of module store in reward module
    public entry fun fund_reward_script(agent: &signer) acquires ModuleStore {
        let (_, fund_time) = block::get_block_info();
        check_agent_permission(agent);
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        add_tvl_snapshot_internal(module_store);
        // update stage
        module_store.stage = module_store.stage + 1;
        add_tvl_snapshot_internal(module_store);
        let fund_stage = module_store.stage;
        let stage_end_time = module_store.stage_end_time;
        let stage_interval = module_store.stage_interval;
        assert!(
            stage_end_time <= fund_time,
            error::invalid_state(ETOO_EARLY_FUND)
        );

        // update stage start_time
        module_store.stage_start_time = stage_end_time;
        module_store.stage_end_time = stage_end_time + stage_interval;
        let initial_reward_amount = vault::reward_per_stage();
        let (
            total_operator_funded_reward,
            total_user_funded_reward,
            operator_funded_rewards,
            user_funded_rewards
        ) = fund_reward(
            module_store,
            fund_stage,
            initial_reward_amount
        );
        table::add(
            &mut module_store.stage_data,
            table_key::encode_u64(fund_stage),
            StageData {
                stage_start_time: module_store.stage_start_time,
                stage_end_time: module_store.stage_end_time,
                pool_split_ratio: module_store.pool_split_ratio,
                total_operator_funded_reward,
                operator_funded_rewards,
                total_user_funded_reward,
                user_funded_rewards,
                vesting_period: module_store.vesting_period,
                minimum_score_ratio: module_store.minimum_score_ratio,
                snapshots: table::new<SnapshotKey, Snapshot>()
            }
        );

        event::emit(
            StageAdvanceEvent {
                stage: fund_stage,
                stage_start_time: module_store.stage_start_time,
                stage_end_time: module_store.stage_end_time,
                pool_split_ratio: module_store.pool_split_ratio,
                total_operator_funded_reward,
                total_user_funded_reward,
                vesting_period: module_store.vesting_period,
                minimum_score_ratio: module_store.minimum_score_ratio
            }
        );
    }

    public entry fun submit_snapshot(
        agent: &signer,
        bridge_id: u64,
        version: u64,
        stage: u64,
        merkle_root: vector<u8>,
        total_l2_score: u64
    ) acquires ModuleStore {
        check_agent_permission(agent);
        let module_store = borrow_global_mut<ModuleStore>(@vip);

        // submitted snapshot under the current stage
        assert!(
            stage < module_store.stage,
            error::invalid_argument(EINVALID_STAGE_SNAPSHOT)
        );
        assert!(
            table::contains(
                &module_store.stage_data,
                table_key::encode_u64(stage)
            ),
            error::not_found(ESTAGE_DATA_NOT_FOUND)
        );
        // check previous stage snapshot for preventing skipping stage
        check_previous_stage_snapshot(module_store, bridge_id, version, stage);
        let stage_data = load_stage_data_mut(module_store, stage);
        let snapshot_key = SnapshotKey {
            bridge_id: table_key::encode_u64(bridge_id),
            version: table_key::encode_u64(version)
        };
        assert!(
            !table::contains(&stage_data.snapshots, snapshot_key),
            error::already_exists(ESNAPSHOT_ALREADY_EXISTS)
        );

        let (_, create_time) = block::get_block_info();

        table::add(
            &mut stage_data.snapshots,
            snapshot_key,
            Snapshot {
                create_time,
                upsert_time: create_time,
                merkle_root,
                total_l2_score
            }
        );

        event::emit(
            SubmitSnapshotEvent {
                bridge_id,
                version,
                stage,
                total_l2_score,
                merkle_root,
                create_time
            }
        )
    }

    fun is_after_challenge_period(
        module_store: &ModuleStore,
        bridge_id: u64,
        version: u64,
        stage: u64
    ): bool {
        let (_, curr_time) = block::get_block_info();
        let challenge_period = module_store.challenge_period;
        let snapshot = load_snapshot_imut(module_store, stage, bridge_id, version);
        let snapshot_create_time = snapshot.create_time;

        curr_time > snapshot_create_time + challenge_period
    }

    public entry fun batch_claim_user_reward_script(
        account: &signer,
        bridge_id: u64,
        version: u64,
        stages: vector<u64>, /*always consecutively and sort asc*/
        merkle_proofs: vector<vector<vector<u8>>>,
        l2_scores: vector<u64>
    ) acquires ModuleStore {
        let account_addr = signer::address_of(account);
        let len = vector::length(&stages);
        assert!(
            len != 0
                && len == vector::length(&merkle_proofs)
                && len == vector::length(&l2_scores),
            error::invalid_argument(EINVALID_BATCH_ARGUMENT)
        );

        let module_store = borrow_global_mut<ModuleStore>(@vip);
        let start_stage = *vector::borrow(&mut stages, 0);
        let end_stage = *vector::borrow(&mut stages, len - 1);
        check_user_reward_claimable(
            module_store,
            account,
            bridge_id,
            version,
            start_stage,
            end_stage
        );
        let vesting_period = module_store.vesting_period;
        let minimum_score_ratio = module_store.minimum_score_ratio;

        add_tvl_snapshot_internal(module_store);

        let prev_stage = start_stage - 1;
        // make vesting position claim info
        let claim_infos: vector<UserVestingClaimInfo> = vector[];
        vector::enumerate_ref(
            &stages,
            |i, stage| {
                // check stages consecutively
                assert!(
                    *stage == prev_stage + 1,
                    error::invalid_argument(EINVALID_STAGE_ORDER)
                );
                let merkle_proof = vector::borrow(&merkle_proofs, i);
                let l2_score = vector::borrow(&l2_scores, i);

                let snapshot = load_snapshot_imut(
                    module_store, *stage, bridge_id, version
                );
                // check merkle proof
                let target_hash =
                    score_hash(
                        bridge_id,
                        *stage,
                        account_addr,
                        *l2_score,
                        snapshot.total_l2_score
                    );
                if (*l2_score != 0) {
                    assert_merkle_proofs(
                        *merkle_proof,
                        snapshot.merkle_root,
                        target_hash
                    );
                };
                vector::push_back(
                    &mut claim_infos,
                    vesting::build_user_vesting_claim_info(
                        *stage,
                        *stage + vesting_period,
                        *l2_score,
                        minimum_score_ratio,
                        snapshot.total_l2_score,
                        get_user_funded_reward_internal(module_store, bridge_id, *stage)
                    )
                );
                prev_stage = *stage;

            }
        );
        // call batch claim user reward; return net reward(total vested reward)
        let net_reward =
            vesting::batch_claim_user_reward(
                account_addr, bridge_id, version, claim_infos
            );

        coin::deposit(account_addr, net_reward);
    }

    public entry fun batch_claim_operator_reward_script(
        operator: &signer, bridge_id: u64, version: u64
    ) acquires ModuleStore {
        operator::check_operator_permission(operator, bridge_id, version);

        if (!vesting::is_operator_vesting_store_registered(bridge_id, version)) {
            vesting::register_operator_vesting_store(bridge_id, version);
        };
        let account_addr = signer::address_of(operator);
        // check if the claim is attempted from a position that has not been finalized.
        let last_submitted_stage = get_last_submitted_stage(bridge_id, version);
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        add_tvl_snapshot_internal(module_store);

        let last_claimed_stage =
            vesting::get_operator_last_claimed_stage(bridge_id, version);
        if (last_claimed_stage == 0) {
            let (is_registered, last_version) =
                get_last_bridge_version(module_store, bridge_id);
            let is_bridge_registered = is_registered && last_version == version;
            let key = BridgeInfoKey {
                is_registered: is_bridge_registered,
                bridge_id: table_key::encode_u64(bridge_id),
                version: table_key::encode_u64(version)
            };
            let bridge_info = table::borrow(&module_store.bridges, key);
            let init_stage = bridge_info.init_stage;
            last_claimed_stage = init_stage - 1;
        };

        let claim_infos: vector<OperatorVestingClaimInfo> = vector[];
        let stage = last_claimed_stage + 1;
        while (stage <= last_submitted_stage) {
            let stage_key = table_key::encode_u64(stage);
            assert!(
                table::contains(&module_store.stage_data, stage_key),
                error::not_found(ESTAGE_DATA_NOT_FOUND)
            );
            let stage_data = table::borrow(&module_store.stage_data, stage_key);
            assert!(
                table::contains(
                    &stage_data.snapshots,
                    SnapshotKey {
                        bridge_id: table_key::encode_u64(bridge_id),
                        version: table_key::encode_u64(version)
                    }
                ),
                error::not_found(ESNAPSHOT_NOT_FOUND)
            );
            vector::push_back(
                &mut claim_infos,
                vesting::build_operator_vesting_claim_info(
                    stage,
                    stage + module_store.vesting_period,
                    get_operator_funded_reward_internal(module_store, bridge_id, stage)
                )
            );
            stage = stage + 1;
        };

        // call batch claim operator reward;
        let net_reward =
            vesting::batch_claim_operator_reward(
                account_addr,
                bridge_id,
                version,
                last_submitted_stage,
                claim_infos
            );
        coin::deposit(signer::address_of(operator), net_reward);
    }

    public entry fun update_vip_weights(
        chain: &signer, bridge_ids: vector<u64>, weights: vector<BigDecimal>
    ) acquires ModuleStore {
        utils::check_chain_permission(chain);
        update_vip_weights_for_friend(bridge_ids, weights)
    }

    public entry fun update_vip_weight(
        chain: &signer, bridge_id: u64, weight: BigDecimal
    ) acquires ModuleStore {
        utils::check_chain_permission(chain);
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        let (is_registered, version) = get_last_bridge_version(module_store, bridge_id);
        assert!(is_registered, error::unavailable(EBRIDGE_NOT_REGISTERED));
        let bridge = load_registered_bridge_mut(module_store, bridge_id, version);
        bridge.vip_weight = weight;
        validate_vip_weights(module_store);
    }

    public entry fun update_params(
        chain: &signer,
        stage_interval: Option<u64>,
        vesting_period: Option<u64>,
        minimum_lock_staking_period: Option<u64>,
        minimum_eligible_tvl: Option<u64>,
        _maximum_tvl_ratio: Option<BigDecimal>, // DEPRECATED
        maximum_weight_ratio: Option<BigDecimal>,
        minimum_score_ratio: Option<BigDecimal>,
        pool_split_ratio: Option<BigDecimal>,
        challenge_period: Option<u64>
    ) acquires ModuleStore {
        utils::check_chain_permission(chain);
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        if (option::is_some(&stage_interval)) {
            module_store.stage_interval = option::extract(&mut stage_interval);
            assert!(
                module_store.stage_interval > 0,
                error::invalid_argument(EINVALID_STAGE_INTERVAL)
            );
        };

        if (option::is_some(&vesting_period)) {
            module_store.vesting_period = option::extract(&mut vesting_period);
            assert!(
                module_store.vesting_period > 0,
                error::invalid_argument(EINVALID_VEST_PERIOD)
            );
        };

        if (option::is_some(&minimum_lock_staking_period)) {
            module_store.minimum_lock_staking_period = option::extract(
                &mut minimum_lock_staking_period
            );
            assert!(
                module_store.minimum_lock_staking_period > 0,
                error::invalid_argument(EINVALID_LOCK_STKAING_PERIOD)
            );
        };

        if (option::is_some(&minimum_eligible_tvl)) {
            module_store.minimum_eligible_tvl = option::extract(
                &mut minimum_eligible_tvl
            );
        };

        if (option::is_some(&maximum_weight_ratio)) {
            module_store.maximum_weight_ratio = option::extract(
                &mut maximum_weight_ratio
            );
            assert!(
                bigdecimal::le(module_store.maximum_weight_ratio, bigdecimal::one()),
                error::invalid_argument(EINVALID_RATIO)
            );
        };

        if (option::is_some(&minimum_score_ratio)) {
            module_store.minimum_score_ratio = option::extract(&mut minimum_score_ratio);
            assert!(
                bigdecimal::le(module_store.minimum_score_ratio, bigdecimal::one()),
                error::invalid_argument(EINVALID_RATIO)
            );
        };

        if (option::is_some(&pool_split_ratio)) {
            module_store.pool_split_ratio = option::extract(&mut pool_split_ratio);
            assert!(
                bigdecimal::le(module_store.pool_split_ratio, bigdecimal::one()),
                error::invalid_argument(EINVALID_RATIO)
            );
        };

        if (option::is_some(&challenge_period)) {
            module_store.challenge_period = option::extract(&mut challenge_period);
        }
    }

    public entry fun update_operator_commission(
        operator: &signer,
        bridge_id: u64,
        version: u64,
        commission_rate: BigDecimal
    ) acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        operator::update_operator_commission(
            operator,
            bridge_id,
            version,
            module_store.stage,
            commission_rate
        );
    }

    public entry fun update_l2_score_contract(
        chain: &signer, bridge_id: u64, new_vip_l2_score_contract: string::String
    ) acquires ModuleStore {
        utils::check_chain_permission(chain);
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        let (is_registered, version) = get_last_bridge_version(module_store, bridge_id);
        assert!(is_registered, error::unavailable(EBRIDGE_NOT_REGISTERED));
        let bridge = load_registered_bridge_mut(module_store, bridge_id, version);
        bridge.vip_l2_score_contract = new_vip_l2_score_contract;
    }

    public entry fun update_operator(
        operator: &signer, bridge_id: u64, new_operator_addr: address
    ) acquires ModuleStore {
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        let (is_registered, version) = get_last_bridge_version(module_store, bridge_id);
        assert!(is_registered, error::unavailable(EBRIDGE_NOT_REGISTERED));
        let bridge = load_registered_bridge_mut(module_store, bridge_id, version);
        assert!(
            bridge.operator_addr == signer::address_of(operator),
            error::permission_denied(EUNAUTHORIZED)
        );
        bridge.operator_addr = new_operator_addr;
        operator::update_operator_addr(
            operator,
            bridge_id,
            version,
            new_operator_addr
        );
    }

    public entry fun lock_stake_script(
        account: &signer,
        bridge_id: u64,
        version: u64,
        lp_metadata: Object<Metadata>,
        min_liquidity: option::Option<u64>,
        validator: string::String,
        stage: u64,
        esinit_amount: u64,
        stakelisted_metadata: Object<Metadata>,
        stakelisted_amount: u64,
        release_time: Option<u64>
    ) acquires ModuleStore {
        let account_addr = signer::address_of(account);
        check_lock_stakable(account_addr, bridge_id, version, stage);
        let esinit =
            vesting::withdraw_vesting(
                account_addr,
                bridge_id,
                version,
                stage,
                esinit_amount
            );

        lock_stake(
            account,
            lp_metadata,
            min_liquidity,
            validator,
            esinit,
            stakelisted_metadata,
            stakelisted_amount,
            release_time
        );
    }

    public entry fun batch_lock_stake_script(
        account: &signer,
        bridge_id: u64,
        version: u64,
        lp_metadata: Object<Metadata>,
        min_liquidity: option::Option<u64>,
        validator: string::String,
        stage: vector<u64>,
        esinit_amount: vector<u64>,
        stakelisted_metadata: Object<Metadata>,
        stakelisted_amount: u64,
        lock_stake_period: Option<u64>
    ) acquires ModuleStore {
        let esinit =
            withdraw_esinit_for_lock_stake(
                account,
                bridge_id,
                version,
                stage,
                esinit_amount
            );

        lock_stake(
            account,
            lp_metadata,
            min_liquidity,
            validator,
            esinit,
            stakelisted_metadata,
            stakelisted_amount,
            lock_stake_period
        );
    }

    public entry fun batch_stableswap_lock_stake_script(
        account: &signer,
        bridge_id: u64,
        version: u64,
        lp_metadata: Object<Metadata>,
        min_liquidity: option::Option<u64>,
        validator: string::String,
        stage: vector<u64>,
        esinit_amount: vector<u64>,
        lock_stake_period: Option<u64>
    ) acquires ModuleStore {
        let esinit =
            withdraw_esinit_for_lock_stake(
                account,
                bridge_id,
                version,
                stage,
                esinit_amount
            );

        stableswap_lock_stake(
            account,
            lp_metadata,
            min_liquidity,
            validator,
            esinit,
            lock_stake_period
        );
    }

    //
    // Helper Functions
    //
    fun get_last_bridge_version(
        module_store: &ModuleStore, bridge_id: u64
    ): (bool, u64) {
        // iter for registered bridge
        let iter =
            table::iter(
                &module_store.bridges,
                option::some(
                    BridgeInfoKey {
                        is_registered: true,
                        bridge_id: table_key::encode_u64(bridge_id),
                        version: table_key::encode_u64(0)
                    }
                ),
                option::none(),
                1
            );
        if (table::prepare<BridgeInfoKey, Bridge>(iter)) {
            let (key, _) = table::next<BridgeInfoKey, Bridge>(iter);
            let last_version = table_key::decode_u64(key.version);
            if (bridge_id == table_key::decode_u64(key.bridge_id)) {
                return (key.is_registered, last_version)
            };
        };

        // iter for deregistered bridge
        let iter =
            table::iter(
                &module_store.bridges,
                option::none(),
                option::some(
                    BridgeInfoKey {
                        is_registered: false,
                        bridge_id: table_key::encode_u64(bridge_id + 1),
                        version: table_key::encode_u64(0u64)
                    }
                ), // exclusive
                2
            );
        if (table::prepare<BridgeInfoKey, Bridge>(iter)) {
            let (key, _) = table::next<BridgeInfoKey, Bridge>(iter);
            let last_version = table_key::decode_u64(key.version);
            if (bridge_id == table_key::decode_u64(key.bridge_id)) {
                return (key.is_registered, last_version)
            };
        };

        (false, 0)
    }

    fun load_stage_data_mut(module_store: &mut ModuleStore, stage: u64): &mut StageData {
        let stage_key = table_key::encode_u64(stage);
        assert!(
            table::contains(&module_store.stage_data, stage_key),
            error::not_found(ESTAGE_DATA_NOT_FOUND)
        );
        table::borrow_mut(
            &mut module_store.stage_data,
            table_key::encode_u64(stage)
        )
    }

    fun load_stage_data_imut(module_store: &ModuleStore, stage: u64): &StageData {
        let stage_key = table_key::encode_u64(stage);
        assert!(
            table::contains(&module_store.stage_data, stage_key),
            error::not_found(ESTAGE_DATA_NOT_FOUND)
        );
        table::borrow(
            &module_store.stage_data,
            table_key::encode_u64(stage)
        )
    }

    fun load_snapshot_mut(
        module_store: &mut ModuleStore,
        stage: u64,
        bridge_id: u64,
        version: u64
    ): &mut Snapshot {
        let stage_key = table_key::encode_u64(stage);
        assert!(
            table::contains(&mut module_store.stage_data, stage_key),
            error::not_found(ESTAGE_DATA_NOT_FOUND)
        );
        let stage_data =
            table::borrow_mut(
                &mut module_store.stage_data,
                table_key::encode_u64(stage)
            );
        let key = SnapshotKey {
            bridge_id: table_key::encode_u64(bridge_id),
            version: table_key::encode_u64(version)
        };
        assert!(
            table::contains(&mut stage_data.snapshots, key),
            error::not_found(ESNAPSHOT_NOT_FOUND)
        );

        table::borrow_mut(&mut stage_data.snapshots, key)
    }

    fun load_snapshot_imut(
        module_store: &ModuleStore,
        stage: u64,
        bridge_id: u64,
        version: u64
    ): &Snapshot {
        let stage_key = table_key::encode_u64(stage);
        assert!(
            table::contains(&module_store.stage_data, stage_key),
            error::not_found(ESTAGE_DATA_NOT_FOUND)
        );
        let stage_data =
            table::borrow(
                &module_store.stage_data,
                table_key::encode_u64(stage)
            );
        let key = SnapshotKey {
            bridge_id: table_key::encode_u64(bridge_id),
            version: table_key::encode_u64(version)
        };
        assert!(
            table::contains(&stage_data.snapshots, key),
            error::not_found(ESNAPSHOT_NOT_FOUND)
        );

        table::borrow(&stage_data.snapshots, key)
    }

    fun load_registered_bridge_mut(
        module_store: &mut ModuleStore, bridge_id: u64, version: u64
    ): &mut Bridge {
        let key = BridgeInfoKey {
            is_registered: true,
            bridge_id: table_key::encode_u64(bridge_id),
            version: table_key::encode_u64(version)
        };
        assert!(
            table::contains(&module_store.bridges, key),
            error::not_found(EBRIDGE_NOT_FOUND)
        );
        table::borrow_mut(&mut module_store.bridges, key)
    }

    fun load_registered_bridge_imut(
        module_store: &ModuleStore, bridge_id: u64, version: u64
    ): &Bridge {
        let key = BridgeInfoKey {
            is_registered: true,
            bridge_id: table_key::encode_u64(bridge_id),
            version: table_key::encode_u64(version)
        };
        assert!(
            table::contains(&module_store.bridges, key),
            error::not_found(EBRIDGE_NOT_FOUND)
        );
        table::borrow(&module_store.bridges, key)
    }

    public fun get_last_submitted_stage(bridge_id: u64, version: u64): u64 acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        let iter = table::iter(
            &module_store.stage_data,
            option::none(),
            option::none(),
            2
        );

        loop {
            if (!table::prepare<vector<u8>, StageData>(iter)) { break };

            let (stage_vec, value) = table::next<vector<u8>, StageData>(iter);

            let _iter =
                table::iter(
                    &value.snapshots,
                    option::some(
                        SnapshotKey {
                            bridge_id: table_key::encode_u64(bridge_id),
                            version: table_key::encode_u64(version)
                        }
                    ),
                    option::some(
                        SnapshotKey {
                            bridge_id: table_key::encode_u64(bridge_id + 1),
                            version: table_key::encode_u64(0)
                        }
                    ),
                    2
                );
            loop {
                if (!table::prepare<SnapshotKey, Snapshot>(_iter)) { break };
                let (_key, _value) = table::next<SnapshotKey, Snapshot>(_iter);
                if (table_key::decode_u64(_key.bridge_id) == bridge_id
                    && table_key::decode_u64(_key.version) == version) {
                    return table_key::decode_u64(stage_vec)
                }
            };
        };

        0
    }

    public fun get_whitelisted_bridge_ids(): (vector<u64>, vector<u64>) acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        get_whitelisted_bridge_ids_internal(module_store)
    }

    public fun is_registered(bridge_id: u64): bool acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        let (is_registered, _) = get_last_bridge_version(module_store, bridge_id);
        is_registered
    }

    //
    // View Functions
    //
    #[view]
    public fun get_bridge_infos(): vector<BridgeResponse> acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        let bridge_infos = vector::empty<BridgeResponse>();
        utils::walk(
            &module_store.bridges,
            option::some(
                BridgeInfoKey {
                    is_registered: true,
                    bridge_id: table_key::encode_u64(0),
                    version: table_key::encode_u64(0)
                }
            ),
            option::none(),
            1,
            |key, bridge| {
                let (_, bridge_id, version) = unpack_bridge_info_key(key);
                vector::push_back(
                    &mut bridge_infos,
                    BridgeResponse {
                        init_stage: bridge.init_stage,
                        bridge_id,
                        version,
                        bridge_addr: bridge.bridge_addr,
                        operator_addr: bridge.operator_addr,
                        vip_l2_score_contract: bridge.vip_l2_score_contract,
                        vip_weight: bridge.vip_weight,
                        vm_type: bridge.vm_type
                    }
                );

                false
            }
        );
        bridge_infos
    }

    #[view]
    public fun get_total_l2_scores(stage: u64): vector<TotalL2ScoreResponse> acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        let stage_key = table_key::encode_u64(stage);
        let stage_data = table::borrow(&module_store.stage_data, stage_key);
        let total_l2_scores: vector<TotalL2ScoreResponse> = vector[];
        utils::walk(
            &stage_data.snapshots,
            option::none(),
            option::none(),
            1,
            |key, snapshot| {
                let (bridge_id, version) = unpack_snapshot_key(key);
                let (is_registered, _) = get_last_bridge_version(
                    module_store, bridge_id
                );
                if (is_registered) {
                    vector::push_back(
                        &mut total_l2_scores,
                        TotalL2ScoreResponse {
                            bridge_id,
                            version,
                            total_l2_score: snapshot.total_l2_score
                        }
                    );
                };
                false
            }
        );
        total_l2_scores
    }

    //
    // unpack
    //
    fun unpack_bridge_info_key(bridge_info_key: BridgeInfoKey): (bool, u64, u64) {
        (
            bridge_info_key.is_registered,
            table_key::decode_u64(bridge_info_key.bridge_id),
            table_key::decode_u64(bridge_info_key.version)
        )
    }

    fun unpack_snapshot_key(snapshot_key: SnapshotKey): (u64, u64) {
        (
            table_key::decode_u64(snapshot_key.bridge_id),
            table_key::decode_u64(snapshot_key.version)
        )
    }

    //
    // Test Functions
    //
    #[test_only]
    use initia_std::coin::{BurnCapability, FreezeCapability, MintCapability};

    #[test_only]
    use initia_std::staking;

    #[test_only]
    struct TestCapability has key {
        burn_cap: BurnCapability,
        freeze_cap: FreezeCapability,
        mint_cap: MintCapability
    }

    #[test_only]
    const DEFAULT_VIP_WEIGHT_RATIO_FOR_TEST: u64 = 10; // ratio with 10 as the

    #[test_only]
    const DEFAULT_MIN_SCORE_RATIO_FOR_TEST: u64 = 10; // ratio with 10 as the

    #[test_only]
    const DEFAULT_COMMISSION_MAX_RATE_FOR_TEST: u64 = 5; // ratio with 10 as the

    #[test_only]
    const DEFAULT_POOL_SPLIT_RATIO_FOR_TEST: u64 = 4; // ratio with 10 as the

    #[test_only]
    const DEFAULT_COMMISSION_MAX_CHANGE_RATE_FOR_TEST: u64 = 5; // ratio with 10 as the

    #[test_only]
    const DEFAULT_COMMISSION_RATE_FOR_TEST: u64 = 0; // ratio with 10 as the

    #[test_only]
    const DEFAULT_USER_VESTING_PERIOD_FOR_TEST: u64 = 52;

    #[test_only]
    const DEFAULT_OPERATOR_VESTING_PERIOD_FOR_TEST: u64 = 52;

    #[test_only]
    const DEFAULT_REWARD_PER_STAGE_FOR_TEST: u64 = 100_000_000_000;

    #[test_only]
    const DEFAULT_SKIPPED_CHALLENGE_PERIOD_FOR_TEST: u64 = 604801;

    #[test_only]
    const DEFAULT_NEW_CHALLENGE_PERIOD: u64 = 604800;
    #[test_only]
    const DEFAULT_API_URI_FOR_TEST: vector<u8> = b"test";

    #[test_only]
    const NEW_API_URI_FOR_TEST: vector<u8> = b"new";

    #[test_only]
    const BRIDGE_ID_FOR_TEST: u64 = 1;

    #[test_only]
    const STAGE_FOR_TEST: u64 = 1;

    #[test_only]
    const DEFAULT_VIP_L2_CONTRACT_FOR_TEST: vector<u8> = (b"vip_l2_contract");

    #[test_only]
    const CHALLENGE_ID_FOR_TEST: u64 = 1;

    #[test_only]
    const NEW_L2_TOTAL_SCORE_FOR_TEST: u64 = 1000;

    #[test_only]
    public fun get_bridge_info(bridge_id: u64): BridgeResponse acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        let (is_registered, version) = get_last_bridge_version(module_store, bridge_id);
        assert!(is_registered, error::unavailable(EBRIDGE_NOT_REGISTERED));
        let bridge = load_registered_bridge_imut(module_store, bridge_id, version);
        BridgeResponse {
            init_stage: bridge.init_stage,
            bridge_id,
            version,
            bridge_addr: bridge.bridge_addr,
            operator_addr: bridge.operator_addr,
            vip_l2_score_contract: bridge.vip_l2_score_contract,
            vip_weight: bridge.vip_weight,
            vm_type: bridge.vm_type
        }
    }

    #[test_only]
    public fun unpack_module_store():
        (
        u64, // stage
        u64, // stage_interval
        u64, // vesting_period
        u64, // challenge_period
        BigDecimal, // minimum_score_ratio
        BigDecimal, // pool_split_ratio
        BigDecimal, // maximum_tvl_ratio
        u64, //minimum_eligible_tvl
        BigDecimal //maximum_weight_ratio
    ) acquires ModuleStore {
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        (
            module_store.stage,
            module_store.stage_interval,
            module_store.vesting_period,
            module_store.challenge_period,
            module_store.minimum_score_ratio,
            module_store.pool_split_ratio,
            module_store.maximum_tvl_ratio,
            module_store.minimum_eligible_tvl,
            module_store.maximum_weight_ratio
        )
    }

    #[test_only]
    public fun get_bridge_init_stage(bridge_id: u64): u64 acquires ModuleStore {
        get_bridge_info(bridge_id).init_stage
    }

    #[test_only]
    public fun get_user_funded_reward(bridge_id: u64, stage: u64): u64 acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        get_user_funded_reward_internal(module_store, bridge_id, stage)
    }

    #[test_only]
    public fun get_operator_funded_reward(bridge_id: u64, stage: u64): u64 acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        get_operator_funded_reward_internal(module_store, bridge_id, stage)
    }

    #[test_only]
    fun skip_period(period: u64) {
        let (height, curr_time) = block::get_block_info();
        block::set_block_info(height + period / 2, curr_time + period);
    }

    #[test_only]
    public fun init_module_for_test(vip: &signer) {
        vault::init_module_for_test(vip);
        operator::init_module_for_test(vip);
        vault::update_reward_per_stage(vip, DEFAULT_REWARD_PER_STAGE_FOR_TEST);
        skip_period(10);
        let (_, block_time) = block::get_block_info();
        initialize(
            vip,
            block_time + 100,
            signer::address_of(vip),
            string::utf8(DEFAULT_API_URI_FOR_TEST)
        );
        skip_period(100);
    }

    #[test_only]
    fun initialize_coin(
        account: &signer, symbol: string::String
    ): (
        coin::BurnCapability,
        coin::FreezeCapability,
        coin::MintCapability,
        Object<Metadata>
    ) {
        let (mint_cap, burn_cap, freeze_cap) =
            coin::initialize(
                account,
                option::none(),
                string::utf8(b""),
                symbol,
                6,
                string::utf8(b""),
                string::utf8(b"")
            );
        let metadata = coin::metadata(signer::address_of(account), symbol);

        (burn_cap, freeze_cap, mint_cap, metadata)
    }

    #[test_only]
    fun test_register_bridge(
        chain: &signer,
        operator: &signer,
        bridge_id: u64,
        bridge_address: address,
        vip_l2_score_contract: string::String,
        mint_amount: u64,
        commission_max_rate: BigDecimal,
        commission_max_change_rate: BigDecimal,
        commission_rate: BigDecimal,
        mint_cap: &coin::MintCapability
    ): u64 acquires ModuleStore {
        coin::mint_to(
            mint_cap,
            signer::address_of(chain),
            mint_amount
        );
        coin::mint_to(
            mint_cap,
            signer::address_of(operator),
            mint_amount
        );
        coin::mint_to(mint_cap, bridge_address, mint_amount);
        vault::deposit(chain, mint_amount);

        register(
            chain,
            signer::address_of(operator),
            bridge_id,
            bridge_address,
            vip_l2_score_contract,
            commission_max_rate,
            commission_max_change_rate,
            commission_rate,
            MOVEVM
        );

        bridge_id
    }

    #[test_only]
    public fun test_setup(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        bridge_id: u64,
        bridge_address: address,
        vip_l2_score_contract: string::String,
        mint_amount: u64
    ): u64 acquires ModuleStore {
        primary_fungible_store::init_module_for_test();
        tvl_manager::init_module_for_test(vip);
        vesting::init_module_for_test(vip);
        let (burn_cap, freeze_cap, mint_cap, _) =
            initialize_coin(chain, string::utf8(b"uinit"));
        init_module_for_test(vip);
        test_register_bridge(
            vip,
            operator,
            bridge_id,
            bridge_address,
            vip_l2_score_contract,
            mint_amount,
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_CHANGE_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_RATE_FOR_TEST, 10),
            &mint_cap
        );

        update_minimum_score_ratio(
            vip,
            bigdecimal::from_ratio_u64(DEFAULT_MIN_SCORE_RATIO_FOR_TEST, 10)
        );

        update_vip_weight(
            vip,
            bridge_id,
            bigdecimal::from_ratio_u64(DEFAULT_VIP_WEIGHT_RATIO_FOR_TEST, 10)
        );

        move_to(
            chain,
            TestCapability { burn_cap, freeze_cap, mint_cap }
        );

        bridge_id
    }

    #[test_only]
    public fun merkle_root_and_proof_scene1():
        (
        SimpleMap<u64, vector<u8>>,
        SimpleMap<u64, vector<vector<u8>>>,
        SimpleMap<u64, u64>,
        SimpleMap<u64, u64>
    ) {
        let root_map = simple_map::new<u64, vector<u8>>();
        let proofs_map = simple_map::new<u64, vector<vector<u8>>>();
        let score_map = simple_map::new<u64, u64>();
        let total_score_map = simple_map::new<u64, u64>();

        simple_map::add(
            &mut root_map,
            1,
            x"fb9eab6b9b5f195d0927c8a7301682b1475425249bb6b8bb31afd0dbb2dd4d09"
        );
        simple_map::add(
            &mut root_map,
            2,
            x"0ac37a58eb526e4577e78f59c46e70b3d0fd54b78c06905345bd7e14e75da42b"
        );
        simple_map::add(
            &mut root_map,
            3,
            x"42c600b41e6ff29ee44e1d61d460f6c78db862c0f3abe42d14df858649a1eea9"
        );
        simple_map::add(
            &mut root_map,
            4,
            x"dda4a2cd3385326bb304d1a6a62c35d39bb28d5acef58b5552e73b3c968e0c79"
        );
        simple_map::add(
            &mut root_map,
            5,
            x"469bdc31f3b0fbc1fb1f2ab9337af4ecf1643d6173cdecee95b235c9ca232017"
        );
        simple_map::add(
            &mut root_map,
            6,
            x"d2197ca826f0ee6084555f86fdd185a16788d68d8c512b025cb5829770682bd7"
        );
        simple_map::add(
            &mut root_map,
            7,
            x"998d5df26676a108e6581d1bc6dab1c7fab86fbdbcc5f1b8e4847ebe74f29341"
        );
        simple_map::add(
            &mut root_map,
            8,
            x"c41ff3aa918e489fc64a62d07915dab0c04b205e05dc6c9e4a8b7997091fdbdc"
        );
        simple_map::add(
            &mut root_map,
            9,
            x"c363c5b4393942032b841d5d0f68213d475e285b2fd7e31a4128c97b91cef97a"
        );
        simple_map::add(
            &mut root_map,
            10,
            x"2c4cc1daece91ee14d55d35595d17b8cc0bd6741b967ff82f73f6330c8b25b8a"
        );

        simple_map::add(
            &mut proofs_map,
            1,
            vector[
                x"0bb9c560686ab3b4e1ac1a41bbc74ccd4d348634985a1a312590346900a6c93e"
            ]
        );
        simple_map::add(
            &mut proofs_map,
            2,
            vector[
                x"66ffc3bb14e3bc65e022401feed6e2644082ccf69ccb40d1842fc6ca2d4c24fd"
            ]
        );
        simple_map::add(
            &mut proofs_map,
            3,
            vector[
                x"70ed0c868798b88361b42895df358f64c4b4dd074f0af7146ef8898a675fee4e"
            ]
        );
        simple_map::add(
            &mut proofs_map,
            4,
            vector[
                x"3e304abd07a33f4fab39537a4ac75c8886a89be9d8aaa96035675775a784b23e"
            ]
        );
        simple_map::add(
            &mut proofs_map,
            5,
            vector[
                x"2911095fa7f35a563471cfff4135031f5d648372cc384b6288a19d8216baa3fa"
            ]
        );
        simple_map::add(
            &mut proofs_map,
            6,
            vector[
                x"25a20d529493d2aef8beef43221b00231a0e8d07990e3d43b93fbf9cfd54de73"
            ]
        );
        simple_map::add(
            &mut proofs_map,
            7,
            vector[
                x"61a55e6aac46c32a47c96b0dc4fd5de1f705e7400460957acb10457904a4a990"
            ]
        );
        simple_map::add(
            &mut proofs_map,
            8,
            vector[
                x"96187ed75a9b83537e045912573bf3efee0a6369a663f1cb4d4ec7798c9f6299"
            ]
        );
        simple_map::add(
            &mut proofs_map,
            9,
            vector[
                x"759ac8ad2821f2dbeb253e0872c07ffc6ccd3f69b80d19b04f0e49d6a0ea8da7"
            ]
        );
        simple_map::add(
            &mut proofs_map,
            10,
            vector[
                x"98b1fed6531d027c0efb53d54941c83f8ceb9694b9ec199ee07278200c943eb1"
            ]
        );

        simple_map::add(&mut score_map, 1, 800_000);
        simple_map::add(&mut score_map, 2, 800_000);
        simple_map::add(&mut score_map, 3, 400_000);
        simple_map::add(&mut score_map, 4, 400_000);
        simple_map::add(&mut score_map, 5, 800_000);
        simple_map::add(&mut score_map, 6, 800_000);
        simple_map::add(&mut score_map, 7, 800_000);
        simple_map::add(&mut score_map, 8, 800_000);
        simple_map::add(&mut score_map, 9, 800_000);
        simple_map::add(&mut score_map, 10, 800_000);

        simple_map::add(&mut total_score_map, 1, 8_000_000);
        simple_map::add(&mut total_score_map, 2, 8_000_000);
        simple_map::add(&mut total_score_map, 3, 4_000_000);
        simple_map::add(&mut total_score_map, 4, 4_000_000);
        simple_map::add(&mut total_score_map, 5, 8_000_000);
        simple_map::add(&mut total_score_map, 6, 8_000_000);
        simple_map::add(&mut total_score_map, 7, 8_000_000);
        simple_map::add(&mut total_score_map, 8, 8_000_000);
        simple_map::add(&mut total_score_map, 9, 8_000_000);
        simple_map::add(&mut total_score_map, 10, 8_000_000);

        (root_map, proofs_map, score_map, total_score_map)
    }

    #[test_only]
    fun update_minimum_score_ratio(chain: &signer, ratio: BigDecimal) acquires ModuleStore {
        update_params(
            chain,
            option::none(), //stage_interval: Option<u64>,
            option::none(), //vesting_period: Option<u64>,
            option::none(), //minimum_lock_staking_period: Option<u64>,
            option::none(), //minimum_eligible_tvl: Option<u64>,
            option::none(), //maximum_tvl_ratio: Option<BigDecimal>,
            option::none(), //maximum_weight_ratio: Option<BigDecimal>,
            option::some(ratio), //minimum_score_ratio: Option<BigDecimal>,
            option::none(), //pool_split_ratio: Option<BigDecimal>,
            option::none() //challenge_period: Option<u64>,
        )
    }

    #[test_only]
    fun update_vesting_period(chain: &signer, period: u64) acquires ModuleStore {
        update_params(
            chain,
            option::none(), //stage_interval: Option<u64>,
            option::some(period), //vesting_period: Option<u64>,
            option::none(), //minimum_lock_staking_period: Option<u64>,
            option::none(), //minimum_eligible_tvl: Option<u64>,
            option::none(), //maximum_tvl_ratio: Option<BigDecimal>,
            option::none(), //maximum_weight_ratio: Option<BigDecimal>,
            option::none(), //minimum_score_ratio: Option<BigDecimal>,
            option::none(), //pool_split_ratio: Option<BigDecimal>,
            option::none() //challenge_period: Option<u64>,
        )
    }

    #[test_only]
    fun update_minimum_eligible_tvl(chain: &signer, tvl: u64) acquires ModuleStore {
        update_params(
            chain,
            option::none(), //stage_interval: Option<u64>,
            option::none(), //vesting_period: Option<u64>,
            option::none(), //minimum_lock_staking_period: Option<u64>,
            option::some(tvl), //minimum_eligible_tvl: Option<u64>,
            option::none(), //maximum_tvl_ratio: Option<BigDecimal>,
            option::none(), //maximum_weight_ratio: Option<BigDecimal>,
            option::none(), //minimum_score_ratio: Option<BigDecimal>,
            option::none(), //pool_split_ratio: Option<BigDecimal>,
            option::none() //challenge_period: Option<u64>,
        )
    }

    #[test_only]
    fun update_pool_split_ratio(chain: &signer, ratio: BigDecimal) acquires ModuleStore {
        update_params(
            chain,
            option::none(), //stage_interval: Option<u64>,
            option::none(), //vesting_period: Option<u64>,
            option::none(), //minimum_lock_staking_period: Option<u64>,
            option::none(), //minimum_eligible_tvl: Option<u64>,
            option::none(), //maximum_tvl_ratio: Option<BigDecimal>,
            option::none(), //maximum_weight_ratio: Option<BigDecimal>,
            option::none(), //minimum_score_ratio: Option<BigDecimal>,
            option::some(ratio), //pool_split_ratio: Option<BigDecimal>,
            option::none() //challenge_period: Option<u64>,
        )
    }

    #[test_only]
    fun update_challenge_period(chain: &signer, period: u64) acquires ModuleStore {
        update_params(
            chain,
            option::none(), //stage_interval: Option<u64>,
            option::none(), //vesting_period: Option<u64>,
            option::none(), //minimum_lock_staking_period: Option<u64>,
            option::none(), //minimum_eligible_tvl: Option<u64>,
            option::none(), //maximum_tvl_ratio: Option<BigDecimal>,
            option::none(), //maximum_weight_ratio: Option<BigDecimal>,
            option::none(), //minimum_score_ratio: Option<BigDecimal>,
            option::none(), //pool_split_ratio: Option<BigDecimal>,
            option::some(period) //challenge_period: Option<u64>,
        )
    }

    #[test_only]
    fun update_minimun_lock_staking_period(chain: &signer, period: u64) acquires ModuleStore {
        update_params(
            chain,
            option::none(), //stage_interval: Option<u64>,
            option::none(), //vesting_period: Option<u64>,
            option::some(period), //minimum_lock_staking_period: Option<u64>,
            option::none(), //minimum_eligible_tvl: Option<u64>,
            option::none(), //maximum_tvl_ratio: Option<BigDecimal>,
            option::none(), //maximum_weight_ratio: Option<BigDecimal>,
            option::none(), //minimum_score_ratio: Option<BigDecimal>,
            option::none(), //pool_split_ratio: Option<BigDecimal>,
            option::none() //challenge_period: Option<u64>,
        )
    }

    #[test_only]
    public fun get_expected_reward(
        bridge_id: u64, fund_reward_amount: u64
    ): u64 acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        let shares = calculate_share(module_store);
        assert!(
            fund_reward_amount > 0,
            error::invalid_argument(EINVALID_TOTAL_REWARD)
        );

        let reward_amount =
            split_reward_with_share_internal(&shares, bridge_id, fund_reward_amount);
        reward_amount
    }

    #[test_only]
    public fun merkle_root_and_proof_scene2():
        (
        SimpleMap<u64, vector<u8>>,
        SimpleMap<u64, vector<vector<u8>>>,
        SimpleMap<u64, u64>,
        SimpleMap<u64, u64>
    ) {
        let root_map = simple_map::new<u64, vector<u8>>();
        let proofs_map = simple_map::new<u64, vector<vector<u8>>>();
        let total_score_map = simple_map::new<u64, u64>();

        simple_map::add(
            &mut root_map,
            1,
            x"da8a26abe037981b46c77de776621601ea78ae2e9e4d095f4f6887d7b8fb4229"
        );
        simple_map::add(
            &mut root_map,
            2,
            x"edbea69a471f721622e7c64d086b901a52b6edb058b97c8a776cd7f3180e1659"
        );
        simple_map::add(
            &mut root_map,
            3,
            x"ecd24a0e9fe1ec83999cbdc0641f15cda95d40589073a6e8cc3234fde9357e65"
        );
        simple_map::add(
            &mut root_map,
            4,
            x"5725135c9c856f4241a05027c815a64fe687525f496dcdc6c57f23a87d5e4ac1"
        );
        simple_map::add(
            &mut root_map,
            5,
            x"183e88a1ca56d8a51d9390d8460621fe651997d63bf26392912e29e7323b08b0"
        );
        simple_map::add(
            &mut root_map,
            6,
            x"9de1fd227b37e6ad88c1eae0f4fd97f8436900befa9c80f4f66735e9e8646f54"
        );

        simple_map::add(&mut proofs_map, 1, vector[]);
        simple_map::add(&mut proofs_map, 2, vector[]);
        simple_map::add(&mut proofs_map, 3, vector[]);
        simple_map::add(&mut proofs_map, 4, vector[]);
        simple_map::add(&mut proofs_map, 5, vector[]);
        simple_map::add(&mut proofs_map, 6, vector[]);

        simple_map::add(&mut total_score_map, 1, 1_000);
        simple_map::add(&mut total_score_map, 2, 1_000);
        simple_map::add(&mut total_score_map, 3, 500);
        simple_map::add(&mut total_score_map, 4, 500);
        simple_map::add(&mut total_score_map, 5, 100);
        simple_map::add(&mut total_score_map, 6, 100);

        (root_map, proofs_map, total_score_map, total_score_map)
    }

    #[test_only]
    public fun test_setup_scene1(agent: &signer, bridge_id: u64) acquires ModuleStore {
        let idx = 1;
        let (merkle_root_map, _, _, total_score_map) = merkle_root_and_proof_scene1();

        // fund reward stage 1 ~ 10
        while (idx <= simple_map::length(&merkle_root_map)) {
            fund_reward_script(agent);
            skip_period(DEFAULT_STAGE_INTERVAL);
            idx = idx + 1;
        };
        // stage 11
        fund_reward_script(agent);
        skip_period(DEFAULT_STAGE_INTERVAL);
        idx = 1;
        // submit snapshot stage 1 ~ 10
        while (idx <= simple_map::length(&merkle_root_map)) {
            let total_l2_score = *simple_map::borrow(&total_score_map, &(idx));
            let merkle_root = *simple_map::borrow(&merkle_root_map, &(idx));
            submit_snapshot(
                agent,
                bridge_id,
                1,
                idx,
                merkle_root,
                total_l2_score
            );
            idx = idx + 1;

        }
    }

    #[test_only]
    public fun test_setup_scene2(agent: &signer, bridge_id: u64) acquires ModuleStore {
        let idx = 1;
        let (merkle_root_map, _, _, total_score_map) = merkle_root_and_proof_scene2();

        // fund reward stage 1 ~ 10
        while (idx <= simple_map::length(&merkle_root_map)) {
            fund_reward_script(agent);
            skip_period(DEFAULT_STAGE_INTERVAL);
            idx = idx + 1;
        };
        // stage 11
        fund_reward_script(agent);
        skip_period(DEFAULT_STAGE_INTERVAL);
        idx = 1;
        // submit snapshot stage 1 ~ 10
        while (idx <= simple_map::length(&merkle_root_map)) {
            let total_l2_score = *simple_map::borrow(&total_score_map, &(idx));
            let merkle_root = *simple_map::borrow(&merkle_root_map, &(idx));
            submit_snapshot(
                agent,
                bridge_id,
                1,
                idx,
                merkle_root,
                total_l2_score
            );
            idx = idx + 1;

        }
    }

    #[test(
        chain = @0x1, vip = @vip, operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573
    )]
    fun test_update_vip_weight(
        chain: &signer, vip: &signer, operator: &signer
    ) acquires ModuleStore {
        let mint_amount = 1_000_000_000;
        primary_fungible_store::init_module_for_test();
        vesting::init_module_for_test(vip);
        let (_, _, mint_cap, _) = initialize_coin(chain, string::utf8(b"uinit"));
        init_module_for_test(vip);

        coin::mint_to(
            &mint_cap,
            signer::address_of(chain),
            mint_amount
        );

        // initialize vip_reward
        register(
            vip,
            signer::address_of(operator),
            1,
            @0x90,
            string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_CHANGE_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_RATE_FOR_TEST, 10),
            MOVEVM
        );

        let new_weight = bigdecimal::from_ratio_u64(7, 10);
        update_vip_weight(vip, 1, new_weight);

        let bridge_info = get_bridge_info(1);
        assert!(
            bigdecimal::eq(bridge_info.vip_weight, new_weight),
            3
        );
    }

    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun test_update_minimum_score_ratio(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires ModuleStore {
        let bridge_id =
            test_setup(
                chain,
                vip,
                operator,
                BRIDGE_ID_FOR_TEST,
                @0x99,
                string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
                1_000_000_000_000
            );

        let (merkle_root_map, merkle_proof_map, score_map, total_score_map) =
            merkle_root_and_proof_scene1();
        // stage 1
        fund_reward_script(vip);
        skip_period(DEFAULT_STAGE_INTERVAL);
        // stage 2
        fund_reward_script(vip);
        submit_snapshot(
            vip,
            bridge_id,
            1,
            1,
            *simple_map::borrow(&merkle_root_map, &1),
            *simple_map::borrow(&total_score_map, &1)
        );
        skip_period(DEFAULT_STAGE_INTERVAL);
        // stage 3
        fund_reward_script(vip);
        submit_snapshot(
            vip,
            bridge_id,
            1,
            2,
            *simple_map::borrow(&merkle_root_map, &2),
            *simple_map::borrow(&total_score_map, &2)
        );

        skip_period(DEFAULT_SKIPPED_CHALLENGE_PERIOD_FOR_TEST);
        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[1, 2],
            vector[
                *simple_map::borrow(&merkle_proof_map, &1),
                *simple_map::borrow(&merkle_proof_map, &2)
            ],
            vector[
                *simple_map::borrow(&score_map, &1),
                *simple_map::borrow(&score_map, &2)
            ]
        );

        // minimum score ratio : 1.0
        assert!(
            vesting::get_user_vesting_minimum_score(
                signer::address_of(receiver), bridge_id, 1, 1
            ) == *simple_map::borrow(&score_map, &1),
            1
        );
        assert!(
            vesting::get_user_vesting_minimum_score(
                signer::address_of(receiver), bridge_id, 1, 2
            ) == *simple_map::borrow(&score_map, &2),
            2
        );
        // stage 4
        skip_period(DEFAULT_STAGE_INTERVAL);
        fund_reward_script(vip);
        submit_snapshot(
            vip,
            bridge_id,
            1,
            3,
            *simple_map::borrow(&merkle_root_map, &3),
            *simple_map::borrow(&total_score_map, &3)
        );
        skip_period(DEFAULT_STAGE_INTERVAL);
        fund_reward_script(vip);
        skip_period(DEFAULT_SKIPPED_CHALLENGE_PERIOD_FOR_TEST);
        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[3],
            vector[*simple_map::borrow(&merkle_proof_map, &3)],
            vector[*simple_map::borrow(&score_map, &3)]
        );

        assert!(
            vesting::get_user_vesting_minimum_score(
                signer::address_of(receiver), bridge_id, 1, 3
            ) == *simple_map::borrow(&score_map, &3),
            3
        );
        // minimum score ratio : 0.5
        update_minimum_score_ratio(vip, bigdecimal::from_ratio_u64(5, 10));

        skip_period(DEFAULT_STAGE_INTERVAL);
        fund_reward_script(vip);
        submit_snapshot(
            vip,
            bridge_id,
            1,
            4,
            *simple_map::borrow(&merkle_root_map, &4),
            *simple_map::borrow(&total_score_map, &4)
        );

        skip_period(DEFAULT_SKIPPED_CHALLENGE_PERIOD_FOR_TEST);

        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[4],
            vector[*simple_map::borrow(&merkle_proof_map, &4)],
            vector[*simple_map::borrow(&score_map, &4)]
        );

        assert!(
            vesting::get_user_vesting_minimum_score(
                signer::address_of(receiver), bridge_id, 1, 4
            ) == *simple_map::borrow(&score_map, &4) / 2,
            4
        );
    }

    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun test_update_l2_score_contract(
        chain: &signer, vip: &signer, operator: &signer
    ) acquires ModuleStore {
        let bridge_id =
            test_setup(
                chain,
                vip,
                operator,
                BRIDGE_ID_FOR_TEST,
                @0x99,
                string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
                1_000_000_000_000
            );

        let new_vip_l2_score_contract = string::utf8(b"new_vip_l2_score_contract");
        update_l2_score_contract(vip, bridge_id, new_vip_l2_score_contract);

        let bridge_info = get_bridge_info(bridge_id);
        assert!(
            bridge_info.vip_l2_score_contract == new_vip_l2_score_contract,
            0
        );
    }

    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun test_get_last_claimed_stages(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires ModuleStore {
        let bridge_id =
            test_setup(
                chain,
                vip,
                operator,
                BRIDGE_ID_FOR_TEST,
                @0x99,
                string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
                1_000_000_000_000
            );

        let (_, merkle_proof_map, score_map, _) = merkle_root_and_proof_scene1();
        test_setup_scene1(vip, bridge_id);

        skip_period(DEFAULT_SKIPPED_CHALLENGE_PERIOD_FOR_TEST);

        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[1],
            vector[*simple_map::borrow(&merkle_proof_map, &1)],
            vector[*simple_map::borrow(&score_map, &1)]
        );
        assert!(
            vesting::get_user_last_claimed_stage(
                signer::address_of(receiver), bridge_id, 1
            ) == 1,
            1
        );

        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[2],
            vector[*simple_map::borrow(&merkle_proof_map, &2)],
            vector[*simple_map::borrow(&score_map, &2)]
        );
        assert!(
            vesting::get_user_last_claimed_stage(
                signer::address_of(receiver), bridge_id, 1
            ) == 2,
            2
        );

        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[3],
            vector[*simple_map::borrow(&merkle_proof_map, &3)],
            vector[*simple_map::borrow(&score_map, &3)]
        );
        assert!(
            vesting::get_user_last_claimed_stage(
                signer::address_of(receiver), bridge_id, 1
            ) == 3,
            3
        );

        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[4],
            vector[*simple_map::borrow(&merkle_proof_map, &4)],
            vector[*simple_map::borrow(&score_map, &4)]
        );
        assert!(
            vesting::get_user_last_claimed_stage(
                signer::address_of(receiver), bridge_id, 1
            ) == 4,
            4
        );
    }

    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun test_update_vesting_period(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires ModuleStore {
        let bridge_id =
            test_setup(
                chain,
                vip,
                operator,
                BRIDGE_ID_FOR_TEST,
                @0x99,
                string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
                1_000_000_000_000
            );

        let total_reward_per_stage = 100_000_000_000;
        assert!(
            vault::reward_per_stage() == total_reward_per_stage,
            0
        );
        let portion = 10;
        let reward_per_stage = total_reward_per_stage / portion;
        let vesting_period = 10;
        update_vesting_period(vip, vesting_period);

        let (_, merkle_proof_map, score_map, _) = merkle_root_and_proof_scene1();
        test_setup_scene1(vip, bridge_id);

        skip_period(DEFAULT_SKIPPED_CHALLENGE_PERIOD_FOR_TEST);

        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[1, 2, 3, 4],
            vector[
                *simple_map::borrow(&merkle_proof_map, &1),
                *simple_map::borrow(&merkle_proof_map, &2),
                *simple_map::borrow(&merkle_proof_map, &3),
                *simple_map::borrow(&merkle_proof_map, &4)
            ],
            vector[
                *simple_map::borrow(&score_map, &1),
                *simple_map::borrow(&score_map, &2),
                *simple_map::borrow(&score_map, &3),
                *simple_map::borrow(&score_map, &4)
            ]
        );

        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[5],
            vector[*simple_map::borrow(&merkle_proof_map, &5)],
            vector[*simple_map::borrow(&score_map, &5)]
        );

        let module_store = borrow_global<ModuleStore>(@vip);
        let stage_data = load_stage_data_imut(module_store, 1);
        assert!(stage_data.vesting_period == vesting_period, 1);

        let expected_reward =
            (
                reward_per_stage / vesting_period
                    + reward_per_stage / (vesting_period * 2)
                    + reward_per_stage / (vesting_period * 2)
                    + reward_per_stage / vesting_period // stage 1
                    + reward_per_stage / (vesting_period * 2)
                    + reward_per_stage / (vesting_period * 2)
                    + reward_per_stage / vesting_period // stage 2
                    + reward_per_stage / vesting_period
                    + reward_per_stage / vesting_period // stage 3
                    + reward_per_stage / vesting_period // stage 4
            );

        assert!(
            coin::balance(
                signer::address_of(receiver),
                vault::reward_metadata()
            ) == expected_reward,
            2
        );
    }

    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun test_finalized_vesting(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires ModuleStore {
        let bridge_id =
            test_setup(
                chain,
                vip,
                operator,
                BRIDGE_ID_FOR_TEST,
                @0x99,
                string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
                1_000_000_000_000
            );

        let vesting_period = 2;
        update_vesting_period(vip, vesting_period);

        let (_, merkle_proof_map, score_map, _) = merkle_root_and_proof_scene1();
        test_setup_scene1(vip, bridge_id);

        skip_period(DEFAULT_SKIPPED_CHALLENGE_PERIOD_FOR_TEST);

        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[1],
            vector[*simple_map::borrow(&merkle_proof_map, &1)],
            vector[*simple_map::borrow(&score_map, &1)] // vesting 1 created
        );
        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[2],
            vector[*simple_map::borrow(&merkle_proof_map, &2)],
            vector[*simple_map::borrow(&score_map, &2)] // vesting 2 created
        );

        vesting::get_user_vesting(signer::address_of(receiver), bridge_id, 1, 1);
        vesting::get_user_vesting(signer::address_of(receiver), bridge_id, 1, 2);

        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[3],
            vector[*simple_map::borrow(&merkle_proof_map, &3)],
            vector[*simple_map::borrow(&score_map, &3)]
        );
        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[4],
            vector[*simple_map::borrow(&merkle_proof_map, &4)],
            vector[*simple_map::borrow(&score_map, &4)] // vesting 1 finalized
        );
        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[5],
            vector[*simple_map::borrow(&merkle_proof_map, &5)],
            vector[*simple_map::borrow(&score_map, &5)] // vesting 2 finalized
        );

        assert!(
            !vesting::has_user_vesting_position(
                signer::address_of(receiver), bridge_id, 1, 1
            ),
            0
        );
        assert!(
            !vesting::has_user_vesting_position(
                signer::address_of(receiver), bridge_id, 1, 1
            ),
            1
        );
    }

    #[test(
        chain = @0x1, vip = @vip, operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573
    )]
    fun test_update_minimum_eligible_tvl(
        chain: &signer, vip: &signer, operator: &signer
    ) acquires ModuleStore {
        test_setup(
            chain,
            vip,
            operator,
            BRIDGE_ID_FOR_TEST,
            @0x99,
            string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
            1_000_000_000_000
        );

        let module_store = borrow_global<ModuleStore>(@vip);
        assert!(module_store.minimum_eligible_tvl == 0, 0);

        update_minimum_eligible_tvl(vip, 1_000_000_000_000);

        let module_store = borrow_global<ModuleStore>(@vip);
        assert!(
            module_store.minimum_eligible_tvl == 1_000_000_000_000,
            0
        );

        update_minimum_eligible_tvl(vip, 500_000_000_000);

        let module_store = borrow_global<ModuleStore>(@vip);
        assert!(
            module_store.minimum_eligible_tvl == 500_000_000_000,
            0
        );
    }

    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            new_agent = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun test_execute_challenge(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        new_agent: address
    ) acquires ModuleStore {
        let challenge_stage = 10;
        let bridge_id =
            test_setup(
                chain,
                vip,
                operator,
                BRIDGE_ID_FOR_TEST,
                @0x99,
                string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
                1_000_000_000_000
            );
        test_setup_scene1(vip, bridge_id);
        let (_, create_time) = block::get_block_info();
        let title: string::String = string::utf8(NEW_API_URI_FOR_TEST);
        let summary: string::String = string::utf8(NEW_API_URI_FOR_TEST);
        let new_api_uri: string::String = string::utf8(NEW_API_URI_FOR_TEST);
        let (new_merkle_root, _, _, _) = merkle_root_and_proof_scene2();
        skip_period(1);
        execute_challenge(
            chain,
            BRIDGE_ID_FOR_TEST,
            challenge_stage,
            CHALLENGE_ID_FOR_TEST,
            title,
            summary,
            new_api_uri,
            new_agent,
            *simple_map::borrow(&new_merkle_root, &BRIDGE_ID_FOR_TEST),
            NEW_L2_TOTAL_SCORE_FOR_TEST
        );

        let module_store = borrow_global<ModuleStore>(@vip);
        let (is_registered, version) = get_last_bridge_version(module_store, bridge_id);
        assert!(is_registered, error::unavailable(EBRIDGE_NOT_REGISTERED));
        let snapshot =
            load_snapshot_imut(
                module_store,
                challenge_stage,
                BRIDGE_ID_FOR_TEST,
                version
            );

        assert!(create_time == snapshot.create_time, 1);
        assert!(snapshot.upsert_time > create_time, 2);
        assert!(
            snapshot.merkle_root
                == *simple_map::borrow(&new_merkle_root, &BRIDGE_ID_FOR_TEST),
            3
        );

        let module_store = borrow_global<ModuleStore>(@vip);
        let key = table_key::encode_u64(CHALLENGE_ID_FOR_TEST);
        let executed_challenge = table::borrow(&module_store.challenges, key);

        assert!(executed_challenge.title == title, 4);
        assert!(executed_challenge.summary == summary, 5);
        assert!(executed_challenge.api_uri == new_api_uri, 6);
        assert!(executed_challenge.new_agent == new_agent, 7);
        assert!(
            executed_challenge.merkle_root
                == *simple_map::borrow(&new_merkle_root, &BRIDGE_ID_FOR_TEST),
            8
        );
    }

    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    #[expected_failure(abort_code = 0x80002, location = vesting)]
    fun failed_claim_already_claimed(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires ModuleStore {
        let bridge_id =
            test_setup(
                chain,
                vip,
                operator,
                BRIDGE_ID_FOR_TEST,
                @0x99,
                string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
                1_100_000_000_000
            );

        skip_period(1);
        let (_, merkle_proof_map, score_map, _) = merkle_root_and_proof_scene1();
        test_setup_scene1(vip, bridge_id);

        skip_period(DEFAULT_SKIPPED_CHALLENGE_PERIOD_FOR_TEST);

        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[1],
            vector[*simple_map::borrow(&merkle_proof_map, &1)],
            vector[*simple_map::borrow(&score_map, &1)]
        );
        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[1],
            vector[*simple_map::borrow(&merkle_proof_map, &1)],
            vector[*simple_map::borrow(&score_map, &1)]
        );
    }

    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    #[expected_failure(abort_code = 0x50015, location = Self)]
    fun failed_user_claim_invalid_period(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires ModuleStore {
        let bridge_id =
            test_setup(
                chain,
                vip,
                operator,
                BRIDGE_ID_FOR_TEST,
                @0x99,
                string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
                1_000_000_000_000
            );

        let (_, merkle_proof_map, score_map, _) = merkle_root_and_proof_scene1();

        test_setup_scene1(vip, bridge_id);
        // try claim user reward script;without skipping challenge period
        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[10],
            vector[*simple_map::borrow(&merkle_proof_map, &10)],
            vector[*simple_map::borrow(&score_map, &10)]
        );
    }

    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun test_user_claim_valid_period(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires ModuleStore {
        let bridge_id =
            test_setup(
                chain,
                vip,
                operator,
                BRIDGE_ID_FOR_TEST,
                @0x99,
                string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
                1_000_000_000_000
            );

        let (_, merkle_proof_map, score_map, _) = merkle_root_and_proof_scene1();

        test_setup_scene1(vip, bridge_id);
        skip_period(DEFAULT_SKIPPED_CHALLENGE_PERIOD_FOR_TEST);
        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[1],
            vector[*simple_map::borrow(&merkle_proof_map, &1)],
            vector[*simple_map::borrow(&score_map, &1)]
        );
    }

    #[test(
        chain = @0x1, vip = @vip, operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573
    )]
    fun operator_claim_valid_period(
        chain: &signer, vip: &signer, operator: &signer
    ) acquires ModuleStore {
        let bridge_id =
            test_setup(
                chain,
                vip,
                operator,
                BRIDGE_ID_FOR_TEST,
                @0x99,
                string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
                1_000_000_000_000
            );

        test_setup_scene1(vip, bridge_id);
        skip_period(DEFAULT_SKIPPED_CHALLENGE_PERIOD_FOR_TEST);
        batch_claim_operator_reward_script(operator, bridge_id, 1 /*version*/);
    }

    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            new_agent = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    #[expected_failure(abort_code = 0x50016, location = Self)]
    fun failed_execute_challenge(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        new_agent: address
    ) acquires ModuleStore {
        let bridge_id =
            test_setup(
                chain,
                vip,
                operator,
                BRIDGE_ID_FOR_TEST,
                @0x99,
                string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
                1_000_000_000_000
            );
        test_setup_scene1(vip, bridge_id);

        skip_period(DEFAULT_SKIPPED_CHALLENGE_PERIOD_FOR_TEST);

        let title: string::String = string::utf8(NEW_API_URI_FOR_TEST);
        let summary: string::String = string::utf8(NEW_API_URI_FOR_TEST);
        let new_api_uri: string::String = string::utf8(NEW_API_URI_FOR_TEST);
        let (new_merkle_root, _, _, _) = merkle_root_and_proof_scene2();

        execute_challenge(
            chain,
            BRIDGE_ID_FOR_TEST,
            STAGE_FOR_TEST,
            CHALLENGE_ID_FOR_TEST,
            title,
            summary,
            new_api_uri,
            new_agent,
            *simple_map::borrow(&new_merkle_root, &BRIDGE_ID_FOR_TEST),
            NEW_L2_TOTAL_SCORE_FOR_TEST
        );
    }

    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun test_batch_claim(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires ModuleStore {
        let bridge_id =
            test_setup(
                chain,
                vip,
                operator,
                BRIDGE_ID_FOR_TEST,
                @0x99,
                string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
                1_000_000_000_000
            );

        let (_, merkle_proof_map, _, _) = merkle_root_and_proof_scene2();
        test_setup_scene2(vip, bridge_id);

        skip_period(DEFAULT_SKIPPED_CHALLENGE_PERIOD_FOR_TEST);

        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[1, 2, 3, 4, 5, 6],
            vector[
                *simple_map::borrow(&merkle_proof_map, &1),
                *simple_map::borrow(&merkle_proof_map, &2),
                *simple_map::borrow(&merkle_proof_map, &3),
                *simple_map::borrow(&merkle_proof_map, &4),
                *simple_map::borrow(&merkle_proof_map, &5),
                *simple_map::borrow(&merkle_proof_map, &6)
            ],
            vector[1_000, 1_000, 500, 500, 100, 100]
        );

        batch_claim_operator_reward_script(operator, bridge_id, 1);
    }

    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun test_shrink_reward(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires ModuleStore {
        let bridge_id =
            test_setup(
                chain,
                vip,
                operator,
                BRIDGE_ID_FOR_TEST,
                @0x99,
                string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
                1_000_000_000_000
            );

        let vesting_period = 5;
        let total_reward = DEFAULT_REWARD_PER_STAGE_FOR_TEST;
        update_minimum_score_ratio(vip, bigdecimal::from_ratio_u64(3, 10));
        update_vesting_period(vip, vesting_period);

        let (_, merkle_proof_map, score_map, _) = merkle_root_and_proof_scene2();
        test_setup_scene2(vip, bridge_id);

        skip_period(DEFAULT_SKIPPED_CHALLENGE_PERIOD_FOR_TEST);

        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[1, 2, 3],
            vector[
                *simple_map::borrow(&merkle_proof_map, &1),
                *simple_map::borrow(&merkle_proof_map, &2),
                *simple_map::borrow(&merkle_proof_map, &3)
            ],
            vector[
                *simple_map::borrow(&score_map, &1),
                *simple_map::borrow(&score_map, &2),
                *simple_map::borrow(&score_map, &3)
            ]
        );

        let initial_reward_vesting1 =
            vesting::get_user_vesting_initial_reward(
                signer::address_of(receiver), bridge_id, 1, 1
            );

        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[4, 5, 6],
            vector[
                *simple_map::borrow(&merkle_proof_map, &4),
                *simple_map::borrow(&merkle_proof_map, &5),
                *simple_map::borrow(&merkle_proof_map, &6)
            ],
            vector[
                *simple_map::borrow(&score_map, &4),
                *simple_map::borrow(&score_map, &5),
                *simple_map::borrow(&score_map, &6)
            ]
        );
        // full vested
        assert!(initial_reward_vesting1 == total_reward, 1);
    }

    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    #[expected_failure(abort_code = 0x10014, location = Self)]
    fun failed_claim_jump_stage(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires ModuleStore {
        let bridge_id =
            test_setup(
                chain,
                vip,
                operator,
                BRIDGE_ID_FOR_TEST,
                @0x99,
                string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
                1_000_000_000_000
            );

        let total_reward_per_stage = DEFAULT_REWARD_PER_STAGE_FOR_TEST;
        let reward_per_stage = total_reward_per_stage / 10;

        let vesting_period = DEFAULT_VESTING_PERIOD;

        let (_, merkle_proof_map, score_map, _) = merkle_root_and_proof_scene1();
        test_setup_scene1(vip, bridge_id);

        skip_period(DEFAULT_SKIPPED_CHALLENGE_PERIOD_FOR_TEST);

        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[1, 3],
            vector[
                *simple_map::borrow(&merkle_proof_map, &1),
                *simple_map::borrow(&merkle_proof_map, &3)
            ],
            vector[
                *simple_map::borrow(&score_map, &1),
                *simple_map::borrow(&score_map, &3)
            ]
        );

        assert!(
            coin::balance(
                signer::address_of(receiver),
                vault::reward_metadata()
            ) == (reward_per_stage / (vesting_period * 2)),
            1
        );
    }

    #[test(
        chain = @0x1, vip = @vip, operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573
    )]
    fun test_fund_reward_script(
        chain: &signer, vip: &signer, operator: &signer
    ) acquires ModuleStore {
        let mint_amount = 100_000_000_000_000;
        primary_fungible_store::init_module_for_test();
        vesting::init_module_for_test(vip);
        tvl_manager::init_module_for_test(vip);
        let (_, _, mint_cap, _) = initialize_coin(chain, string::utf8(b"uinit"));
        init_module_for_test(vip);

        coin::mint_to(
            &mint_cap,
            signer::address_of(chain),
            mint_amount
        );
        vault::deposit(chain, mint_amount);
        coin::mint_to(&mint_cap, @0x90, mint_amount / 2);
        coin::mint_to(&mint_cap, @0x91, mint_amount / 4);
        coin::mint_to(&mint_cap, @0x92, mint_amount / 4);
        let operator_addr = signer::address_of(operator);

        // initialize vip_reward
        register(
            vip,
            operator_addr,
            1,
            @0x90,
            string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_CHANGE_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_RATE_FOR_TEST, 10),
            MOVEVM
        );

        register(
            vip,
            operator_addr,
            2,
            @0x91,
            string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_CHANGE_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_RATE_FOR_TEST, 10),
            MOVEVM
        );

        register(
            vip,
            operator_addr,
            3,
            @0x92,
            string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_CHANGE_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_RATE_FOR_TEST, 10),
            MOVEVM
        );

        update_pool_split_ratio(vip, bigdecimal::from_ratio_u64(7, 10));

        update_vip_weights(
            chain,
            vector[1, 2, 3],
            vector[
                bigdecimal::from_ratio_u64(1, 4),
                bigdecimal::from_ratio_u64(1, 4),
                bigdecimal::from_ratio_u64(2, 4)
            ]
        );
        // add_tvl_snapshot();
        fund_reward_script(vip);
        skip_period(DEFAULT_STAGE_INTERVAL);

        // check the balances splited
        assert!(
            get_user_funded_reward(1, 1)
                == get_expected_reward(1, DEFAULT_REWARD_PER_STAGE_FOR_TEST),
            4
        );
        assert!(
            get_user_funded_reward(2, 1)
                == get_expected_reward(2, DEFAULT_REWARD_PER_STAGE_FOR_TEST),
            5
        );
        assert!(
            get_user_funded_reward(3, 1)
                == get_expected_reward(3, DEFAULT_REWARD_PER_STAGE_FOR_TEST),
            6
        );
        assert!(get_operator_funded_reward(1, 1) == 0, 7);
        assert!(get_operator_funded_reward(2, 1) == 0, 8);
        assert!(get_operator_funded_reward(3, 1) == 0, 9);

        update_operator_commission(
            operator,
            1,
            1,
            bigdecimal::from_ratio_u64(5, 10)
        );
        update_operator_commission(
            operator,
            2,
            1,
            bigdecimal::from_ratio_u64(5, 10)
        );

        // add_tvl_snapshot();
        fund_reward_script(vip);
        skip_period(DEFAULT_STAGE_INTERVAL);

        // check the balances splited
        assert!(
            get_user_funded_reward(1, 2)
                == get_expected_reward(1, DEFAULT_REWARD_PER_STAGE_FOR_TEST) / 2,
            10
        );
        assert!(
            get_user_funded_reward(2, 2)
                == get_expected_reward(2, DEFAULT_REWARD_PER_STAGE_FOR_TEST) / 2,
            11
        );
        assert!(
            get_user_funded_reward(3, 2)
                == get_expected_reward(3, DEFAULT_REWARD_PER_STAGE_FOR_TEST),
            12
        );
        assert!(
            get_operator_funded_reward(1, 2)
                == get_expected_reward(1, DEFAULT_REWARD_PER_STAGE_FOR_TEST) / 2,
            13
        );
        assert!(
            get_operator_funded_reward(2, 2)
                == get_expected_reward(2, DEFAULT_REWARD_PER_STAGE_FOR_TEST) / 2,
            14
        );
        assert!(get_operator_funded_reward(3, 2) == 0, 15);

        fund_reward_script(vip);
        skip_period(DEFAULT_STAGE_INTERVAL);

        assert!(
            get_user_funded_reward(1, 3)
                == get_expected_reward(1, DEFAULT_REWARD_PER_STAGE_FOR_TEST) / 2,
            15
        );
        assert!(
            get_user_funded_reward(2, 3)
                == get_expected_reward(2, DEFAULT_REWARD_PER_STAGE_FOR_TEST) / 2,
            16
        );
        assert!(
            get_user_funded_reward(3, 3)
                == get_expected_reward(3, DEFAULT_REWARD_PER_STAGE_FOR_TEST),
            17
        );
        assert!(
            get_operator_funded_reward(1, 3)
                == get_expected_reward(1, DEFAULT_REWARD_PER_STAGE_FOR_TEST) / 2,
            18
        );
        assert!(
            get_operator_funded_reward(2, 3)
                == get_expected_reward(2, DEFAULT_REWARD_PER_STAGE_FOR_TEST) / 2,
            19
        );
        assert!(get_operator_funded_reward(3, 3) == 0, 20);

    }

    #[
        test(
            chain = @0x1,
            vip = @vip,
            agent = @0x2,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun test_deregistered_bridge(
        chain: &signer,
        vip: &signer,
        agent: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires ModuleStore, TestCapability {
        primary_fungible_store::init_module_for_test();
        tvl_manager::init_module_for_test(vip);
        vesting::init_module_for_test(vip);
        let (burn_cap, freeze_cap, mint_cap, _) =
            initialize_coin(chain, string::utf8(b"uinit"));
        init_module_for_test(vip);

        move_to(
            chain,
            TestCapability { burn_cap, freeze_cap, mint_cap }
        );

        let cap = borrow_global<TestCapability>(signer::address_of(chain));
        let operator_addr = signer::address_of(operator);
        let (bridge_id1, bridge_id2) = (1, 2);
        let (bridge_address1, bridge_address2) = (@0x999, @0x1000);
        let mint_amount = 1_000_000_000_000;

        coin::mint_to(
            &cap.mint_cap,
            signer::address_of(chain),
            mint_amount
        );
        vault::deposit(chain, mint_amount);
        coin::mint_to(
            &cap.mint_cap,
            signer::address_of(operator),
            mint_amount
        );
        coin::mint_to(&cap.mint_cap, bridge_address1, mint_amount);
        coin::mint_to(&cap.mint_cap, bridge_address2, mint_amount);

        register(
            vip,
            operator_addr,
            bridge_id1,
            bridge_address1,
            string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_CHANGE_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_RATE_FOR_TEST, 10),
            MOVEVM
        );

        // need other L2 to increase stage
        register(
            vip,
            operator_addr,
            bridge_id2,
            bridge_address2,
            string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_CHANGE_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_RATE_FOR_TEST, 10),
            MOVEVM
        );

        let (whitelisted_bridge_ids, _) = get_whitelisted_bridge_ids();
        assert!(whitelisted_bridge_ids == vector[1, 2], 0);
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        let (_, version) = get_last_bridge_version(module_store, bridge_id1);
        let init_stage =
            load_registered_bridge_imut(module_store, bridge_id1, version).init_stage;
        assert!(init_stage == 1, 1);

        let (merkle_root_map, merkle_proof_map, score_map, total_score_map) =
            merkle_root_and_proof_scene1();

        update_agent(
            vip,
            signer::address_of(agent),
            string::utf8(b"")
        );
        update_vip_weights(
            vip,
            vector[1, 2],
            vector[
                bigdecimal::from_ratio_u64(5, 10),
                bigdecimal::from_ratio_u64(5, 10)
            ]
        );
        // stage 1
        fund_reward_script(agent);
        skip_period(DEFAULT_STAGE_INTERVAL);
        // stage 2
        fund_reward_script(agent);
        submit_snapshot(
            agent,
            bridge_id1,
            1,
            1,
            *simple_map::borrow(&merkle_root_map, &1),
            *simple_map::borrow(&total_score_map, &1)
        );
        skip_period(DEFAULT_STAGE_INTERVAL);

        // deregister bridge_id 1
        deregister(vip, bridge_id1);

        // skip two stage
        // stage 3
        fund_reward_script(agent);
        skip_period(DEFAULT_STAGE_INTERVAL);
        // stage 4
        fund_reward_script(agent);
        skip_period(DEFAULT_STAGE_INTERVAL);

        register(
            vip,
            operator_addr,
            bridge_id1,
            @0x999,
            string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_CHANGE_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_RATE_FOR_TEST, 10),
            MOVEVM
        );
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        let (_, version) = get_last_bridge_version(module_store, bridge_id1);
        assert!(version == 2, 2);
        assert!(get_bridge_init_stage(bridge_id1) == 5, 3);
        // stage 5
        fund_reward_script(agent);
        skip_period(DEFAULT_STAGE_INTERVAL);
        // stage 6
        fund_reward_script(agent);
        submit_snapshot(
            agent,
            bridge_id1,
            2,
            5,
            *simple_map::borrow(&merkle_root_map, &5),
            *simple_map::borrow(&total_score_map, &5)
        );

        skip_period(DEFAULT_SKIPPED_CHALLENGE_PERIOD_FOR_TEST);
        // stage 1 claim
        batch_claim_user_reward_script(
            receiver,
            bridge_id1,
            1, //version
            vector[1],
            vector[*simple_map::borrow(&merkle_proof_map, &1)],
            vector[*simple_map::borrow(&score_map, &1)]
        );
        // stage 5 claim
        batch_claim_user_reward_script(
            receiver,
            bridge_id1,
            2, //version
            vector[5],
            vector[*simple_map::borrow(&merkle_proof_map, &5)],
            vector[*simple_map::borrow(&score_map, &5)]
        );
    }

    #[test(vip = @vip)]
    fun test_update_challenge_period(vip: &signer) acquires ModuleStore {
        init_module_for_test(vip);
        update_challenge_period(vip, DEFAULT_NEW_CHALLENGE_PERIOD);
        let module_store = borrow_global<ModuleStore>(@vip);
        assert!(
            module_store.challenge_period == DEFAULT_NEW_CHALLENGE_PERIOD,
            0
        )
    }

    #[test(
        chain = @0x1, vip = @vip, operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573
    )]
    #[expected_failure(abort_code = 0x10013, location = Self)]
    fun failed_update_vip_weights(
        chain: &signer, vip: &signer, operator: &signer
    ) acquires ModuleStore {
        primary_fungible_store::init_module_for_test();
        vesting::init_module_for_test(vip);
        let (burn_cap, freeze_cap, mint_cap, _) =
            initialize_coin(chain, string::utf8(b"uinit"));
        init_module_for_test(vip);

        move_to(
            chain,
            TestCapability { burn_cap, freeze_cap, mint_cap }
        );

        let operator_addr = signer::address_of(operator);
        let (bridge_id1, bridge_id2) = (1, 2);
        let (bridge_address1, bridge_address2) = (@0x999, @0x1000);

        register(
            vip,
            operator_addr,
            bridge_id1,
            bridge_address1,
            string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_CHANGE_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_RATE_FOR_TEST, 10),
            MOVEVM
        );

        // need other L2 to increase stage
        register(
            vip,
            operator_addr,
            bridge_id2,
            bridge_address2,
            string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_CHANGE_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_RATE_FOR_TEST, 10),
            MOVEVM
        );

        update_vip_weights(
            vip,
            vector[1, 2],
            vector[
                bigdecimal::from_ratio_u64(5, 10),
                bigdecimal::from_ratio_u64(7, 10)
            ]
        );
    }

    #[test(
        chain = @0x1, vip = @vip, operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573
    )]
    #[expected_failure(abort_code = 0x10013, location = Self)]
    fun failed_update_vip_weight(
        chain: &signer, vip: &signer, operator: &signer
    ) acquires ModuleStore {
        primary_fungible_store::init_module_for_test();
        vesting::init_module_for_test(vip);
        let (burn_cap, freeze_cap, mint_cap, _) =
            initialize_coin(chain, string::utf8(b"uinit"));
        init_module_for_test(vip);

        move_to(
            chain,
            TestCapability { burn_cap, freeze_cap, mint_cap }
        );

        let operator_addr = signer::address_of(operator);
        let (bridge_id1, bridge_id2) = (1, 2);
        let (bridge_address1, bridge_address2) = (@0x999, @0x1000);

        register(
            vip,
            operator_addr,
            bridge_id1,
            bridge_address1,
            string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_CHANGE_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_RATE_FOR_TEST, 10),
            MOVEVM
        );

        // need other L2 to increase stage
        register(
            vip,
            operator_addr,
            bridge_id2,
            bridge_address2,
            string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_CHANGE_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_RATE_FOR_TEST, 10),
            MOVEVM
        );

        update_vip_weights(
            vip,
            vector[1, 2],
            vector[
                bigdecimal::from_ratio_u64(5, 10),
                bigdecimal::from_ratio_u64(4, 10)
            ]
        );
        update_vip_weight(vip, 1, bigdecimal::from_ratio_u64(7, 10));
    }

    #[test_only]
    public fun test_setup_for_lock_staking(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        account: &signer,
        bridge_id: u64,
        bridge_address: address,
        mint_amount: u64
    ): (u64, Object<Metadata>, Object<Metadata>, Object<Metadata>, string::String) acquires ModuleStore {
        dex::init_module_for_test();
        staking::init_module_for_test();
        primary_fungible_store::init_module_for_test();
        vesting::init_module_for_test(vip);
        tvl_manager::init_module_for_test(vip);
        lock_staking::init_module_for_test(vip);
        init_module_for_test(vip);

        let (_burn_cap, _freeze_cap, mint_cap, _) =
            initialize_coin(chain, string::utf8(b"uinit"));

        let reward_metadata = vault::reward_metadata();
        coin::mint_to(&mint_cap, bridge_address, mint_amount);
        coin::mint_to(
            &mint_cap,
            signer::address_of(operator),
            mint_amount
        );
        coin::mint_to(
            &mint_cap,
            signer::address_of(account),
            mint_amount
        );
        coin::mint_to(
            &mint_cap,
            signer::address_of(chain),
            mint_amount
        );
        vault::deposit(chain, mint_amount);

        coin::mint_to(
            &mint_cap,
            signer::address_of(chain),
            mint_amount
        ); // for pair creation
        coin::mint_to(
            &mint_cap,
            signer::address_of(chain),
            mint_amount
        ); // for staking reward

        let validator = string::utf8(b"val");

        register(
            vip,
            signer::address_of(operator),
            bridge_id,
            bridge_address,
            string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_CHANGE_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_RATE_FOR_TEST, 10),
            MOVEVM
        );

        let (_burn_cap, _freeze_cap, mint_cap, stakelisted_metadata) =
            initialize_coin(chain, string::utf8(b"USDC"));
        coin::mint_to(
            &mint_cap,
            signer::address_of(chain),
            mint_amount
        );
        coin::mint_to(
            &mint_cap,
            signer::address_of(account),
            mint_amount
        );

        dex::create_pair_script(
            chain,
            string::utf8(b"pair"),
            string::utf8(b"INIT-USDC"),
            bigdecimal::from_ratio_u64(3, 1000),
            bigdecimal::from_ratio_u64(5, 10),
            bigdecimal::from_ratio_u64(5, 10),
            reward_metadata,
            stakelisted_metadata,
            mint_amount,
            mint_amount
        );

        let lp_metadata =
            coin::metadata(
                signer::address_of(chain),
                string::utf8(b"INIT-USDC")
            );
        staking::initialize_for_chain(chain, lp_metadata);
        staking::set_staking_share_ratio(
            *string::bytes(&validator),
            &lp_metadata,
            &bigdecimal::one(),
            1
        );
        fund_reward_script(vip);
        skip_period(DEFAULT_STAGE_INTERVAL);
        (bridge_id, reward_metadata, stakelisted_metadata, lp_metadata, validator)
    }

    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun test_lock_staking(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires ModuleStore {
        let mint_amount = 10_000_000_000_000;
        let (bridge_id, _, stakelisted_metadata, lp_metadata, validator) =
            test_setup_for_lock_staking(
                chain,
                vip,
                operator,
                receiver,
                1,
                @0x99,
                mint_amount
            );

        let (_, merkle_proof_map, _, _) = merkle_root_and_proof_scene1();
        test_setup_scene1(vip, bridge_id);

        skip_period(DEFAULT_SKIPPED_CHALLENGE_PERIOD_FOR_TEST);

        batch_claim_user_reward_script(
            receiver,
            bridge_id,
            1,
            vector[1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
            vector[
                *simple_map::borrow(&merkle_proof_map, &1),
                *simple_map::borrow(&merkle_proof_map, &2),
                *simple_map::borrow(&merkle_proof_map, &3),
                *simple_map::borrow(&merkle_proof_map, &4),
                *simple_map::borrow(&merkle_proof_map, &5),
                *simple_map::borrow(&merkle_proof_map, &6),
                *simple_map::borrow(&merkle_proof_map, &7),
                *simple_map::borrow(&merkle_proof_map, &8),
                *simple_map::borrow(&merkle_proof_map, &9),
                *simple_map::borrow(&merkle_proof_map, &10)
            ],
            vector[
                800_000,
                800_000,
                400_000,
                400_000,
                800_000,
                800_000,
                800_000,
                800_000,
                800_000,
                800_000
            ]
        );

        let stage = 1;
        let lock_period = 60 * 60 * 24; // 1 day

        skip_period(100);
        update_minimun_lock_staking_period(vip, lock_period);
        let esinit_amount =
            vesting::get_user_vesting_remaining(
                signer::address_of(receiver),
                bridge_id,
                1,
                stage
            );

        // lock stake vesting in stage 1
        lock_stake_script(
            receiver,
            bridge_id,
            1,
            lp_metadata,
            option::none(),
            validator,
            stage,
            esinit_amount,
            stakelisted_metadata,
            esinit_amount,
            option::none()
        );
    }

    #[test(
        chain = @0x1, vip = @vip, operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573
    )]
    #[expected_failure(abort_code = 0xd0022, location = Self)]
    fun test_min_eligible_tvl_failure(
        chain: &signer, vip: &signer, operator: &signer
    ) acquires ModuleStore {
        primary_fungible_store::init_module_for_test();
        vesting::init_module_for_test(vip);
        initialize_coin(chain, string::utf8(b"uinit"));
        init_module_for_test(vip);

        update_params(
            chain,
            option::none(), //stage_interval: Option<u64>,
            option::none(), //vesting_period: Option<u64>,
            option::none(), //minimum_lock_staking_period: Option<u64>,
            option::some(100), //minimum_eligible_tvl: Option<u64>,
            option::none(), //maximum_tvl_ratio: Option<BigDecimal>,
            option::none(), //maximum_weight_ratio: Option<BigDecimal>,
            option::none(), //minimum_score_ratio: Option<BigDecimal>,
            option::none(), //pool_split_ratio: Option<BigDecimal>,
            option::none() //challenge_period: Option<u64>,
        );

        // initialize vip_reward
        register(
            vip,
            signer::address_of(operator),
            1,
            @0x90,
            string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_MAX_CHANGE_RATE_FOR_TEST, 10),
            bigdecimal::from_ratio_u64(DEFAULT_COMMISSION_RATE_FOR_TEST, 10),
            MOVEVM
        );
    }
}
