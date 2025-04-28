#[test_only]
module vip::test {
    use std::bcs;
    use std::hash::sha3_256;
    use std::option;
    use std::signer;
    use std::string::{Self, String};
    use std::vector;

    use initia_std::block;
    use initia_std::coin;
    use initia_std::dex;
    use initia_std::stableswap;
    use initia_std::bigdecimal::{Self, BigDecimal};
    use initia_std::fungible_asset::Metadata;
    use initia_std::object::Object;
    use initia_std::staking;
    use initia_std::primary_fungible_store;

    use vip::lock_staking;
    use vip::vip;
    use vip::tvl_manager;
    use vip::vault;
    use vip::vesting;

    struct TestState has key {
        last_submitted_stage: u64
    }

    fun init_and_mint_coin(
        creator: &signer, symbol: String, amount: u64
    ): Object<Metadata> {
        let (init_mint_cap, _, _) =
            coin::initialize(
                creator,
                option::none(),
                string::utf8(b""),
                symbol,
                6,
                string::utf8(b""),
                string::utf8(b"")
            );
        coin::mint_to(
            &init_mint_cap,
            signer::address_of(creator),
            amount
        );
        coin::metadata(signer::address_of(creator), symbol)
    }

    fun get_validator(): String {
        string::utf8(b"validator")
    }

    fun get_bridge_id(): u64 {
        1
    }

    fun get_bridge2_id(): u64 {
        2
    }

    fun get_version(): u64 {
        1
    }

    fun get_bridge_address(): address {
        @0x99
    }

    fun get_bridge2_address(): address {
        @0x98
    }

    fun get_stage(): u64 {
        let (stage, _, _, _, _, _, _, _, _) = vip::unpack_module_store();
        stage
    }

    const TEST_STAGE_INTERVAL: u64 = 100;

    fun get_stage_interval(): u64 {
        let (_, stage_interval, _, _, _, _, _, _, _) = vip::unpack_module_store();
        stage_interval
    }

    const TEST_VESTING_PERIOD: u64 = 10;
    fun get_vesting_period(): u64 {
        let (_, _, vesting_period, _, _, _, _, _, _) = vip::unpack_module_store();
        vesting_period
    }

    const TEST_CHALLENGE_PERIOD: u64 = 50;
    fun get_challenge_period(): u64 {
        let (_, _, _, challenge_period, _, _, _, _, _) = vip::unpack_module_store();
        challenge_period
    }

    const TEST_MIN_SCORE_RATIO: u64 = 5; // with 10 as the denominator
    fun get_minimum_score_ratio(): BigDecimal {
        let (_, _, _, _, minimum_score_ratio, _, _, _, _) = vip::unpack_module_store();
        minimum_score_ratio
    }

    const TEST_POOL_RATIO: u64 = 5; // with 10 as the denominator
    fun get_pool_split_ratio(): BigDecimal {
        let (_, _, _, _, _, pool_split_ratio, _, _, _) = vip::unpack_module_store();
        pool_split_ratio
    }

    const TEST_MAX_TVL_RATIO: u64 = 10; // with 10 as the denominator
    fun get_maximum_tvl_ratio(): BigDecimal {
        let (_, _, _, _, _, _, maximum_tvl_ratio, _, _) = vip::unpack_module_store();
        maximum_tvl_ratio
    }

    const TEST_MIN_ELIGIBLE_TVL: u64 = 1;
    fun get_minimum_eligible_tvl(): u64 {
        let (_, _, _, _, _, _, _, minimum_eligible_tvl, _) = vip::unpack_module_store();
        minimum_eligible_tvl
    }

    const TEST_MAX_WEIGHT_RATIO: u64 = 5; // with 10 as the denominator
    fun get_maximum_weight_ratio(): BigDecimal {
        let (_, _, _, _, _, _, _, _, maximum_weight_ratio) = vip::unpack_module_store();
        maximum_weight_ratio
    }

    fun get_reward_per_stage(): u64 {
        vault::reward_per_stage()
    }

    fun get_vm_type(): u64 {
        0
    }

    fun skip_period(period: u64) {
        let (height, curr_time) = block::get_block_info();
        block::set_block_info(height + period / 2, curr_time + period);
    }

    fun reward_balance(addr: address): u64 {
        primary_fungible_store::balance(addr, vault::reward_metadata())
    }

    // only do fund reward not
    fun fund_reward(
        agent: &signer,
        stages: &mut vector<u64>,
        merkle_proofs: &mut vector<vector<vector<u8>>>,
        l2_scores: &mut vector<u64>
    ) acquires TestState {
        vip::fund_reward_script(agent);
        let test_state = borrow_global_mut<TestState>(@vip);
        test_state.last_submitted_stage = test_state.last_submitted_stage + 1;
        let stage = test_state.last_submitted_stage;
        update_timestamp(get_stage_interval() + 1, true);
        vector::push_back(stages, stage);
        vector::push_back(merkle_proofs, vector[vector[]]);
        vector::push_back(l2_scores, 0);
    }

    fun submit_snapshot(
        agent: &signer,
        bridge_id: u64,
        version: u64,
        user: address,
        l2_score: u64,
        total_l2_score: u64,
        stages: &mut vector<u64>,
        merkle_proofs: &mut vector<vector<vector<u8>>>,
        l2_scores: &mut vector<u64>
    ) acquires TestState {
        let test_state = borrow_global_mut<TestState>(@vip);
        let stage = test_state.last_submitted_stage;
        let (merkle_root, merkle_proof) =
            get_merkle_root_and_proof(stage, user, l2_score, total_l2_score);
        vip::submit_snapshot(
            agent,
            bridge_id,
            version,
            stage,
            merkle_root,
            total_l2_score
        );
        vector::push_back(stages, stage);
        vector::push_back(merkle_proofs, merkle_proof);
        vector::push_back(l2_scores, l2_score);
    }

    fun submit_snapshot_and_fund_reward(
        agent: &signer,
        bridge_id: u64,
        version: u64,
        user: address,
        l2_score: u64,
        total_l2_score: u64,
        stages: &mut vector<u64>,
        merkle_proofs: &mut vector<vector<vector<u8>>>,
        l2_scores: &mut vector<u64>
    ) acquires TestState {
        vip::fund_reward_script(agent);
        let test_state = borrow_global_mut<TestState>(@vip);
        test_state.last_submitted_stage = test_state.last_submitted_stage + 1;
        let stage = test_state.last_submitted_stage;
        let (merkle_root, merkle_proof) =
            get_merkle_root_and_proof(stage, user, l2_score, total_l2_score);
        vip::submit_snapshot(
            agent,
            bridge_id,
            version,
            stage,
            merkle_root,
            total_l2_score
        );

        update_timestamp(get_stage_interval() + 1, true);
        vector::push_back(stages, stage);
        vector::push_back(merkle_proofs, merkle_proof);
        vector::push_back(l2_scores, l2_score);

        skip_period(2);
    }

