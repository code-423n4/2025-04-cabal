/// Pool Router handles interactions with the underlying validator
/// This implementation is designed for a single validator setup
module staking_addr::pool_router {
    use std::bcs;
    use std::error;
    use std::option;
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use initia_std::address;
    use initia_std::address::to_sdk;
    use initia_std::bigdecimal;
    use initia_std::bigdecimal::BigDecimal;

    use initia_std::block;
    use initia_std::coin;
    use initia_std::cosmos;
    use initia_std::fungible_asset;
    use initia_std::fungible_asset::{FungibleAsset, Metadata};
    use initia_std::json::{marshal, unmarshal};
    use initia_std::object;
    use initia_std::object::{ExtendRef, Object};
    use initia_std::primary_fungible_store;
    use initia_std::query::query_stargate;
    use initia_std::simple_map;
    use initia_std::simple_map::SimpleMap;
    use staking_addr::manager;
    use staking_addr::utils;
    use vip::lock_staking;
    use vip::weight_vote;


    friend staking_addr::cabal;

    // Error constants
    const EUNAUTHORIZED: u64 = 1;
    const EPOOL_NOT_FOUND: u64 = 2;
    const EUNSUPPORT_TOKEN: u64 = 3;

    // Constants
    const MAX_U64: u64 = 18_446_744_073_709_551_615u64; // u64 max at first
    const INIT_LOCK_INTERVAL: u64 = 2592000; // 60 * 60 * 24 * 30 (30 days);

    // Basic resource structure
    struct PoolRouter has key {
        // token -> pools
        token_pool_map: SimpleMap<Object<Metadata>, vector<Object<StakePool>>>,
    }

    struct StakePool has key {
        metadata: Object<Metadata>,
        amount: u64,
        ref: ExtendRef,
        validator: String
    }

    // msg

    struct Coin has drop, copy, store {
        denom: String,
        amount: u64,
    }

    struct MsgBeginRedelegate has drop {
        _type_: String,
        delegator_address: String,
        validator_src_address: String,
        validator_dst_address: String,
        amount: vector<Coin>,
    }

    struct MsgUndelegate has drop {
        _type_: String,
        delegator_address: String,
        validator_address: String,
        amount: vector<Coin>,
    }

    struct MsgWithdrawDelegatorReward has drop {
        _type_: String,
        delegator_address: String,
        validator_address: String,
    }

    struct DelegationRequest has copy, drop {
        validator_addr: String,
        delegator_addr: String,
    }

    struct DelegationResponse has drop, copy, store {
        delegation_response: DelegationResponseInner
    }

    struct DelegationResponseInner has drop, copy, store {
        delegation: Delegation,
        balance: vector<Coin>
    }

    struct Delegation has drop, copy, store {
        delegator_address: String,
        validator_address: String,
        shares: vector<DecCoin>
    }

    struct DecCoin has drop, copy, store {
        denom: String,
        amount: BigDecimal,
    }

    // Module initialization
    fun init_module(account: &signer) {
        assert!(signer::address_of(account) == @staking_addr, error::permission_denied(EUNAUTHORIZED));
        // Initialize the pool router...
        move_to(account, PoolRouter {
            token_pool_map: simple_map::new()
        })
    }

    // Admin function

    /// Add a new pool to the router
    public entry fun add_pool(account: &signer, metadata: Object<Metadata>, validator_address: String) acquires PoolRouter {
        
        // Only the manager should be able to call this
        assert!(manager::is_authorized(account), error::permission_denied(EUNAUTHORIZED));

        let router = borrow_global_mut<PoolRouter>(@staking_addr);

        if (!simple_map::contains_key(&router.token_pool_map, &metadata)) {
            simple_map::add(&mut router.token_pool_map, metadata, vector::empty());
        };
        let pools = simple_map::borrow_mut(&mut router.token_pool_map, &metadata);

        let constructor_ref = object::create_object(@staking_addr, false);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        move_to(&object::generate_signer(&constructor_ref), StakePool {
            metadata,
            amount: 0,
            ref: extend_ref,
            validator: validator_address
        });

        vector::push_back(pools, object::address_to_object<StakePool>(object::address_from_constructor_ref(&constructor_ref)));
    }

