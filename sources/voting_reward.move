module staking_addr::voting_reward {

    use std::error;
    use std::signer;
    use std::vector;

    use initia_std::bigdecimal;
    use initia_std::bigdecimal::BigDecimal;
    use initia_std::fungible_asset::Metadata;
    use initia_std::object::Object;
    use initia_std::primary_fungible_store;
    use initia_std::simple_map;
    use initia_std::simple_map::SimpleMap;

    use staking_addr::bribe;
    use staking_addr::cabal;
    use staking_addr::cabal_token;
    use staking_addr::emergency;
    use staking_addr::manager;
    use staking_addr::package;
    use staking_addr::snapshots;
    use staking_addr::utils;

    const EMODULE_OPERATION: u64 = 1;
    const EINVALID_REMAIN_AMOUNT: u64 = 2;
    const EPAUSED: u64 = 3;
    const EINVALID_CYCLE: u64 = 4;
    const EUNAUTHORIZED: u64 = 5;

    struct ModuleStore has key {
        cycle_snapshot_map: SimpleMap<u64, u64>,
    }

    struct SnapshotRecord has store {
        supply: u128,
        weight: BigDecimal,
    }

    fun init_module(account: &signer) {
        assert!(signer::address_of(account) == @staking_addr, error::unauthenticated(EMODULE_OPERATION));

        move_to(account, ModuleStore {
            cycle_snapshot_map: simple_map::new(),
        });
    }

    // View function to calculate the total accumulated (not necessarily claimed) rewards for a user across all cycles, broken down by token
    #[view]
    public fun get_total_reward_in_usd(claimer: address): BigDecimal acquires ModuleStore {
        let total_value = bigdecimal::zero();

        let rewards: SimpleMap<Object<Metadata>, u64> = get_total_reward(claimer);
        let metadatas = simple_map::keys(&rewards);
        for (i in 0..vector::length(&metadatas)) {
            let value = utils::get_token_value_in_usd(metadatas[i], *simple_map::borrow(&rewards, &metadatas[i]));
            total_value = bigdecimal::add(total_value, value);
        };

        total_value
    }

    // View function to calculate the total accumulated (not necessarily claimed) rewards for a user across all cycles, broken down by token
    #[view]
    public fun get_total_reward(claimer: address): SimpleMap<Object<Metadata>, u64> acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        let res: SimpleMap<Object<Metadata>, u64> = simple_map::new();

        // iter cycle reward
        let cycles= simple_map::keys(&m_store.cycle_snapshot_map);
        for (i in 0..vector::length(&cycles)) {
            let block_height = *simple_map::borrow(&m_store.cycle_snapshot_map, &cycles[i]);
            let reward_share = get_cycle_reward_share(claimer, block_height);

            // calculate reward
            let bribe_map = bribe::get_total_bribes_by_token_for_cycle(cycles[i]);
            let bribe_metas = simple_map::keys(&bribe_map);

            for (i in 0..vector::length(&bribe_metas)) {
                let bribe = *simple_map::borrow(&bribe_map, &bribe_metas[i]);
                let reward = bigdecimal::mul_by_u64_truncate(reward_share, bribe);

                if (!simple_map::contains_key(&res, &bribe_metas[i])) {
                    simple_map::add(&mut res, bribe_metas[i], reward);
                    continue;
                };

                let reward_ref = simple_map::borrow_mut(&mut res, &bribe_metas[i]);
                *reward_ref = *reward_ref + reward;
            };
        };

        res
    }

    // View function to calculate the total accumulated rewards (not necessarily claimed) for a user for a specific token
    #[view]
    public fun get_single_reward(claimer: address, reward_meta: Object<Metadata>): u64 acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        let total_reward = 0;

        // iter cycle reward
        let cycles= simple_map::keys(&m_store.cycle_snapshot_map);
        for (i in 0..vector::length(&cycles)) {
            let block_height = *simple_map::borrow(&m_store.cycle_snapshot_map, &cycles[i]);
            let reward_share = get_cycle_reward_share(claimer, block_height);

            // calculate reward
            let bribe_map = bribe::get_total_bribes_by_token_for_cycle(cycles[i]);
            if (!simple_map::contains_key(&bribe_map, &reward_meta)) {
                continue;
            };

            let bribe = *simple_map::borrow(&bribe_map, &reward_meta);
            let reward = bigdecimal::mul_by_u64_truncate(reward_share, bribe);

            total_reward = total_reward + reward;
        };

        total_reward
    }

    // view function to get the amount of unclaimed rewards for some token
    #[view]
    public fun get_unclaimed_voting_reward(account_addr: address, metadata: Object<Metadata>): u64  acquires ModuleStore{
        let amount = get_single_reward(account_addr, metadata);
        amount - cabal::get_claimed_voting_reward_amount(account_addr, metadata)
    }

    // Entry function for the admin to take a snapshot of the current state relevant for rewards calculations
    // Also calls snapshot for the user balances for distribution
    public entry fun snapshot(account: &signer) {
        // Only the manager should be able to call this
        assert!(manager::is_authorized(account), error::permission_denied(EUNAUTHORIZED));
        
        snapshots::snapshot();
        cabal_token::snapshot();
    }

    #[test_only]
    public fun mock_snapshot(account: &signer) {
        // same as the normal snapshot, however removes the call to the weights, as that deals with the vip module
        assert!(manager::is_authorized(account), error::permission_denied(EUNAUTHORIZED));

        snapshots::mock_snapshot();
        cabal_token::snapshot();
    }

    // Entry function for the admin to associate a specific snapshot (by block_height) with a reward cycle number
    // This marks the cycle as "distributed" and links it to the state captured at that block height
    public entry fun finalize_reward_cycle(account: &signer, cycle: u64, block_height: u64) acquires ModuleStore {
        emergency::assert_no_paused();

        // Only the manager should be able to call this
        assert!(manager::is_authorized(account), error::permission_denied(EUNAUTHORIZED));

        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);
        assert!(!simple_map::contains_key(&m_store.cycle_snapshot_map, &cycle), error::invalid_argument(EINVALID_CYCLE));

        simple_map::add(&mut m_store.cycle_snapshot_map, cycle, block_height);
    }

    public entry fun claim_voting_reward(account: &signer, metadata: Object<Metadata>) acquires ModuleStore {
        emergency::assert_no_paused();
        let account_addr = signer::address_of(account);
        cabal::ensure_cabal_store_exists(account);

        let amount = get_single_reward(account_addr, metadata);

        let remain_amount = amount - cabal::get_claimed_voting_reward_amount(account_addr, metadata);
        assert!(remain_amount > 0, error::invalid_state(EINVALID_REMAIN_AMOUNT));

        cabal::update_claimed_voting_reward_amount(account_addr, metadata, amount);

        // transfer reward token to user
        primary_fungible_store::transfer(
            &package::get_reward_store_signer(),
            metadata,
            account_addr,
            remain_amount
        )
    }

    // Internal helper function to calculate a user's weighted share of voting power for a specific snapshot
    // Sums up the user's share across all Cabal stake tokens
    fun get_cycle_reward_share(claimer: address, block_height: u64): BigDecimal {
        let stake_token_cabal_token_map = cabal::get_stake_token_cabal_token_map();
        let stake_tokens = simple_map::keys(&stake_token_cabal_token_map);
        let total_share = bigdecimal::zero();
        for (i in 0..vector::length(&stake_tokens)) {
            let cabal_meta = *simple_map::borrow(&stake_token_cabal_token_map, &stake_tokens[i]);
            let balance = cabal_token::get_snapshot_balance(claimer, cabal_meta, block_height);
            if (balance == 0) {
                continue;
            };
            let weight = snapshots::get_snapshot_weight(block_height, stake_tokens[i]);
            let supply = cabal_token::get_snapshot_supply(cabal_meta, block_height);
            let ratio = bigdecimal::from_ratio_u128((balance as u128), supply);
            let reward_share = bigdecimal::mul(ratio, weight);
            total_share = bigdecimal::add(total_share, reward_share);
        };

        total_share
    }

    #[test_only]
    public fun init_module_for_test(staking_addr: &signer) {
        init_module(staking_addr)
    }

    // Check if a cycle has been finalized
    #[view]
    #[test_only]
    public fun is_cycle_finalized(cycle: u64): bool acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        simple_map::contains_key(&m_store.cycle_snapshot_map, &cycle)
    }

    // Get number of finalized cycles
    #[view]
    #[test_only]
    public fun get_finalized_cycles_count(): u64 acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        simple_map::length(&m_store.cycle_snapshot_map)
    }
}