    fun get_merkle_root_and_proof(
        stage: u64,
        user: address,
        l2_score: u64,
        total_l2_score: u64
    ): (vector<u8>, vector<vector<u8>>) {
        let user_hash = score_hash(
            get_bridge_id(),
            stage,
            user,
            l2_score,
            total_l2_score
        );
        let dummpy_hash =
            score_hash(
                get_bridge_id(),
                stage,
                @0xff,
                total_l2_score - l2_score,
                total_l2_score
            );

        let cmp = bytes_cmp(&user_hash, &dummpy_hash);
        let merkle_root =
            if (cmp == 2 /* less */) {
                let tmp = user_hash;
                vector::append(&mut tmp, dummpy_hash);
                sha3_256(tmp)
            } else /* greater or equals */ {
                let tmp = dummpy_hash;
                vector::append(&mut tmp, user_hash);
                sha3_256(tmp)
            };
        (merkle_root, vector[dummpy_hash])
    }

    fun bytes_cmp(v1: &vector<u8>, v2: &vector<u8>): u8 {
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

    public fun initialize(
        chain: &signer, vip: &signer, operator: &signer
    ) {
        lock_staking::init_module_for_test(vip);
        primary_fungible_store::init_module_for_test();
        stableswap::init_module_for_test();
        dex::init_module_for_test();
        let init_metadata =
            init_and_mint_coin(
                chain,
                string::utf8(b"uinit"),
                10000000000000000
            );
        let usdc_metadata =
            init_and_mint_coin(
                chain,
                string::utf8(b"uusdc"),
                10000000000000000
            );
        tvl_manager::init_module_for_test(vip);
        vip::init_module_for_test(vip);
        vesting::init_module_for_test(vip);

        vip::update_params(
            vip,
            option::some(TEST_STAGE_INTERVAL),
            option::some(TEST_VESTING_PERIOD),
            option::none(),
            option::some(TEST_MIN_ELIGIBLE_TVL),
            option::some(bigdecimal::zero()), // deprecated
            option::some(bigdecimal::from_ratio_u64(TEST_MAX_WEIGHT_RATIO, 10)),
            option::some(bigdecimal::from_ratio_u64(TEST_MIN_SCORE_RATIO, 10)),
            option::some(bigdecimal::from_ratio_u64(TEST_POOL_RATIO, 10)),
            option::some(TEST_CHALLENGE_PERIOD)
        );
        vault::deposit(chain, 9_000_000_000_000_000);
        vault::update_reward_per_stage(vip, 100_000_000);

        coin::transfer(
            chain,
            get_bridge_address(),
            init_metadata,
            100_000_000
        );

        coin::transfer(
            chain,
            get_bridge2_address(),
            init_metadata,
            100_000_000
        );

        vip::register(
            vip,
            signer::address_of(operator),
            get_bridge_id(),
            get_bridge_address(),
            string::utf8(b"contract"),
            bigdecimal::from_ratio_u64(1, 2),
            bigdecimal::from_ratio_u64(1, 2),
            bigdecimal::from_ratio_u64(1, 2),
            get_vm_type()
        );

        vip::register(
            vip,
            signer::address_of(operator),
            get_bridge2_id(),
            get_bridge2_address(),
            string::utf8(b"contract"),
            bigdecimal::from_ratio_u64(1, 2),
            bigdecimal::from_ratio_u64(1, 2),
            bigdecimal::from_ratio_u64(1, 2),
            get_vm_type()
        );

        vip::update_vip_weights(
            vip,
            vector[get_bridge_id(), get_bridge2_id()],
            vector[bigdecimal::from_ratio_u64(1, 2), bigdecimal::from_ratio_u64(1, 2)]
        );
        move_to(vip, TestState { last_submitted_stage: 0 });
        dex::create_pair_script(
            chain,
            string::utf8(b"pair"),
            string::utf8(b"INIT-USDC"),
            bigdecimal::from_ratio_u64(3, 1000),
            bigdecimal::from_ratio_u64(5, 10),
            bigdecimal::from_ratio_u64(5, 10),
            init_metadata,
            usdc_metadata,
            100000,
            100000
        );
        stableswap::create_pool_script(
            chain,
            string::utf8(b"pair"),
            string::utf8(b"STABLE-INIT-USDC"),
            bigdecimal::from_ratio_u64(3, 1000),
            vector[init_metadata, usdc_metadata],
            vector[100000, 100000],
            6000
        );

        let lp_metadata = get_lp_metadata();
        let stable_lp_metadata = get_stable_lp_metadata();
        staking::init_module_for_test();
        staking::initialize_for_chain(chain, lp_metadata);
        staking::initialize_for_chain(chain, stable_lp_metadata);
        staking::set_staking_share_ratio(
            *string::bytes(&get_validator()),
            &lp_metadata,
            &bigdecimal::one(),
            1
        );
        staking::set_staking_share_ratio(
            *string::bytes(&get_validator()),
            &stable_lp_metadata,
            &bigdecimal::one(),
            1
        );
        vip::fund_reward_script(vip);
        skip_period(TEST_STAGE_INTERVAL + 1);
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

    fun get_lp_metadata(): Object<Metadata> {
        coin::metadata(@0x1, string::utf8(b"INIT-USDC"))
    }

    fun get_stable_lp_metadata(): Object<Metadata> {
        coin::metadata(@0x1, string::utf8(b"STABLE-INIT-USDC"))
    }

    fun usdc_metadata(): Object<Metadata> {
        coin::metadata(@0x1, string::utf8(b"uusdc"))
    }

    fun init_metadata(): Object<Metadata> {
        coin::metadata(@0x1, string::utf8(b"uinit"))
    }

    fun update_timestamp(diff: u64, increase: bool) {
        let (height, curr_time) = block::get_block_info();
        let updated_time =
            if (increase) {
                curr_time + diff
            } else {
                curr_time - diff
            };
        block::set_block_info(height, updated_time);
    }

    fun reset_claim_args(): (vector<u64>, vector<vector<vector<u8>>>, vector<u64>) {
        let stages: vector<u64> = vector[];
        let merkle_proofs: vector<vector<vector<u8>>> = vector[];
        let l2_scores: vector<u64> = vector[];
        (stages, merkle_proofs, l2_scores)
    }

    #[test(
        chain = @initia_std, vip = @vip, operator = @0x2, user = @0x3
    )]
    fun e2e(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        user: &signer
    ) acquires TestState {
        initialize(chain, vip, operator);
        let user_addr = signer::address_of(user);
        coin::transfer(chain, user_addr, usdc_metadata(), 1000000);
        let (stages, merkle_proofs, l2_scores) = reset_claim_args();
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            user_addr,
            10,
            100,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            user_addr,
            20,
            100,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            user_addr,
            0,
            100,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            user_addr,
            40,
            100,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        vip::batch_claim_user_reward_script(
            user,
            get_bridge_id(),
            get_version(),
            stages,
            merkle_proofs,
            l2_scores
        );
        (stages, merkle_proofs, l2_scores) = reset_claim_args();
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            user_addr,
            40,
            100,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        vip::batch_claim_user_reward_script(
            user,
            get_bridge_id(),
            get_version(),
            stages,
            merkle_proofs,
            l2_scores
        );
        let stage = *vector::borrow(&stages, 0);

        vip::lock_stake_script(
            user,
            get_bridge_id(),
            get_version(),
            get_lp_metadata(),
            option::none(),
            get_validator(),
            stage,
            1000,
            usdc_metadata(),
            1000,
            option::none()
        );
    }