    /// Change a validator from the router
    public entry fun change_validator(admin: &signer, stake_pool: Object<StakePool>, new_validator_address: String) acquires StakePool {
        // Only the deployer address
        assert!(signer::address_of(admin) == @staking_addr, error::unauthenticated(EUNAUTHORIZED));
        let pool_addr = object::object_address(&stake_pool);
        let pool = borrow_global_mut<StakePool>(pool_addr);

        // redelegate
        if (pool.metadata == utils::get_init_metadata()) {
            redelegate_init(pool, new_validator_address);
        } else {
            redelegate_lp(pool, new_validator_address);
        };

        pool.validator = new_validator_address;
    }

    // Core functions for staking operations

    /// Add stake to the most underutilized validator
    public(friend) fun add_stake(fa: FungibleAsset) acquires PoolRouter, StakePool {
        // Find most underutilized validator
        let metadata = fungible_asset::metadata_from_asset(&fa);
        let amount= fungible_asset::amount(&fa);
        let pool_ob = get_most_underutilized_pool(metadata);
        let pool = borrow_global_mut<StakePool>(object::object_address(&pool_ob));

        // Delegate to validator via cosmos::delegate
        primary_fungible_store::deposit(object::address_from_extend_ref(&pool.ref), fa);
        if (metadata == utils::get_init_metadata()) {
            process_delegate_init(pool, amount);
        } else {
            process_delegate_lp(pool, amount);
        };

        // Update state tracking
        pool.amount = pool.amount + amount;
    }

    /// Unlock stake from validators, starting with most overutilized
    /// Returns (active_decrement, pending_inactive_increment, withdrawn_amount)
    public(friend) fun unlock(metadata: Object<Metadata>, amount: u64) acquires PoolRouter, StakePool {
        let init_metadata = coin::metadata(@initia_std, string::utf8(b"uinit"));
        assert!(metadata != init_metadata, error::invalid_argument(EUNSUPPORT_TOKEN));
        unlock_lp(metadata, amount);
    }

    public(friend) fun request_claim_rewards(metadata: Object<Metadata>) acquires PoolRouter, StakePool {
        let router = borrow_global<PoolRouter>(@staking_addr);
        let pools = *simple_map::borrow(&router.token_pool_map, &metadata);

        for (i in 0..vector::length(&pools)) {
            let pool_addr = object::object_address(&pools[i]);
            let temp_pool = borrow_global<StakePool>(pool_addr);

            let extend_signer = object::generate_signer_for_extending(&temp_pool.ref);
            if (metadata == utils::get_init_metadata()) {
                lock_staking::withdraw_delegator_reward(&extend_signer);
            } else {
                let msg = MsgWithdrawDelegatorReward {
                    _type_: string::utf8(b"/cosmos.distribution.v1beta1.MsgWithdrawDelegatorReward"),
                    delegator_address: to_sdk(signer::address_of(&extend_signer)),
                    validator_address: temp_pool.validator,
                };
                cosmos::stargate(&extend_signer, marshal(&msg));
            }
        };
    }

    /// Withdraw all reward init
    public(friend) fun withdraw_rewards(stake_meta: Object<Metadata>): FungibleAsset acquires PoolRouter, StakePool {
        let reward_metadata = coin::metadata(@initia_std, string::utf8(b"uinit"));
        withdraw(stake_meta, reward_metadata)
    }

    /// Withdraw all available inactive stakes
    /// Returns total withdrawn amount
    public(friend) fun withdraw_assets(stake_meta: Object<Metadata>): FungibleAsset acquires PoolRouter, StakePool {
        withdraw(stake_meta, stake_meta)
    }

    public(friend) fun get_all_signers(): vector<signer> acquires PoolRouter, StakePool {
        let router = borrow_global<PoolRouter>(@staking_addr);
        let signers: vector<signer> = vector::empty();

        let metas = simple_map::keys( &router.token_pool_map);
        for (i in 0..vector::length(&metas)) {
            let temp_signers = get_signers_for_stake_token(metas[i]);
            vector::append(&mut signers, temp_signers);
        };

        signers
    }

    public(friend) fun get_signers_for_stake_token(metadata: Object<Metadata>): vector<signer> acquires PoolRouter, StakePool {
        let router = borrow_global<PoolRouter>(@staking_addr);
        let signers: vector<signer> = vector::empty();

        let pools = *simple_map::borrow(&router.token_pool_map, &metadata);
        for (i in 0..vector::length(&pools)) {
            let pool_addr = object::object_address(&pools[i]);
            let temp_pool = borrow_global<StakePool>(pool_addr);
            vector::push_back(&mut signers, object::generate_signer_for_extending(&temp_pool.ref))
        };

        signers
    }

    public fun get_all_pool_address(): vector<address> acquires PoolRouter, StakePool {
        let router = borrow_global<PoolRouter>(@staking_addr);
        let addresses: vector<address> = vector::empty();

        let metas = simple_map::keys( &router.token_pool_map);
        for (i in 0..vector::length(&metas)) {
            let temp_addresses = get_pool_address_for_stake_token(metas[i]);
            vector::append(&mut addresses, temp_addresses);
        };

        addresses
    }

    public fun get_pool_address_for_stake_token(metadata: Object<Metadata>): vector<address> acquires PoolRouter, StakePool {
        let router = borrow_global<PoolRouter>(@staking_addr);
        let addresses: vector<address> = vector::empty();

        let pools = *simple_map::borrow(&router.token_pool_map, &metadata);
        for (i in 0..vector::length(&pools)) {
            let pool_addr = object::object_address(&pools[i]);
            let temp_pool = borrow_global<StakePool>(pool_addr);
            vector::push_back(&mut addresses, object::address_from_extend_ref(&temp_pool.ref))
        };

        addresses
    }

    // Helper functions

    /// Find the most underutilized pool
    fun get_most_underutilized_pool(metadata: Object<Metadata>): Object<StakePool> acquires StakePool, PoolRouter {
        let router = borrow_global<PoolRouter>(@staking_addr);
        assert!(simple_map::contains_key(&router.token_pool_map, &metadata), error::invalid_argument(EPOOL_NOT_FOUND));
        let pools = *simple_map::borrow(&router.token_pool_map, &metadata);
        assert!(vector::length(&pools) > 0, error::invalid_argument(EPOOL_NOT_FOUND));

        let pool: Object<StakePool> = pools[0];
        let min_amount: u64 = MAX_U64;
        for (i in 0..vector::length(&pools)) {
            let pool_addr = object::object_address(&pools[i]);
            let temp_pool = borrow_global<StakePool>(pool_addr);
            let temp_amount = temp_pool.amount;
            if (temp_amount < min_amount) {
                min_amount = temp_amount;
                pool = pools[i];
            }
        };

        pool
    }

    fun redelegate_init(pool: &StakePool, new_validator_address: String) {
        let pool_addr = object::address_from_extend_ref(&pool.ref);
        let pool_signer = object::generate_signer_for_extending(&pool.ref);
        let (_, block_time) = block::get_block_info();
        let (_, lock_period) = lock_staking::get_lock_period_limits();
        let new_release_time = (block_time + lock_period) / INIT_LOCK_INTERVAL * INIT_LOCK_INTERVAL;

        let delegations = lock_staking::get_locked_delegations(pool_addr);
        for (i in 0..vector::length(&delegations)) {
            let (metadata, src_validator, _, src_release_time) = lock_staking::unpack_locked_delegation(&delegations[i]);
            lock_staking::redelegate(
                &pool_signer,
                metadata,
                option::none(),
                src_release_time,
                src_validator,
                new_release_time,
                new_validator_address
            )
        };
    }