    //
    // User Claim
    //
    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun claim_multiple_vested_positions(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires TestState {
        initialize(chain, vip, operator);
        let receiver_addr = signer::address_of(receiver);
        let vesting_period = get_vesting_period();
        let (stages, merkle_proofs, l2_scores) = reset_claim_args();
        // submit snapshot of stage 1; total score: 1000, receiver's score : 100
        // stage 1 snapshot submitted
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 2
        // total score: 1000, receiver's score : 500
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            500,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 3
        // total score: 1000, receiver's score : 100
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 4
        // total score: 1000, receiver's score : 100
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        assert!(
            coin::balance(receiver_addr, init_metadata()) == 0,
            1
        );
        // claim vesting positions of stage 1~4
        vip::batch_claim_user_reward_script(
            receiver,
            get_bridge_id(),
            get_version(),
            stages,
            merkle_proofs,
            l2_scores
        );
        let vesting1_initial_reward =
            vesting::get_user_vesting_initial_reward(receiver_addr, get_bridge_id(), 1, 1);
        let vesting2_initial_reward =
            vesting::get_user_vesting_initial_reward(receiver_addr, get_bridge_id(), 1, 2);
        let vesting3_initial_reward =
            vesting::get_user_vesting_initial_reward(receiver_addr, get_bridge_id(), 1, 3);

        // claimed reward stage 1 ~ 3
        assert!(
            coin::balance(receiver_addr, init_metadata())
                == (
                    3 * vesting1_initial_reward / vesting_period /*stage 1 reward vested three time with 100% vesting */
                ) + (2 * 2 * vesting2_initial_reward) / (vesting_period * 5) /* stage 2 reward vested twice with 20% vesting */
                    + (vesting3_initial_reward / vesting_period), /* stage 3 reward vested one time with 100% vesting */
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
    fun claim_with_zero_score(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires TestState {
        initialize(chain, vip, operator);
        let receiver_addr = signer::address_of(receiver);
        let vesting_period = get_vesting_period();
        let (stages, merkle_proofs, l2_scores) = reset_claim_args();
        // submit snapshot of stage 1; total score: 1000, receiver's score : 100
        // stage 1 snapshot submitted
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 2
        // total score: 1000, receiver's score : 500
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            500,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 3
        // total score: 1000, receiver's score : 0
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            0,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        let vault_balance_before = vault::balance();
        // stage 1,2,3 claim
        vip::batch_claim_user_reward_script(
            receiver,
            1,
            get_version(),
            stages,
            merkle_proofs,
            l2_scores
        );

        // do not create vesting positions and finalize it
        assert!(
            vesting::get_user_last_claimed_stage(receiver_addr, 1, 1) == 3,
            5
        );
        assert!(
            !vesting::has_user_vesting_position(receiver_addr, 1, 1, 3),
            6
        );
        assert!(
            !vesting::has_user_vesting_position(receiver_addr, 1, 1, 3),
            7
        );
        let vesting1_initial_reward =
            vesting::get_user_vesting_initial_reward(receiver_addr, get_bridge_id(), 1, 1);
        let vault_balance_after = vault::balance();
        // vested stage 1 reward(stage_reward  + vested stage 2 reward(0))
        assert!(
            reward_balance(receiver_addr) == (vesting1_initial_reward / vesting_period),
            8
        );
        // claim no reward of vesting2 position; vault balance reduce only amount of claim reward
        assert!(
            vault_balance_after == vault_balance_before - reward_balance(receiver_addr),
            9
        )
    }

    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun claim_with_total_zero_score(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires TestState {
        initialize(chain, vip, operator);
        let receiver_addr = signer::address_of(receiver);
        let vesting_period = get_vesting_period();
        let (stages, merkle_proofs, l2_scores) = reset_claim_args();
        // submit snapshot of stage 1; total score: 1000, receiver's score : 100
        // stage 1 snapshot submitted
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 2
        // total score: 1000, receiver's score : 500
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            500,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 3
        // total score: 0, receiver's score : 0
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            0,
            0,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );

        // stage 4
        // total score: 1000, receiver's score : 100
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        assert!(reward_balance(receiver_addr) == 0, 1);

        let vault_balance_before = vault::balance();
        // stage 1, 2, 3, 4 claimed
        vip::batch_claim_user_reward_script(
            receiver,
            get_bridge_id(),
            get_version(),
            stages,
            merkle_proofs,
            l2_scores
        );
        let vesting1_initial_reward =
            vesting::get_user_vesting_initial_reward(receiver_addr, get_bridge_id(), 1, 1);
        let vesting2_initial_reward =
            vesting::get_user_vesting_initial_reward(receiver_addr, get_bridge_id(), 1, 2);
        let vesting1_net_reward = 2 * vesting1_initial_reward / vesting_period; // stage 2 : 100%, stage 3: 0% , stage 4 : 100%
        let vesting2_net_reward = 2 * vesting2_initial_reward / (5 * vesting_period); // stage 3: 0%, stage 4 : 40%
        let vault_balance_after = vault::balance();
        assert!(
            reward_balance(receiver_addr) == vesting1_net_reward + vesting2_net_reward,
            6
        );
        assert!(
            vault_balance_after == vault_balance_before - reward_balance(receiver_addr),
            7
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
    fun lock_stake_vesting_position(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires TestState {
        let receiver_addr = signer::address_of(receiver);
        initialize(chain, vip, operator);
        coin::transfer(
            chain,
            receiver_addr,
            usdc_metadata(),
            1_000_000
        );
        let (stages, merkle_proofs, l2_scores) = reset_claim_args();
        // submit snapshot of stage 1; total score: 1000, receiver's score : 100
        // stage 1 snapshot submitted
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        assert!(vip::get_last_submitted_stage(1, get_version()) == 1, 2);
        // stage 2
        // total score: 1000, receiver's score : 500
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            500,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        assert!(reward_balance(receiver_addr) == 0, 3);

        vip::batch_claim_user_reward_script(
            receiver,
            get_bridge_id(),
            get_version(),
            stages,
            merkle_proofs,
            l2_scores
        );

        let remaining_reward =
            vesting::get_user_vesting_remaining(receiver_addr, get_bridge_id(), 1, 1);
        // lock stake stage 1 vesting position; remaining reward: (stage_reward) * 100 / 1000
        // without waiting the challenge period
        vip::lock_stake_script(
            receiver,
            1,
            get_version(),
            get_lp_metadata(),
            option::none(),
            get_validator(),
            1,
            remaining_reward,
            usdc_metadata(),
            1_000_000,
            option::none()
        );
        assert!(
            !vesting::has_user_vesting_position(receiver_addr, get_bridge_id(), 1, 1),
            5
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
    fun lock_stake_vesting_position_in_challenge_period(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires TestState {
        let receiver_addr = signer::address_of(receiver);
        initialize(chain, vip, operator);
        coin::transfer(
            chain,
            receiver_addr,
            usdc_metadata(),
            1_000_000
        );
        let (stages, merkle_proofs, l2_scores) = reset_claim_args();
        // submit snapshot of stage 1; total score: 1000, receiver's score : 100
        // stage 1 snapshot submitted
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // create stage 1 vesting position
        vip::batch_claim_user_reward_script(
            receiver,
            get_bridge_id(),
            get_version(),
            stages,
            merkle_proofs,
            l2_scores
        );

        // submit snapshot of stage 2; total score: 1000, receiver's score : 100
        // stage 2 snapshot submitted
        vip::fund_reward_script(vip);
        let test_state = borrow_global_mut<TestState>(@vip);
        test_state.last_submitted_stage = test_state.last_submitted_stage + 1;
        let stage = test_state.last_submitted_stage;
        let (merkle_root, _) = get_merkle_root_and_proof(stage, receiver_addr, 100, 1000);
        vip::submit_snapshot(
            vip,
            get_bridge_id(),
            get_version(),
            stage,
            merkle_root,
            1000
        );
        assert!(vip::get_last_submitted_stage(1, get_version()) == 2, 2);

        let remaining_reward =
            vesting::get_user_vesting_remaining(receiver_addr, get_bridge_id(), 1, 1);
        // lock stake stage 1 vesting position; remaining reward: (stage_reward) * 100 / 1000
        // without waiting the challenge period of vesting position2
        vip::lock_stake_script(
            receiver,
            1,
            get_version(),
            get_lp_metadata(),
            option::none(),
            get_validator(),
            1,
            remaining_reward,
            usdc_metadata(),
            1_000_000,
            option::none()
        );
        assert!(
            !vesting::has_user_vesting_position(receiver_addr, get_bridge_id(), 1, 1),
            5
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
    #[expected_failure(abort_code = 0xC0021, location = vip)]
    fun fail_lock_stake_vesting_position_without_claim(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires TestState {
        let receiver_addr = signer::address_of(receiver);
        initialize(chain, vip, operator);
        coin::transfer(
            chain,
            receiver_addr,
            usdc_metadata(),
            1_000_000
        );
        let (stages, merkle_proofs, l2_scores) = reset_claim_args();
        // submit snapshot of stage 1; total score: 1000, receiver's score : 100
        // stage 1 snapshot submitted
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // create stage 1 vesting position
        vip::batch_claim_user_reward_script(
            receiver,
            get_bridge_id(),
            get_version(),
            stages,
            merkle_proofs,
            l2_scores
        );

        assert!(vip::get_last_submitted_stage(1, get_version()) == 1, 2);
        // stage 2
        // total score: 1000, receiver's score : 500
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            500,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        assert!(reward_balance(receiver_addr) == 0, 3);
        let remaining_reward =
            vesting::get_user_vesting_remaining(receiver_addr, get_bridge_id(), 1, 1);
        let vault_balance_before = vault::balance();
        // lock stake stage 1 vesting position; remaining reward: (stage_reward) * 100 / 1000
        // without waiting the challenge period
        vip::lock_stake_script(
            receiver,
            1,
            get_version(),
            get_lp_metadata(),
            option::none(),
            get_validator(),
            1,
            remaining_reward,
            usdc_metadata(),
            1_000_000,
            option::none()
        );

        assert!(reward_balance(receiver_addr) == 0, 4);

        assert!(
            vault::balance() == vault_balance_before - remaining_reward,
            5
        )
    }

    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun test_submit_snapshot_and_fund_reward_with_deregistered_bridge(
        chain: &signer, vip: &signer, operator: &signer
    ) {
        initialize(chain, vip, operator);
        vip::fund_reward_script(vip); // stage 1 distributed
        skip_period(TEST_STAGE_INTERVAL + 1);
        vip::fund_reward_script(vip); // stage 2 distributed
        vip::deregister(vip, get_bridge_id());

        let (stage1_merkle_root, _) =
            get_merkle_root_and_proof(1, signer::address_of(vip), 100, 1000);
        vip::submit_snapshot(
            vip,
            get_bridge_id(),
            get_version(),
            1,
            stage1_merkle_root,
            1000
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
    fun e2e_re_registered_bridge_reward(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires TestState {
        initialize(chain, vip, operator);
        let receiver_addr = signer::address_of(receiver);
        let vesting_period = get_vesting_period();
        let vault_balance_before = vault::balance();
        coin::transfer(
            chain,
            receiver_addr,
            usdc_metadata(),
            100_000_000
        );
        let (stages, merkle_proofs, l2_scores) = reset_claim_args();
        // submit snapshot of stage 1; total score: 1000, receiver's score : 100
        // stage 1 snapshot submitted
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 2
        // total score: 1000, receiver's score : 500
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            500,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // deregister bridge
        vip::deregister(vip, get_bridge_id());

        // stage 1,2 claim on version 1
        vip::batch_claim_user_reward_script(
            receiver,
            get_bridge_id(),
            get_version(),
            stages,
            merkle_proofs,
            l2_scores
        );

        // stage3 distributed
        fund_reward(
            vip,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );

        // bridge 1 re-registered on stage 4 with version 2
        vip::register(
            vip,
            signer::address_of(operator),
            get_bridge_id(),
            get_bridge_address(),
            string::utf8(b"contract"),
            bigdecimal::from_ratio_u64(1, 2),
            bigdecimal::from_ratio_u64(1, 2),
            bigdecimal::from_ratio_u64(1, 2),
            get_vm_type()
        );

        assert!(vip::get_bridge_init_stage(get_bridge_id()) == 5, 1);

        // stage4 distributed
        fund_reward(
            vip,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        (stages, merkle_proofs, l2_scores) = reset_claim_args();
        // stage 5
        // total score: 1000, receiver's score : 100
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version() + 1,
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );

        // stage 5 claim on version 2
        vip::batch_claim_user_reward_script(
            receiver,
            get_bridge_id(),
            get_version() + 1,
            stages,
            merkle_proofs,
            l2_scores
        );

        assert!(
            vesting::get_user_last_claimed_stage(receiver_addr, 1, 2) == 5,
            2
        );
        assert!(
            vesting::has_user_vesting_position(receiver_addr, 1, 1, 2),
            3
        );
        let vesting1_initial_reward =
            vesting::get_user_vesting_initial_reward(receiver_addr, get_bridge_id(), 1, 1);
        let vault_balance_after = vault::balance();

        // stage 1 vested reward(stage 2)
        assert!(
            reward_balance(receiver_addr) == (vesting1_initial_reward / vesting_period),
            4
        );
        // claim no reward of vesting2 position; vault balance reduce only amount of claim reward
        assert!(
            vault_balance_after == vault_balance_before - reward_balance(receiver_addr),
            5
        );

        let vesting5_remaining_reward =
            vesting::get_user_vesting_remaining_reward(
                receiver_addr, get_bridge_id(), 2, 5
            );

        // lock stake position of stage 1
        vip::lock_stake_script(
            receiver,
            get_bridge_id(),
            get_version(),
            get_lp_metadata(),
            option::none(),
            get_validator(),
            1,
            vesting5_remaining_reward, // lock staking amount
            usdc_metadata(),
            vesting5_remaining_reward, // lock staking amount
            option::none()
        );
        skip_period(2);
        // lock stake position of stage 5
        vip::lock_stake_script(
            receiver,
            get_bridge_id(),
            get_version() + 1,
            get_lp_metadata(),
            option::none(),
            get_validator(),
            5,
            vesting5_remaining_reward, // lock staking amount
            usdc_metadata(),
            vesting5_remaining_reward, // lock staking amount
            option::none()
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
    #[expected_failure(abort_code = 0x60006, location = vip)]
    fun fail_calim_deregistered_bridge_reward(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires TestState {
        initialize(chain, vip, operator);
        let receiver_addr = signer::address_of(receiver);
        let (stages, merkle_proofs, l2_scores) = reset_claim_args();
        // submit snapshot of stage 1; total score: 1000, receiver's score : 100
        // stage 1 snapshot submitted
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 2
        // total score: 1000, receiver's score : 500
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            500,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // deregister bridge
        vip::deregister(vip, get_bridge_id());
        // stage3 distributed
        fund_reward(
            vip,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        vip::batch_claim_user_reward_script(
            receiver,
            get_bridge_id(),
            get_version(),
            stages,
            merkle_proofs,
            l2_scores
        );
    }

    //
    // User Lock Staking
    //
    // after lock staking, remaining reward < vesting reward per stage
    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun partial_lock_stake_scene1(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires TestState {
        initialize(chain, vip, operator);
        let receiver_addr = signer::address_of(receiver);
        let vault_balance_before = vault::balance();
        coin::transfer(
            chain,
            receiver_addr,
            usdc_metadata(),
            100_000_000
        );
        let (stages, merkle_proofs, l2_scores) = reset_claim_args();
        // stage 1 distributed
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            20,
            100,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 2 distributed
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            20,
            100,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );

        // stage 1,2 claimed
        vip::batch_claim_user_reward_script(
            receiver,
            get_bridge_id(),
            get_version(),
            stages,
            merkle_proofs,
            l2_scores
        );
        let vesting1_initial_reward =
            vesting::get_user_vesting_initial_reward(receiver_addr, get_bridge_id(), 1, 1);
        let vesting2_initial_reward =
            vesting::get_user_vesting_initial_reward(receiver_addr, get_bridge_id(), 1, 2);
        assert!(
            reward_balance(receiver_addr)
                == vesting1_initial_reward / get_vesting_period(),
            1
        );
        // stage 1 clean up
        vector::remove(&mut stages, 0);
        vector::remove(&mut merkle_proofs, 0);
        vector::remove(&mut l2_scores, 0);
        // stage 2 clean up
        vector::remove(&mut stages, 0);
        vector::remove(&mut merkle_proofs, 0);
        vector::remove(&mut l2_scores, 0);

        let extra = 1000;
        let lock_staking_amount = 8 * vesting1_initial_reward / get_vesting_period()
            + extra;
        // lock stake stage 1 vesting position
        vip::lock_stake_script(
            receiver,
            get_bridge_id(),
            get_version(),
            get_lp_metadata(),
            option::none(),
            get_validator(),
            1,
            lock_staking_amount,
            usdc_metadata(),
            lock_staking_amount,
            option::none()
        );
        // stage 1 vesting position lock staked but not finalized yet
        assert!(
            vesting::has_user_vesting_position(receiver_addr, get_bridge_id(), 1, 1),
            2
        );
        // stage 3 distributed
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            5,
            100,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        vip::batch_claim_user_reward_script(
            receiver,
            get_bridge_id(),
            get_version(),
            stages,
            merkle_proofs,
            l2_scores
        );
        assert!(
            reward_balance(receiver_addr)
                == (3 * vesting1_initial_reward) / (2 * get_vesting_period())
                    + vesting2_initial_reward / (2 * get_vesting_period()),
            4
        );
        // stage 1 vesting position finalized
        assert!(
            !vesting::has_user_vesting_position(receiver_addr, get_bridge_id(), 1, 1),
            5
        );
        let vesting1_penalty_reward =
            vesting1_initial_reward / (2 * get_vesting_period()) - extra; // 50% vesting amount per stage; extra is lock staked
        let vesting2_penalty_reward = vesting2_initial_reward
            / (2 * get_vesting_period()); // 50% vesting amount per stage
        vesting::get_user_vesting_penalty_reward(receiver_addr, get_bridge_id(), 1, 2);
        let vesting2_remaining_reward =
            vesting::get_user_vesting_remaining_reward(
                receiver_addr, get_bridge_id(), 1, 2
            );
        let net_vested1 = vesting1_initial_reward - vesting1_penalty_reward;
        let net_vested2 =
            vesting2_initial_reward - vesting2_remaining_reward
                - vesting2_penalty_reward;
        assert!(
            net_vested1 + net_vested2 == vault_balance_before - vault::balance(),
            7
        )
    }

    // after lock staking, remaining reward >= vesting reward per stage
    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun partial_lock_stake_scene2(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires TestState {
        initialize(chain, vip, operator);
        let receiver_addr = signer::address_of(receiver);
        coin::transfer(
            chain,
            receiver_addr,
            usdc_metadata(),
            100_000_000
        );
        let (stages, merkle_proofs, l2_scores) = reset_claim_args();
        // stage 1 distributed
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            10,
            100,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 2 distributed
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            20,
            100,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 1,2 claimed
        vip::batch_claim_user_reward_script(
            receiver,
            get_bridge_id(),
            get_version(),
            stages,
            merkle_proofs,
            l2_scores
        );
        // stage 1 clean up
        vector::remove(&mut stages, 0);
        vector::remove(&mut merkle_proofs, 0);
        vector::remove(&mut l2_scores, 0);
        // stage 2 clean up
        vector::remove(&mut stages, 0);
        vector::remove(&mut merkle_proofs, 0);
        vector::remove(&mut l2_scores, 0);

        let vesting1_initial_reward =
            vesting::get_user_vesting_initial_reward(receiver_addr, get_bridge_id(), 1, 1);
        let lock_staking_amount = 7 * vesting1_initial_reward / get_vesting_period()
            + 100;
        // lock stake stage 1 vesting position
        vip::lock_stake_script(
            receiver,
            get_bridge_id(),
            get_version(),
            get_lp_metadata(),
            option::none(),
            get_validator(),
            1,
            lock_staking_amount,
            usdc_metadata(),
            lock_staking_amount,
            option::none()
        );
        // stage 1 vesting position lock staked but not finalized yet
        assert!(
            vesting::has_user_vesting_position(receiver_addr, get_bridge_id(), 1, 1),
            1
        );
        // stage 3 distributed
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            40,
            100,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 3 claimed
        vip::batch_claim_user_reward_script(
            receiver,
            get_bridge_id(),
            get_version(),
            stages,
            merkle_proofs,
            l2_scores
        );
        // stage 3 clean up
        vector::remove(&mut stages, 0);
        vector::remove(&mut merkle_proofs, 0);
        vector::remove(&mut l2_scores, 0);

        // stage 1 vesting position finalized not yet
        assert!(
            vesting::has_user_vesting_position(receiver_addr, get_bridge_id(), 1, 1),
            2
        );
        // stage 4 distributed
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            40,
            100,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );

        vip::batch_claim_user_reward_script(
            receiver,
            get_bridge_id(),
            get_version(),
            stages,
            merkle_proofs,
            l2_scores
        );
        // stage 1 vesting position finalized
        assert!(
            !vesting::has_user_vesting_position(receiver_addr, get_bridge_id(), 1, 1),
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
    fun lock_stake_deregistered_bridge_vesting_positions(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires TestState {
        initialize(chain, vip, operator);
        let receiver_addr = signer::address_of(receiver);
        coin::transfer(
            chain,
            receiver_addr,
            usdc_metadata(),
            1_000_000
        );
        let (stages, merkle_proofs, l2_scores) = reset_claim_args();

        // submit snapshot of stage 1; total score: 1000, receiver's score : 100
        // stage 1 snapshot submitted
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );

        // minitia submits the snapshot but deregistered by gov.
        vip::deregister(vip, get_bridge_id());

        // create user reward position of stage 1
        vip::batch_claim_user_reward_script(
            receiver,
            get_bridge_id(),
            get_version(),
            stages,
            merkle_proofs,
            l2_scores
        );

        let initial_reward =
            vesting::get_user_vesting_initial_reward(
                signer::address_of(receiver),
                get_bridge_id(),
                1,
                1
            );
        // user can only lock stake the deregisterd minitia positions
        vip::lock_stake_script(
            receiver,
            get_bridge_id(),
            get_version(),
            get_lp_metadata(),
            option::none(),
            get_validator(),
            1,
            initial_reward,
            usdc_metadata(),
            1000_000,
            option::none()
        )
    }

    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun lock_stake_re_registered_bridge_reward(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires TestState {
        initialize(chain, vip, operator);
        let receiver_addr = signer::address_of(receiver);

        coin::transfer(
            chain,
            receiver_addr,
            usdc_metadata(),
            1_000_000_00
        );
        let (stages, merkle_proofs, l2_scores) = reset_claim_args();

        // submit snapshot of stage 1; total score: 1000, receiver's score : 100
        // stage 1 snapshot submitted
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );

        // stage 1 claim & lock stake
        vip::batch_claim_user_reward_script(
            receiver,
            get_bridge_id(),
            get_version(),
            vector[vector::remove(&mut stages, 0)],
            vector[vector::remove(&mut merkle_proofs, 0)],
            vector[vector::remove(&mut l2_scores, 0)]
        );
        let vesting1_initial_reward =
            vesting::get_user_vesting_initial_reward(receiver_addr, get_bridge_id(), 1, 1);
        // user can only lock stake the deregisterd minitia positions
        vip::lock_stake_script(
            receiver,
            get_bridge_id(),
            get_version(),
            get_lp_metadata(),
            option::none(),
            get_validator(),
            1,
            vesting1_initial_reward,
            usdc_metadata(),
            vesting1_initial_reward, // usdc amount 1:1
            option::none()
        );

        let vault_balance_before = vault::balance();
        // stage 2
        // total score: 1000, receiver's score : 500
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            500,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 1,2 claim on version 1
        vip::batch_claim_user_reward_script(
            receiver,
            get_bridge_id(),
            get_version(),
            stages,
            merkle_proofs,
            l2_scores
        );
        // deregister bridge
        vip::deregister(vip, get_bridge_id());
        // stage3 distributed
        fund_reward(
            vip,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // bridge 1 re-registered on stage 4
        vip::register(
            vip,
            signer::address_of(operator),
            get_bridge_id(),
            get_bridge_address(),
            string::utf8(b"contract"),
            bigdecimal::from_ratio_u64(1, 2),
            bigdecimal::from_ratio_u64(1, 2),
            bigdecimal::from_ratio_u64(1, 2),
            get_vm_type()
        );
        // stage4 distributed
        fund_reward(
            vip,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        (stages, merkle_proofs, l2_scores) = reset_claim_args();
        // stage 5
        // total score: 1000, receiver's score : 100
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version() + 1,
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );

        // stage 5 claim on version 2
        vip::batch_claim_user_reward_script(
            receiver,
            get_bridge_id(),
            get_version() + 1,
            stages,
            merkle_proofs,
            l2_scores
        );

        assert!(
            vesting::get_user_last_claimed_stage(receiver_addr, 1, 2) == 5,
            1
        );
        assert!(
            !vesting::has_user_vesting_position(receiver_addr, 1, 1, 1),
            2
        );

        // stage 2 vested reward(5; 40% one time)
        assert!(reward_balance(receiver_addr) == 0, 3);
        // claim no reward of vesting2 position; vault balance reduced only by amount of claim reward
        assert!(
            vault::balance() == vault_balance_before - reward_balance(receiver_addr),
            4
        )
    }

    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun test_batch_lock_stake(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires TestState {
        initialize(chain, vip, operator);
        let receiver_addr = signer::address_of(receiver);
        coin::transfer(
            chain,
            receiver_addr,
            usdc_metadata(),
            1_000_000_000
        );
        let (stages, merkle_proofs, l2_scores) = reset_claim_args();
        // submit snapshot of stage 1; total score: 1000, receiver's score : 100
        // stage 1 snapshot submitted
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 2
        // total score: 1000, receiver's score : 500
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            500,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 3
        // total score: 1000, receiver's score : 200
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            200,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );

        // stage 4
        // total score: 1000, receiver's score : 100
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // claim stage 1,2,3,4
        vip::batch_claim_user_reward_script(
            receiver,
            get_bridge_id(),
            get_version(),
            stages,
            merkle_proofs,
            l2_scores
        );
        let stage = 1;
        let lock_staking_amounts = vector::empty<u64>();
        let stakelisted_amount: u64 = 0;
        let stakelist_metadatas = vector::empty<Object<Metadata>>();
        while (stage < 5) {
            let remaining =
                vesting::get_user_vesting_remaining(
                    receiver_addr, get_bridge_id(), 1, stage
                );
            vector::push_back(&mut lock_staking_amounts, remaining);
            stakelisted_amount = stakelisted_amount + remaining;
            vector::push_back(&mut stakelist_metadatas, usdc_metadata());
            stage = stage + 1;
        };

        vip::batch_lock_stake_script(
            receiver,
            get_bridge_id(),
            get_version(),
            get_lp_metadata(),
            option::none(),
            get_validator(),
            stages,
            lock_staking_amounts,
            usdc_metadata(),
            stakelisted_amount,
            option::none()
        );

        stage = 1;
        while (stage < 5) {
            assert!(
                !vesting::has_user_vesting_position(
                    receiver_addr, get_bridge_id(), 1, stage
                ),
                1
            );
            stage = stage + 1;
        };
    }

    //
    // Operator Claim
    //
    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun claim_operator_reward(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires TestState {
        initialize(chain, vip, operator);
        let operator_addr = signer::address_of(operator);
        let receiver_addr = signer::address_of(receiver);

        let (stages, merkle_proofs, l2_scores) = reset_claim_args();
        // submit snapshot of stage 1; total score: 1000, receiver's score : 100
        // stage 1 snapshot submitted
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 2
        // total score: 1000, receiver's score : 500
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            500,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 3
        // total score: 1000, receiver's score : 200
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            200,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 1,2,3 operator claim
        vip::batch_claim_operator_reward_script(operator, get_bridge_id(), get_version());

        let vesting1_initial_reward =
            vesting::get_operator_vesting_initial_reward(get_bridge_id(), 1, 1);
        let vesting1_remaining_reward =
            vesting::get_operator_vesting_remaining_reward(get_bridge_id(), 1, 1);
        let vesting2_initial_reward =
            vesting::get_operator_vesting_initial_reward(get_bridge_id(), 1, 2);
        let vesting2_remaining_reward =
            vesting::get_operator_vesting_remaining_reward(get_bridge_id(), 1, 2);
        assert!(
            vesting1_remaining_reward
                == (get_vesting_period() - 2) * vesting1_initial_reward
                    / get_vesting_period(),
            1
        );
        assert!(
            vesting2_remaining_reward
                == (get_vesting_period() - 1) * vesting2_initial_reward
                    / get_vesting_period(),
            2
        );
        assert!(
            reward_balance(operator_addr)
                == vesting2_initial_reward / get_vesting_period()
                    + 2 * vesting1_initial_reward / get_vesting_period(),
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
    fun claim_operator_reward_re_registerd_bridge(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires TestState {
        initialize(chain, vip, operator);
        let receiver_addr = signer::address_of(receiver);
        let operator_addr = signer::address_of(operator);
        let vesting_period = get_vesting_period();
        assert!(vip::get_bridge_init_stage(get_bridge_id()) == 1, 1);
        let (stages, merkle_proofs, l2_scores) = reset_claim_args();
        // submit snapshot of stage 1; total score: 1000, receiver's score : 100
        // stage 1 snapshot submitted
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 2
        // total score: 1000, receiver's score : 500
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            500,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );

        // deregister bridge
        vip::deregister(vip, get_bridge_id());
        // stage3 distributed
        fund_reward(
            vip,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // bridge 1 re-registered on stage 4
        vip::register(
            vip,
            signer::address_of(operator),
            get_bridge_id(),
            get_bridge_address(),
            string::utf8(b"contract"),
            bigdecimal::from_ratio_u64(1, 2),
            bigdecimal::from_ratio_u64(1, 2),
            bigdecimal::from_ratio_u64(1, 2),
            get_vm_type()
        );
        assert!(vip::get_bridge_init_stage(get_bridge_id()) == 5, 1);
        // stage4 distributed
        fund_reward(
            vip,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );

        // stage 5
        // total score: 1000, receiver's score : 100
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version() + 1,
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        let vault_balance_before = vault::balance();

        // stage 1,2 on version 1
        vip::batch_claim_operator_reward_script(operator, get_bridge_id(), get_version());
        // stage 5 on version 2
        vip::batch_claim_operator_reward_script(
            operator, get_bridge_id(), get_version() + 1
        );
        assert!(
            vesting::get_operator_last_claimed_stage(get_bridge_id(), 2) == 5,
            2
        );

        let vesting1_initial_reward =
            vesting::get_operator_vesting_initial_reward(get_bridge_id(), 1, 1);
        let vault_balance_after = vault::balance();
        // stage 1 vesting reward(2)
        assert!(
            reward_balance(operator_addr) == ((vesting1_initial_reward)
                / (vesting_period)),
            3
        );
        // claim no reward of vesting2 position; vault balance reduce only amount of claim reward
        assert!(
            vault_balance_after == vault_balance_before - reward_balance(operator_addr),
            4
        )
    }

    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            new_operator = @0x5,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun claim_new_operator_reward(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer,
        new_operator: &signer
    ) acquires TestState {
        initialize(chain, vip, operator);
        let operator_addr = signer::address_of(operator);
        let new_operator_addr = signer::address_of(new_operator);
        let receiver_addr = signer::address_of(receiver);

        let (stages, merkle_proofs, l2_scores) = reset_claim_args();
        // submit snapshot of stage 1; total score: 1000, receiver's score : 100
        // stage 1 snapshot submitted
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 2
        // total score: 1000, receiver's score : 500
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            500,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );

        // stage 1,2 operator claim
        vip::batch_claim_operator_reward_script(operator, get_bridge_id(), get_version());

        // update operator
        vip::update_operator(operator, get_bridge_id(), new_operator_addr);

        // stage 3
        // total score: 1000, receiver's score : 200
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            200,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );

        // stage 4
        // total score: 1000, receiver's score : 200
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            200,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );

        // stage 3,4  claimed by new operator
        vip::batch_claim_operator_reward_script(
            new_operator, get_bridge_id(), get_version()
        );

        let vesting1_initial_reward =
            vesting::get_operator_vesting_initial_reward(get_bridge_id(), 1, 1);
        let vesting1_remaining_reward =
            vesting::get_operator_vesting_remaining_reward(get_bridge_id(), 1, 1);
        let vesting2_initial_reward =
            vesting::get_operator_vesting_initial_reward(get_bridge_id(), 1, 2);
        let vesting2_remaining_reward =
            vesting::get_operator_vesting_remaining_reward(get_bridge_id(), 1, 2);
        let vesting3_initial_reward =
            vesting::get_operator_vesting_initial_reward(get_bridge_id(), 1, 3);

        assert!(
            vesting1_remaining_reward
                == (get_vesting_period() - 3) * vesting1_initial_reward
                    / get_vesting_period(),
            1
        );
        assert!(
            vesting2_remaining_reward
                == (get_vesting_period() - 2) * vesting2_initial_reward
                    / get_vesting_period(),
            2
        );
        assert!(
            reward_balance(operator_addr)
                == vesting1_initial_reward / get_vesting_period(),
            3
        );

        assert!(
            reward_balance(new_operator_addr)
                == 2 * vesting1_initial_reward / get_vesting_period()
                    + 2 * vesting2_initial_reward / get_vesting_period()
                    + vesting3_initial_reward / get_vesting_period(),
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
    fun e2e_bridge_reward(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires TestState {
        // stage 1 distributed
        initialize(chain, vip, operator);
        let receiver_addr = signer::address_of(receiver);
        coin::transfer(
            chain,
            receiver_addr,
            usdc_metadata(),
            100_000_000
        );
        let (bridge1_stages, bridge1_merkle_proofs, bridge1_l2_scores) =
            reset_claim_args();
        let (bridge2_stages, bridge2_merkle_proofs, bridge2_l2_scores) =
            reset_claim_args();
        // submit snapshot of stage 1(bridge id: 1, 2); total score: 1000, receiver's score : 100
        // stage 1 snapshot submitted. stage 2 distributed
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut bridge1_stages,
            &mut bridge1_merkle_proofs,
            &mut bridge1_l2_scores
        );
        submit_snapshot(
            vip,
            get_bridge2_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut bridge2_stages,
            &mut bridge2_merkle_proofs,
            &mut bridge2_l2_scores
        );
        let user_distributed_reward1 = vip::get_user_funded_reward(get_bridge_id(), 2);
        let user_distributed_reward2 = vip::get_user_funded_reward(get_bridge2_id(), 2);
        let operator_distributed_reward1 =
            vip::get_operator_funded_reward(get_bridge_id(), 2);
        let operator_distributed_reward2 =
            vip::get_operator_funded_reward(get_bridge2_id(), 2);
        // same weight and same tvl
        assert!(user_distributed_reward1 == user_distributed_reward2, 1);
        assert!(operator_distributed_reward1 == operator_distributed_reward2, 1);
        // stage 2
        // weight 0.6 : 0.4
        // total score: 1000, receiver's score : 500
        // total score: 1000, receiver's score : 250
        vip::update_vip_weights(
            chain,
            vector[get_bridge_id(), get_bridge2_id()],
            vector[bigdecimal::from_ratio_u64(3, 5), bigdecimal::from_ratio_u64(2, 5)]
        );

        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            500,
            1000,
            &mut bridge1_stages,
            &mut bridge1_merkle_proofs,
            &mut bridge1_l2_scores
        );

        submit_snapshot(
            vip,
            get_bridge2_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut bridge2_stages,
            &mut bridge2_merkle_proofs,
            &mut bridge2_l2_scores
        );
        // voting weight 0.6 : 0.4
        // tvl ratio 0.5: 0.5
        // if total reward is 100
        // weight is 0.6 * 0.5 + 0.5 * 0.5 : 0.4 * 0.5 + 0.5 * 0.5
        // => 0.55 : 0.45
        // max_weight_ratio is 0.5 so cut 0.55 to 0.5
        // 0.5 : 0.45
        // reward amount 50 : 45
        user_distributed_reward1 = vip::get_user_funded_reward(get_bridge_id(), 3);
        user_distributed_reward2 = vip::get_user_funded_reward(get_bridge2_id(), 3);
        operator_distributed_reward1 = vip::get_operator_funded_reward(
            get_bridge_id(), 3
        );
        operator_distributed_reward2 = vip::get_operator_funded_reward(
            get_bridge2_id(), 3
        );
        assert!(
            user_distributed_reward1 * 45 == user_distributed_reward2 * 50,
            2
        );
        assert!(
            operator_distributed_reward1 * 45 == operator_distributed_reward2 * 50,
            2
        );

        // stage3
        // total score: 1000, receiver's score : 200
        // total score: 1000, receiver's score : 400
        vip::update_vip_weights(
            chain,
            vector[get_bridge_id(), get_bridge2_id()],
            vector[
                bigdecimal::from_ratio_u64(3, 10),
                bigdecimal::from_ratio_u64(7, 10)
            ]
        );
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            200,
            1000,
            &mut bridge1_stages,
            &mut bridge1_merkle_proofs,
            &mut bridge1_l2_scores
        );

        submit_snapshot(
            vip,
            get_bridge2_id(),
            get_version(),
            receiver_addr,
            400,
            1000,
            &mut bridge2_stages,
            &mut bridge2_merkle_proofs,
            &mut bridge2_l2_scores
        );

        // voting weight 0.7 : 0.3
        // tvl ratio 0.5: 0.5
        // if total reward is 100
        // weight is 0.7 * 0.5 + 0.5 * 0.5 : 0.3 * 0.5 + 0.5 * 0.5
        // => 0.6 : 0.4
        // max_weight_ratio is 0.5 so cut 0.6 to 0.4
        // 0.5 : 0.4
        // reward amount 50 : 40
        user_distributed_reward1 = vip::get_user_funded_reward(get_bridge_id(), 4);
        user_distributed_reward2 = vip::get_user_funded_reward(get_bridge2_id(), 4);
        operator_distributed_reward1 = vip::get_operator_funded_reward(
            get_bridge_id(), 4
        );
        operator_distributed_reward2 = vip::get_operator_funded_reward(
            get_bridge2_id(), 4
        );
        assert!(
            user_distributed_reward1 * 50 == user_distributed_reward2 * 40,
            2
        );
        assert!(
            operator_distributed_reward1 * 50 == operator_distributed_reward2 * 40,
            2
        );

        // check min eligible tvl
        vip::update_params(
            vip,
            option::none(),
            option::none(),
            option::none(),
            option::some(100_000_001), // update min eligible tvl
            option::none(),
            option::none(),
            option::none(),
            option::none(),
            option::none()
        );

        // stage 5
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            200,
            1000,
            &mut bridge1_stages,
            &mut bridge1_merkle_proofs,
            &mut bridge1_l2_scores
        );

        submit_snapshot(
            vip,
            get_bridge2_id(),
            get_version(),
            receiver_addr,
            400,
            1000,
            &mut bridge2_stages,
            &mut bridge2_merkle_proofs,
            &mut bridge2_l2_scores
        );

        user_distributed_reward1 = vip::get_user_funded_reward(get_bridge_id(), 5);
        user_distributed_reward2 = vip::get_user_funded_reward(get_bridge2_id(), 5);
        assert!(user_distributed_reward1 == 0, 2);
        assert!(user_distributed_reward2 == 0, 2);

        // transfer some coin to bridge_id()
        coin::transfer(
            chain,
            get_bridge_address(),
            vault::reward_metadata(),
            1
        );

        // stage 6
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            200,
            1000,
            &mut bridge1_stages,
            &mut bridge1_merkle_proofs,
            &mut bridge1_l2_scores
        );

        submit_snapshot(
            vip,
            get_bridge2_id(),
            get_version(),
            receiver_addr,
            400,
            1000,
            &mut bridge2_stages,
            &mut bridge2_merkle_proofs,
            &mut bridge2_l2_scores
        );

        user_distributed_reward1 = vip::get_user_funded_reward(get_bridge_id(), 6);
        user_distributed_reward2 = vip::get_user_funded_reward(get_bridge2_id(), 6);
        assert!(user_distributed_reward1 == 20000000, 2);
        assert!(user_distributed_reward2 == 0, 2);
    }

    // Stable swap lock staking
    #[
        test(
            chain = @0x1,
            vip = @vip,
            operator = @0x56ccf33c45b99546cd1da172cf6849395bbf8573,
            receiver = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun test_batch_stableswap_lock_stake(
        chain: &signer,
        vip: &signer,
        operator: &signer,
        receiver: &signer
    ) acquires TestState {
        initialize(chain, vip, operator);
        let receiver_addr = signer::address_of(receiver);
        coin::transfer(
            chain,
            receiver_addr,
            usdc_metadata(),
            1_000_000_000
        );
        let (stages, merkle_proofs, l2_scores) = reset_claim_args();
        // submit snapshot of stage 1; total score: 1000, receiver's score : 100
        // stage 1 snapshot submitted
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 2
        // total score: 1000, receiver's score : 500
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            500,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // stage 3
        // total score: 1000, receiver's score : 200
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            200,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );

        // stage 4
        // total score: 1000, receiver's score : 100
        submit_snapshot_and_fund_reward(
            vip,
            get_bridge_id(),
            get_version(),
            receiver_addr,
            100,
            1000,
            &mut stages,
            &mut merkle_proofs,
            &mut l2_scores
        );
        // claim stage 1,2,3,4
        vip::batch_claim_user_reward_script(
            receiver,
            get_bridge_id(),
            get_version(),
            stages,
            merkle_proofs,
            l2_scores
        );
        let stage = 1;
        let lock_staking_amounts = vector::empty<u64>();
        let stakelisted_amount: u64 = 0;
        let stakelist_metadatas = vector::empty<Object<Metadata>>();
        while (stage < 5) {
            let remaining =
                vesting::get_user_vesting_remaining(
                    receiver_addr, get_bridge_id(), 1, stage
                );
            vector::push_back(&mut lock_staking_amounts, remaining);
            stakelisted_amount = stakelisted_amount + remaining;
            vector::push_back(&mut stakelist_metadatas, usdc_metadata());
            stage = stage + 1;
        };

        vip::batch_stableswap_lock_stake_script(
            receiver,
            get_bridge_id(),
            get_version(),
            get_stable_lp_metadata(),
            option::none(),
            get_validator(),
            stages,
            lock_staking_amounts,
            option::none()
        );

        while (stage < 5) {
            assert!(
                !vesting::has_user_vesting_position(
                    receiver_addr, get_bridge_id(), 1, stage
                ),
                1
            );
            stage = stage + 1;
        };
    }
}