    fun redelegate_lp(pool: &StakePool, new_validator_address: String) {
        let denom = coin::metadata_to_denom(pool.metadata);
        let coin = Coin { denom, amount: pool.amount };

        let msg = MsgBeginRedelegate {
            _type_: string::utf8(b"/initia.mstaking.v1.MsgBeginRedelegate"),
            delegator_address: to_sdk(object::address_from_extend_ref(&pool.ref)),
            validator_src_address: pool.validator,
            validator_dst_address: new_validator_address,
            amount: vector[coin]
        };
        cosmos::stargate(&object::generate_signer_for_extending(&pool.ref), marshal(&msg));
    }

    fun process_delegate_init(pool: &StakePool, amount: u64) {
        let (_, block_time) = block::get_block_info();
        let (_, lock_period) = lock_staking::get_lock_period_limits();
        let release_time = (block_time + lock_period) / INIT_LOCK_INTERVAL * INIT_LOCK_INTERVAL;
        cosmos::move_execute(
            &object::generate_signer_for_extending(&pool.ref),
            @vip,
            string::utf8(b"lock_staking"),
            string::utf8(b"delegate"),
            vector[],
            vector[
                bcs::to_bytes(&pool.metadata),
                bcs::to_bytes(&amount),
                bcs::to_bytes(&release_time),
                bcs::to_bytes(&pool.validator),
            ]
        );
    }

    fun process_delegate_lp(pool: &StakePool, amount: u64) {
        cosmos::delegate(
            &object::generate_signer_for_extending(&pool.ref),
            pool.validator,
            pool.metadata,
            amount
        );
    }

    fun withdraw(stake_meta: Object<Metadata>, withdraw_meta: Object<Metadata>): FungibleAsset acquires PoolRouter, StakePool {
        let router = borrow_global<PoolRouter>(@staking_addr);
        let pools = *simple_map::borrow(&router.token_pool_map, &stake_meta);
        let fa = fungible_asset::zero(withdraw_meta);

        for (i in 0..vector::length(&pools)) {
            let pool_addr = object::object_address(&pools[i]);
            let temp_pool = borrow_global<StakePool>(pool_addr);
            let extend_signer = object::generate_signer_for_extending(&temp_pool.ref);
            let balance = primary_fungible_store::balance(signer::address_of(&extend_signer), withdraw_meta);
            let temp_fa = primary_fungible_store::withdraw(&extend_signer, withdraw_meta, balance);
            fungible_asset::merge(&mut fa, temp_fa);
        };

        fa
    }

    fun unlock_lp(metadata: Object<Metadata>, amount: u64) acquires PoolRouter, StakePool {
        // Identify validators to unstake from
        let total_amount = get_total_stakes(metadata);
        let router = borrow_global_mut<PoolRouter>(@staking_addr);
        let ratio = bigdecimal::from_ratio_u64(amount, total_amount);
        let denom = coin::metadata_to_denom(metadata);

        // Undelegate via cosmos::stargate with MsgUndelegate
        let pools = *simple_map::borrow_mut(&mut router.token_pool_map, &metadata);
        let remain_amount: u64 = amount;
        for (i in 0..vector::length(&pools)) {
            let pool_addr = object::object_address(&pools[i]);
            let temp_pool = borrow_global_mut<StakePool>(pool_addr);

            let temp_amount = if (i == vector::length(&pools) - 1) {
                remain_amount
            } else {
                bigdecimal::mul_by_u64_truncate(ratio, temp_pool.amount)
            };
            remain_amount = remain_amount - temp_amount;

            let coin = Coin { denom, amount: temp_amount };
            let msg = MsgUndelegate {
                _type_: string::utf8(b"/initia.mstaking.v1.MsgUndelegate"),
                delegator_address: to_sdk(object::address_from_extend_ref(&temp_pool.ref)),
                validator_address: temp_pool.validator,
                amount: vector[coin]
            };
            cosmos::stargate(&object::generate_signer_for_extending(&temp_pool.ref), marshal(&msg));

            // Update state tracking
            temp_pool.amount = temp_pool.amount - temp_amount;

        };
    }

    fun get_init_real_stakes(pool: &Object<StakePool>): u64 {
        let temp_total_stakes: u64 = 0;
        let pool_addr = object::object_address(pool);
        let delegations = lock_staking::get_locked_delegations(pool_addr);
        for (i in 0..vector::length(&delegations)) {
            let (_, _, amount, _) = lock_staking::unpack_locked_delegation(&delegations[i]);
            temp_total_stakes = temp_total_stakes + amount;
        };
        temp_total_stakes
    }

    fun get_lp_real_stakes(pool: &Object<StakePool>): u64 acquires StakePool {
        let pool_addr = object::object_address(pool);
        let temp_pool = borrow_global<StakePool>(pool_addr);
        let denom = coin::metadata_to_denom(temp_pool.metadata);

        // stargate get balance
        let path = b"/initia.mstaking.v1.Query/Delegation";
        let request = DelegationRequest { validator_addr: temp_pool.validator, delegator_addr: address::to_sdk(pool_addr) };
        let response = query_stargate(path, marshal(&request));
        let balances = unmarshal<DelegationResponse>(response).delegation_response.balance;

        let (found, idx) = vector::find<Coin>(
            &balances,
            |balance| {
                balance.denom == denom
            }
        );

        if (found) {
            vector::borrow(&balances, idx).amount
        } else {
            0
        }
    }

    // View functions

    #[view]
    /// Returns all validator addresses
    public fun get_validators(metadata: Object<Metadata>): vector<String> acquires PoolRouter, StakePool {
        let router = borrow_global<PoolRouter>(@staking_addr);
        if (!simple_map::contains_key(&router.token_pool_map, &metadata)) {
            return vector::empty<String>();
        };

        let validators: SimpleMap<String, u8> = simple_map::new();
        let pools = *simple_map::borrow(&router.token_pool_map, &metadata);
        for (i in 0..vector::length(&pools)) {
            let pool_addr = object::object_address(&pools[i]);
            let temp_pool = borrow_global<StakePool>(pool_addr);
            simple_map::upsert(&mut validators, temp_pool.validator, 0);
        };

        simple_map::keys(&validators)
    }

    #[view]
    /// Returns (all support stake tokens)
    public fun get_stake_tokens(): vector<Object<Metadata>> acquires PoolRouter {
        let router = borrow_global<PoolRouter>(@staking_addr);
        simple_map::keys(&router.token_pool_map)
    }

    #[view]
    /// Returns (validators, stakes per pool)
    public fun get_stakes(metadata: Object<Metadata>): (vector<Object<StakePool>>, vector<u64>) acquires PoolRouter, StakePool {
        let router = borrow_global<PoolRouter>(@staking_addr);
        if (!simple_map::contains_key(&router.token_pool_map, &metadata)) {
            return (vector::empty<Object<StakePool>>(), vector::empty<u64>());
        };
        let pools = *simple_map::borrow(&router.token_pool_map, &metadata);
        let amounts: vector<u64> = vector::empty();

        for (i in 0..vector::length(&pools)) {
            let pool_addr = object::object_address(&pools[i]);
            let temp_pool = borrow_global<StakePool>(pool_addr);
            vector::push_back(&mut amounts, temp_pool.amount)
        };

        (pools, amounts)
    }

    #[view]
    /// Returns total active, inactive, and pending_inactive stakes
    public fun get_total_stakes(metadata: Object<Metadata>): u64 acquires PoolRouter, StakePool {
        // Sum up all stake amounts
        let router = borrow_global<PoolRouter>(@staking_addr);
        let total_stakes: u64 = 0;
        if (!simple_map::contains_key(&router.token_pool_map, &metadata)) {
            return total_stakes;
        };

        let pools = *simple_map::borrow(&router.token_pool_map, &metadata);
        for (i in 0..vector::length(&pools)) {
            let pool_addr = object::object_address(&pools[i]);
            let temp_pool = borrow_global<StakePool>(pool_addr);
            total_stakes = total_stakes + temp_pool.amount;
        };

        total_stakes
    }

    #[view]
    /// Returns real total stakes
    public fun get_real_total_stakes(metadata: Object<Metadata>): u64 acquires PoolRouter, StakePool {
        // Sum up all stake amounts
        let router = borrow_global<PoolRouter>(@staking_addr);
        let total_stakes: u64 = 0;
        if (!simple_map::contains_key(&router.token_pool_map, &metadata)) {
            return total_stakes;
        };

        let pools = *simple_map::borrow(&router.token_pool_map, &metadata);

        for (i in 0..vector::length(&pools)) {
            let amount = if (metadata == utils::get_init_metadata()) {
                get_init_real_stakes(&pools[i])
            } else {
                get_lp_real_stakes(&pools[i])
            };
            total_stakes = total_stakes + amount;
        };

        total_stakes
    }

    #[view]
    public fun get_voting_power_weight(): SimpleMap<Object<Metadata>, BigDecimal> acquires PoolRouter, StakePool {
        let res = simple_map::new<Object<Metadata>, BigDecimal>();
        let pool_powers: vector<u64> = vector::empty();
        let total_power: u64 = 0;

        let stake_tokens = get_stake_tokens();
        for (i in 0..vector::length(&stake_tokens)) {
            let pool_addresses = get_pool_address_for_stake_token(stake_tokens[i]);
            let token_power: u64 = 0;
            for (j in 0..vector::length(&pool_addresses)) {
                let power = weight_vote::get_voting_power(pool_addresses[j]);
                token_power = token_power + power;
            };
            vector::push_back(&mut pool_powers, token_power);
            total_power = total_power + token_power;
        };

        for (i in 0..vector::length(&stake_tokens)) {
            simple_map::add(
                &mut res,
                stake_tokens[i],
                bigdecimal::from_ratio_u64(pool_powers[i], total_power)
            );
        };

        res
    }

    // Testing helper functions

    #[test_only]
    public fun init_module_for_test(staking_addr: &signer) {
        init_module(staking_addr)
    }

    #[test_only]
    public fun add_stake_for_test(amount: u64): String {
        // Test helper for add_stake f
        string::utf8(b"validator_address")
    }

    #[test_only]
    /// Manually triggers the delegate logic normally called via move_execute in process_delegate_init
    public fun mock_process_delegate_init(pool: &StakePool, amount: u64) {
        // Borrow the StakePool globally using the provided address
        let pool_ref = &pool.ref; 

        // Get the signer for the pool object using the borrowed reference
        let pool_signer = object::generate_signer_for_extending(pool_ref);

        // Calculate release time (same logic as in process_delegate_init)
        let (_, block_time) = block::get_block_info();
        let (_, lock_period) = lock_staking::get_lock_period_limits(); // Assumes lock_staking is accessible or mocked
        let release_time = (block_time + lock_period) / INIT_LOCK_INTERVAL * INIT_LOCK_INTERVAL;

        // *** Directly call the target function ***
        // Ensure the mock implementation of lock_staking::delegate correctly withdraws
        // the 'amount' from the signer's address (pool_signer).
        vip::lock_staking::delegate(
            &pool_signer,
            pool.metadata, // Pass Object<Metadata> directly
            amount,        // Pass u64 directly
            release_time,  // Pass u64 directly
            pool.validator // Pass String directly
        );
    }


    #[test_only]
    public(friend) fun mock_add_stake(fa: FungibleAsset) acquires PoolRouter, StakePool {
        // Find most underutilized validator
        let metadata = fungible_asset::metadata_from_asset(&fa);
        let amount= fungible_asset::amount(&fa);
        let pool_ob = get_most_underutilized_pool(metadata);
        let pool = borrow_global_mut<StakePool>(object::object_address(&pool_ob));


        // Delegate to validator via cosmos::delegate
        primary_fungible_store::deposit(object::address_from_extend_ref(&pool.ref), fa);
        if (metadata == utils::get_init_metadata()) {
            mock_process_delegate_init(pool, amount);
        } else {
            process_delegate_lp(pool, amount);
        };

        // Update state tracking
        pool.amount = pool.amount + amount;
    }


}