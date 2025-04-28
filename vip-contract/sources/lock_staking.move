module vip::lock_staking {
    use std::bcs::to_bytes;
    use std::error;
    use std::event;
    use std::option::{Self, Option};
    use std::signer;
    use std::string::{Self, String};
    use std::vector;

    use initia_std::address::to_sdk;
    use initia_std::block;
    use initia_std::coin;
    use initia_std::cosmos::{stargate, stargate_vote, move_execute};
    use initia_std::dex;
    use initia_std::bigdecimal::{Self, BigDecimal};
    use initia_std::fungible_asset::{Self, FungibleAsset, Metadata};
    use initia_std::json::{marshal, unmarshal};
    use initia_std::object::{Self, ExtendRef, Object};
    use initia_std::simple_map::{Self, SimpleMap};
    use initia_std::stableswap;
    use initia_std::staking;
    use initia_std::table::{Self, Table};
    use initia_std::table_key;
    use initia_std::type_info;
    use initia_std::query::query_stargate;

    use vip::utils;

    friend vip::vip;

    const EUNAUTHORIZED: u64 = 1;
    const EDELEGATION_NOT_FOUND: u64 = 2;
    // length of redelegation_responses must be 1
    const EREDELEGATION_LENGTH: u64 = 3;
    const ECREATION_HEIGHT_MISMATCH: u64 = 4;
    const ENOT_SINGLE_COIN: u64 = 5;
    const EDENOM_MISMATCH: u64 = 6;
    const ENOT_ENOUGH_BALANCE: u64 = 7;
    const ESMALL_RELEASE_TIME: u64 = 8;
    const ENOT_RELEASE: u64 = 9;
    const EREENTER: u64 = 10;
    const ENOT_ENOUGH_DELEGATION: u64 = 11;
    const EMAX_LOCK_PERIOD: u64 = 12;
    const EMAX_SLOT: u64 = 13;
    const EZERO_AMOUNT: u64 = 14;
    const EINVALID_MIN_MAX: u64 = 15;
    const EINVALID_ARGS_LENGTH: u64 = 16;

    const EDEPRECATED: u64 = 0x100;

    //
    // Events
    //
    #[event]
    struct DepositDelegationEvent has drop, store {
        staking_account: address,
        metadata: Object<Metadata>,
        release_time: u64,
        validator: String,
        locked_share: BigDecimal
    }

    #[event]
    struct WithdrawDelegationEvent has drop, store {
        staking_account: address,
        metadata: Object<Metadata>,
        release_time: u64,
        validator: String,
        locked_share: BigDecimal
    }

    struct LockedDelegationResponse has drop {
        metadata: Object<Metadata>,
        validator: String,
        locked_share: BigDecimal,
        amount: u64,
        release_time: u64
    }

    struct StakingAccount has key {
        extend_ref: ExtendRef,
        last_height: u64, // record the locked height to prevent the stargate sequential problem.
        validators: Table<String, u16>, // validator => number of delegation
        delegations: Table<DelegationKey, BigDecimal>, // key => locked share
        // This share variable is specific to the lock_staking.move module
        // It should not be confused with the share variable in the mstaking module
        total_locked_shares: Table<LockedShareKey, BigDecimal> // store total locked share
    }

    struct DelegationKey has copy, drop {
        metadata: Object<Metadata>,
        release_time: vector<u8>, // use table encoded key for ordering
        validator: String
    }

    struct LockedShareKey has copy, drop {
        metadata: Object<Metadata>,
        validator: String
    }

    struct ModuleStore has key {
        min_lock_period: u64,
        max_lock_period: u64,
        max_delegation_slot: u64
    }

    // init module
    fun init_module(vip: &signer) {
        move_to(
            vip,
            ModuleStore {
                min_lock_period: 0,
                max_lock_period: 126230400u64, // 60 * 60 * 24 * 365.25 * 4 (4 years)
                max_delegation_slot: 18_446_744_073_709_551_615u64 // u64 max at first
            }
        )
    }

    // entry functions
    public entry fun update_params(
        chain: &signer,
        min_lock_period: Option<u64>,
        max_lock_period: Option<u64>,
        max_delegation_slot: Option<u64>
    ) acquires ModuleStore {
        utils::check_chain_permission(chain);
        let module_store = borrow_global_mut<ModuleStore>(@vip);

        if (option::is_some(&min_lock_period)) {
            module_store.min_lock_period = option::extract(&mut min_lock_period);
        };

        if (option::is_some(&max_lock_period)) {
            module_store.max_lock_period = option::extract(&mut max_lock_period);
        };

        if (option::is_some(&max_delegation_slot)) {
            module_store.max_delegation_slot = option::extract(&mut max_delegation_slot);
        };

        assert!(
            module_store.max_lock_period > module_store.min_lock_period,
            error::invalid_argument(EINVALID_MIN_MAX)
        );
    }

    public entry fun withdraw_delegator_reward(account: &signer) acquires StakingAccount {
        let staking_account_signer = get_staking_account_signer(account);
        let staking_account_addr = signer::address_of(&staking_account_signer);
        let staking_account = borrow_global<StakingAccount>(staking_account_addr);

        let iter =
            table::iter(
                &staking_account.validators,
                option::none(),
                option::none(),
                1
            );

        loop {
            if (!table::prepare<String, u16>(iter)) { break };
            let (validator, _) = table::next<String, u16>(iter);
            // execute withdraw delegator reward for each validator
            let msg = MsgWithdrawDelegatorReward {
                _type_: string::utf8(
                    b"/cosmos.distribution.v1beta1.MsgWithdrawDelegatorReward"
                ),
                delegator_address: to_sdk(staking_account_addr),
                validator_address: validator
            };
            stargate(&staking_account_signer, marshal(&msg))
        };

        // withdraw uinit from staking account
        move_execute(
            &staking_account_signer,
            @vip,
            string::utf8(b"lock_staking"),
            string::utf8(b"withdraw_asset_for_staking_account"),
            vector[],
            vector[
                to_bytes(&coin::metadata(@initia_std, string::utf8(b"uinit"))),
                to_bytes(&option::none<u64>())
            ]
        )
    }

    public entry fun vote_gov_proposal(
        account: &signer,
        proposal_id: u64,
        option: u64,
        metadata: String
    ) acquires StakingAccount {
        let addr = signer::address_of(account);
        if (!is_registered(addr)) { return };

        let staking_account_signer = get_staking_account_signer(account);
        let staking_account_addr = signer::address_of(&staking_account_signer);
        stargate_vote(
            &staking_account_signer,
            proposal_id,
            to_sdk(staking_account_addr),
            option,
            metadata
        );
    }

    public entry fun withdraw_asset(
        account: &signer, metadata: Object<Metadata>, amount: Option<u64>
    ) acquires StakingAccount {
        let staking_account_signer = get_staking_account_signer(account);
        withdraw_asset_for_staking_account(&staking_account_signer, metadata, amount);
    }

    public entry fun withdraw_asset_for_staking_account(
        staking_account_signer: &signer, metadata: Object<Metadata>, amount: Option<u64>
    ) {
        let staking_account_addr = signer::address_of(staking_account_signer);
        assert_staking_account(staking_account_addr);
        let object = object::address_to_object<StakingAccount>(staking_account_addr);
        let owner = object::owner(object);

        let balance = coin::balance(staking_account_addr, metadata);

        let withdraw_amount =
            if (option::is_none(&amount)) {
                balance
            } else {
                let withdraw_amount = *option::borrow(&amount);
                assert!(withdraw_amount > 0, error::invalid_argument(EZERO_AMOUNT));
                assert!(
                    withdraw_amount <= balance,
                    error::invalid_argument(ENOT_ENOUGH_BALANCE)
                );
                withdraw_amount
            };

        if (withdraw_amount == 0) { return };

        coin::transfer(
            staking_account_signer,
            owner,
            metadata,
            withdraw_amount
        );
    }

    public entry fun delegate(
        account: &signer,
        metadata: Object<Metadata>,
        amount: u64,
        release_time: u64,
        validator_address: String
    ) acquires StakingAccount, ModuleStore {
        let fa = coin::withdraw(account, metadata, amount);
        delegate_internal(account, fa, release_time, validator_address);
    }

    public entry fun provide_delegate(
        account: &signer,
        metadata: Object<Metadata>,
        coin_a_amount_in: u64,
        coin_b_amount_in: u64,
        min_liquidity: Option<u64>,
        release_time: u64,
        validator_address: String
    ) acquires StakingAccount, ModuleStore {
        let pair = object::convert(metadata);
        let (coin_a_amount_in, coin_b_amount_in) =
            get_exact_provide_amount(pair, coin_a_amount_in, coin_b_amount_in);
        let (metadata_a, metadata_b) = dex::pool_metadata(pair);
        let coin_a = coin::withdraw(account, metadata_a, coin_a_amount_in);
        let coin_b = coin::withdraw(account, metadata_b, coin_b_amount_in);
        let fa = dex::provide_liquidity(pair, coin_a, coin_b, min_liquidity);

        delegate_internal(account, fa, release_time, validator_address);
    }

    public entry fun single_asset_provide_delegate(
        account: &signer,
        metadata: Object<Metadata>,
        offer_asset_metadata: Object<Metadata>,
        amount_in: u64,
        min_liquidity: Option<u64>,
        release_time: u64,
        validator_address: String
    ) acquires StakingAccount, ModuleStore {
        let pair = object::convert(metadata);
        let fa =
            dex::single_asset_provide_liquidity(
                pair,
                coin::withdraw(account, offer_asset_metadata, amount_in),
                min_liquidity
            );

        delegate_internal(account, fa, release_time, validator_address);

    }

    public entry fun stableswap_provide_delegate(
        account: &signer,
        metadata: Object<Metadata>,
        coin_amounts: vector<u64>,
        min_liquidity: Option<u64>,
        release_time: u64,
        validator_address: String
    ) acquires StakingAccount, ModuleStore {
        let pool = object::convert(metadata);
        let (coin_metadata, _, _, _) = stableswap::pool_info(pool);
        let coins: vector<FungibleAsset> = vector[];

        let i = 0;
        let n = vector::length(&coin_amounts);
        while (i < n) {
            let metadata = *vector::borrow(&coin_metadata, i);
            let amount = *vector::borrow(&coin_amounts, i);
            vector::push_back(
                &mut coins,
                coin::withdraw(account, metadata, amount)
            );
            i = i + 1;
        };

        let fa = stableswap::provide_liquidity(pool, coins, min_liquidity);

        delegate_internal(account, fa, release_time, validator_address);
    }

    public entry fun redelegate(
        account: &signer,
        metadata: Object<Metadata>,
        amount: Option<u64>, // if none, redelegate all
        src_release_time: u64,
        validator_src_address: String,
        dst_release_time: u64,
        validator_dst_address: String
    ) acquires StakingAccount {
        let staking_account_signer = get_staking_account_signer(account);
        let staking_account_addr = signer::address_of(&staking_account_signer);
        let staking_account = borrow_global_mut<StakingAccount>(staking_account_addr);

        reentry_check(staking_account, true);
        assert!(
            dst_release_time >= src_release_time,
            error::invalid_argument(ESMALL_RELEASE_TIME)
        );
        // get current delegation shares
        let src_delegation =
            get_delegation(
                staking_account,
                validator_src_address,
                staking_account_addr,
                false
            );
        let locked_share =
            get_locked_share(
                staking_account,
                metadata,
                src_release_time,
                validator_src_address
            );
        let src_share_before =
            get_share(
                &src_delegation.delegation.shares,
                coin::metadata_to_denom(metadata),
                true
            );
        let dst_delegation =
            get_delegation(
                staking_account,
                validator_dst_address,
                staking_account_addr,
                false
            );
        let dst_share_before =
            get_share(
                &dst_delegation.delegation.shares,
                coin::metadata_to_denom(metadata),
                false
            );
        let locked_amount =
            locked_share_to_amount(
                staking_account,
                validator_src_address,
                metadata,
                &src_share_before,
                &locked_share
            );

        // get redelegate amount and share before
        let (amount, src_share_before) =
            if (option::is_none(&amount)) {
                // redelegate all
                (locked_amount, option::none())
            } else {
                let redelegate_amount = option::extract(&mut amount);
                assert!(redelegate_amount > 0, error::invalid_argument(EZERO_AMOUNT));
                assert!(
                    locked_amount >= redelegate_amount,
                    error::invalid_argument(ENOT_ENOUGH_DELEGATION)
                );

                if (redelegate_amount == locked_amount) {
                    (locked_amount, option::none())
                } else {
                    (redelegate_amount, option::some(src_share_before))
                }
            };

        // execute begin redelegate
        let coin = create_coin(metadata, amount);
        let msg = MsgBeginRedelegate {
            _type_: string::utf8(b"/initia.mstaking.v1.MsgBeginRedelegate"),
            delegator_address: to_sdk(staking_account_addr),
            validator_src_address,
            validator_dst_address,
            amount: vector[coin]
        };

        stargate(&staking_account_signer, marshal(&msg));

        // execute redelegate hook
        move_execute(
            &staking_account_signer,
            @vip,
            string::utf8(b"lock_staking"),
            string::utf8(b"redelegate_hook_v2"),
            vector[],
            vector[
                to_bytes(&metadata),
                to_bytes(&src_release_time),
                to_bytes(&validator_src_address),
                to_bytes(&src_share_before),
                to_bytes(&dst_release_time),
                to_bytes(&validator_dst_address),
                to_bytes(&dst_share_before)
            ]
        )
    }

    public entry fun undelegate(
        account: &signer,
        metadata: Object<Metadata>,
        amount: Option<u64>, // if none, undelegte all
        release_time: u64,
        validator: String
    ) acquires StakingAccount {
        let staking_account_signer = get_staking_account_signer(account);
        let staking_account_addr = signer::address_of(&staking_account_signer);
        let staking_account = borrow_global_mut<StakingAccount>(staking_account_addr);

        reentry_check(staking_account, true);

        // check can undelegate
        let (_, curr_time) = block::get_block_info();
        assert!(
            curr_time > release_time,
            error::invalid_state(ENOT_RELEASE)
        );
        // get current delegation share
        let delegation =
            get_delegation(
                staking_account,
                validator,
                staking_account_addr,
                false
            );
        let locked_share =
            get_locked_share(
                staking_account,
                metadata,
                release_time,
                validator
            );
        let share_before =
            get_share(
                &delegation.delegation.shares,
                coin::metadata_to_denom(metadata),
                true
            );

        let locked_amount =
            locked_share_to_amount(
                staking_account,
                validator,
                metadata,
                &share_before,
                &locked_share
            );

        // get undelegate amount and share before
        let (amount, share_before) =
            if (option::is_none(&amount)) {
                // undelegate all
                (locked_amount, option::none())
            } else {
                let undelegate_amount = option::extract(&mut amount);
                assert!(undelegate_amount > 0, error::invalid_argument(EZERO_AMOUNT));
                assert!(
                    locked_amount >= undelegate_amount,
                    error::invalid_argument(ENOT_ENOUGH_DELEGATION)
                );

                if (undelegate_amount == locked_amount) {
                    (locked_amount, option::none())
                } else {
                    (undelegate_amount, option::some(share_before))
                }
            };

        // execute undelegate
        let coin = create_coin(metadata, amount);
        let msg = MsgUndelegate {
            _type_: string::utf8(b"/initia.mstaking.v1.MsgUndelegate"),
            delegator_address: to_sdk(staking_account_addr),
            validator_address: validator,
            amount: vector[coin]
        };

        stargate(&staking_account_signer, marshal(&msg));

        // execute undelegate hook
        move_execute(
            &staking_account_signer,
            @vip,
            string::utf8(b"lock_staking"),
            string::utf8(b"undelegate_hook"),
            vector[],
            vector[
                to_bytes(&metadata),
                to_bytes(&release_time),
                to_bytes(&validator),
                to_bytes(&share_before)
            ]
        )
    }

    public entry fun extend(
        account: &signer,
        metadata: Object<Metadata>,
        amount: Option<u64>, // if none, extend all
        release_time: u64,
        validator: String,
        new_release_time: u64
    ) acquires StakingAccount, ModuleStore {
        let staking_account_signer = get_staking_account_signer(account);
        let staking_account_addr = signer::address_of(&staking_account_signer);
        let staking_account = borrow_global_mut<StakingAccount>(staking_account_addr);

        reentry_check(staking_account, false);

        extend_internal(
            staking_account_addr,
            staking_account,
            metadata,
            amount,
            release_time,
            validator,
            new_release_time
        );
    }

    public entry fun batch_extend(
        account: &signer,
        metadata: vector<Object<Metadata>>,
        amounts: vector<Option<u64>>, // if none, extend all
        release_times: vector<u64>,
        validators: vector<String>,
        new_release_times: vector<u64>
    ) acquires StakingAccount, ModuleStore {
        let staking_account_signer = get_staking_account_signer(account);
        let staking_account_addr = signer::address_of(&staking_account_signer);
        let staking_account = borrow_global_mut<StakingAccount>(staking_account_addr);

        reentry_check(staking_account, false);

        let len = vector::length(&metadata);
        assert!(
            len == vector::length(&amounts)
                && len == vector::length(&release_times)
                && len == vector::length(&validators)
                && len == vector::length(&new_release_times),
            error::invalid_argument(EINVALID_ARGS_LENGTH)
        );

        let i = 0;
        while (i < len) {
            extend_internal(
                staking_account_addr,
                staking_account,
                *vector::borrow(&metadata, i),
                *vector::borrow(&amounts, i),
                *vector::borrow(&release_times, i),
                *vector::borrow(&validators, i),
                *vector::borrow(&new_release_times, i)
            );
            i = i + 1;
        }
    }

    fun extend_internal(
        staking_account_addr: address,
        staking_account: &mut StakingAccount,
        metadata: Object<Metadata>,
        amount: Option<u64>, // if none, extend all
        release_time: u64,
        validator: String,
        new_release_time: u64
    ) acquires ModuleStore {
        // check release time
        assert!(
            new_release_time > release_time,
            error::invalid_argument(ESMALL_RELEASE_TIME)
        );

        // get locked_share amount to extend
        let locked_share =
            if (option::is_none(&amount)) {
                // extend all
                option::none()
            } else {
                let extend_amount = option::extract(&mut amount);
                assert!(extend_amount > 0, error::invalid_argument(EZERO_AMOUNT));
                // get current delegation share
                let delegation =
                    get_delegation(
                        staking_account,
                        validator,
                        staking_account_addr,
                        false
                    );
                let total_share =
                    get_share(
                        &delegation.delegation.shares,
                        coin::metadata_to_denom(metadata),
                        true
                    );
                option::some(
                    amount_to_locked_share(
                        staking_account,
                        validator,
                        metadata,
                        &total_share,
                        extend_amount
                    )
                )
            };

        // withdraw/remove delegation
        let withdrawn_locked_share =
            withdraw_delegation(
                staking_account,
                metadata,
                release_time,
                validator,
                locked_share
            );

        // deposit delegation to new release time
        deposit_delegation(
            staking_account,
            metadata,
            validator,
            withdrawn_locked_share,
            new_release_time
        );
    }

    // stargate msgs
    struct MsgDelegate has drop {
        _type_: String,
        delegator_address: String,
        validator_address: String,
        amount: vector<Coin>
    }

    struct MsgBeginRedelegate has drop {
        _type_: String,
        delegator_address: String,
        validator_src_address: String,
        validator_dst_address: String,
        amount: vector<Coin>
    }

    struct MsgUndelegate has drop {
        _type_: String,
        delegator_address: String,
        validator_address: String,
        amount: vector<Coin>
    }

    struct MsgWithdrawDelegatorReward has drop {
        _type_: String,
        delegator_address: String,
        validator_address: String
    }

    public(friend) fun delegate_internal(
        account: &signer,
        fa: FungibleAsset,
        release_time: u64,
        validator_address: String
    ) acquires StakingAccount, ModuleStore {
        let (_, curr_time) = block::get_block_info();
        let module_store = borrow_global<ModuleStore>(@vip);
        assert!(
            release_time > curr_time + module_store.min_lock_period,
            error::invalid_argument(ESMALL_RELEASE_TIME)
        );

        let staking_account_signer = get_staking_account_signer(account);
        let staking_account_addr = signer::address_of(&staking_account_signer);
        let staking_account = borrow_global_mut<StakingAccount>(staking_account_addr);

        reentry_check(staking_account, true);
        let metadata = fungible_asset::metadata_from_asset(&fa);
        let amount = fungible_asset::amount(&fa);
        let denom = coin::metadata_to_denom(metadata);
        let coin = Coin { denom, amount };

        // deposit token to staking account addr
        coin::deposit(staking_account_addr, fa);

        // delegate
        let msg = MsgDelegate {
            _type_: string::utf8(b"/initia.mstaking.v1.MsgDelegate"),
            delegator_address: to_sdk(staking_account_addr),
            validator_address,
            amount: vector[coin]
        };

        // execute hook
        let delegation =
            get_delegation(
                staking_account,
                validator_address,
                staking_account_addr,
                false
            );

        let share_before = get_share(&delegation.delegation.shares, denom, false);

        stargate(&staking_account_signer, marshal(&msg));

        move_execute(
            &staking_account_signer,
            @vip,
            string::utf8(b"lock_staking"),
            string::utf8(b"delegate_hook"),
            vector[],
            vector[
                to_bytes(&metadata),
                to_bytes(&release_time),
                to_bytes(&validator_address),
                to_bytes(&share_before)
            ]
        )
    }

    // hook functions
    entry fun delegate_hook(
        staking_account_signer: &signer,
        metadata: Object<Metadata>,
        release_time: u64,
        validator: String,
        share_before: BigDecimal
    ) acquires StakingAccount, ModuleStore {
        let staking_account_addr = signer::address_of(staking_account_signer);
        let staking_account = borrow_global_mut<StakingAccount>(staking_account_addr);
        assert_staking_account(staking_account_addr);

        delegate_hook_internal(
            staking_account,
            staking_account_addr,
            metadata,
            release_time,
            validator,
            share_before
        );

        // withdraw uinit from staking account
        withdraw_asset_for_staking_account(
            staking_account_signer,
            coin::metadata(@initia_std, string::utf8(b"uinit")),
            option::none()
        );

        unlock_reentry_check(staking_account);
    }

    #[deprecated]
    entry fun redelegate_hook(
        _staking_account_signer: &signer,
        _metadata: Object<Metadata>,
        _src_release_time: u64,
        _validator_src_address: String,
        _dst_release_time: u64,
        _validator_dst_address: String,
        _src_share_before: Option<BigDecimal> // if none, redelegate all
    ) {
        abort(error::unavailable(EDEPRECATED));
    }

    entry fun redelegate_hook_v2(
        staking_account_signer: &signer,
        metadata: Object<Metadata>,
        src_release_time: u64,
        validator_src_address: String,
        src_share_before: Option<BigDecimal>, // if none, redelegate all
        dst_release_time: u64,
        validator_dst_address: String,
        dst_share_before: BigDecimal
    ) acquires StakingAccount, ModuleStore {
        let staking_account_addr = signer::address_of(staking_account_signer);
        let staking_account = borrow_global_mut<StakingAccount>(staking_account_addr);
        assert_staking_account(staking_account_addr);

        undelegate_hook_internal(
            staking_account,
            staking_account_addr,
            metadata,
            src_release_time,
            validator_src_address,
            src_share_before
        );
        delegate_hook_internal(
            staking_account,
            staking_account_addr,
            metadata,
            dst_release_time,
            validator_dst_address,
            dst_share_before
        );

        // withdraw uinit from staking account
        withdraw_asset_for_staking_account(
            staking_account_signer,
            coin::metadata(@initia_std, string::utf8(b"uinit")),
            option::none()
        );

        unlock_reentry_check(staking_account);
    }

    entry fun undelegate_hook(
        staking_account_signer: &signer,
        metadata: Object<Metadata>,
        release_time: u64,
        validator: String,
        share_before: Option<BigDecimal> // if none, undelegate all
    ) acquires StakingAccount {
        let staking_account_addr = signer::address_of(staking_account_signer);
        let staking_account = borrow_global_mut<StakingAccount>(staking_account_addr);
        assert_staking_account(staking_account_addr);

        let (height, _) = block::get_block_info();
        let denom = coin::metadata_to_denom(metadata);

        // get undelegation
        let UnbondingDelegationResponse { unbond } =
            get_unbonding_delegation(staking_account_addr, validator);

        // the last entry is the most recent creation
        let unbond_entry = vector::pop_back(&mut unbond.entries);

        // check unbond to check query ordering changed
        assert!(
            unbond_entry.creation_height == height,
            error::internal(ECREATION_HEIGHT_MISMATCH)
        );
        assert!(
            vector::length(&unbond_entry.initial_balance) == 1,
            error::internal(ENOT_SINGLE_COIN)
        );
        let initial_balance = vector::borrow(&unbond_entry.initial_balance, 0);
        assert!(
            initial_balance.denom == denom,
            error::internal(EDENOM_MISMATCH)
        );

        undelegate_hook_internal(
            staking_account,
            staking_account_addr,
            metadata,
            release_time,
            validator,
            share_before
        );

        // withdraw uinit from staking account
        withdraw_asset_for_staking_account(
            staking_account_signer,
            coin::metadata(@initia_std, string::utf8(b"uinit")),
            option::none()
        );

        unlock_reentry_check(staking_account);
    }

    fun delegate_hook_internal(
        staking_account: &mut StakingAccount,
        staking_account_addr: address,
        metadata: Object<Metadata>,
        release_time: u64,
        validator: String,
        share_before: BigDecimal
    ) acquires ModuleStore {
        // calculate share diff
        let denom = coin::metadata_to_denom(metadata);

        let delegation =
            get_delegation(
                staking_account,
                validator,
                staking_account_addr,
                true
            );

        let share_after = get_share(&delegation.delegation.shares, denom, true);
        let share_diff = bigdecimal::sub(share_after, share_before);
        let new_locked_share =
            share_to_locked_share(
                staking_account,
                validator,
                metadata,
                &share_before,
                &share_diff
            );

        // store delegation
        deposit_delegation(
            staking_account,
            metadata,
            validator,
            new_locked_share,
            release_time
        );
    }

    fun undelegate_hook_internal(
        staking_account: &mut StakingAccount,
        staking_account_addr: address,
        metadata: Object<Metadata>,
        release_time: u64,
        validator: String,
        share_before: Option<BigDecimal> // if none, undelegate all
    ) {
        let denom = coin::metadata_to_denom(metadata);

        // withdraw delegation
        let locked_share_to_withdraw =
            if (option::is_none(&share_before)) {
                option::none()
            } else {
                // calculate share diff
                let share_before = option::extract(&mut share_before);
                let delegation =
                    get_delegation(
                        staking_account,
                        validator,
                        staking_account_addr,
                        false
                    );

                let share_after = get_share(&delegation.delegation.shares, denom, false);

                let share_diff = bigdecimal::sub(share_before, share_after);

                let locked_share =
                    share_to_locked_share(
                        staking_account,
                        validator,
                        metadata,
                        &share_before,
                        &share_diff
                    );
                option::some(locked_share)
            };

        withdraw_delegation(
            staking_account,
            metadata,
            release_time,
            validator,
            locked_share_to_withdraw
        );
    }

    // stargate queries
    struct DelegationRequest has copy, drop {
        validator_addr: String,
        delegator_addr: String
    }

    struct DelegationResponse has drop, copy, store {
        delegation_response: DelegationResponseInner
    }

    struct DelegationResponseInner has drop, copy, store {
        delegation: Delegation,
        balance: vector<Coin>
    }

    struct UnbondingDelegationRequest has copy, drop {
        delegator_addr: String,
        validator_addr: String
    }

    struct UnbondingDelegationResponse has drop, copy, store {
        unbond: UnbondingDelegation
    }

    // only allow single redelegation query
    struct RedelegationsRequest has copy, drop {
        delegator_addr: String,
        src_validator_addr: String,
        dst_validator_addr: String
    }

    struct RedelegationsResponse has drop, copy, store {
        redelegation_responses: vector<RedelegationResponse>, // Always contains exactly one item, as only single redelegation queries are allowed
        pagination: Option<PageResponse> // Always None, as only single redelegation queries are allowed
    }

    fun get_delegation(
        staking_account: &StakingAccount,
        validator_addr: String,
        delegator_addr: address,
        must_exist: bool
    ): DelegationResponseInner {
        let delegator_addr = to_sdk(delegator_addr);
        if (!table::contains(&staking_account.validators, validator_addr)
            && !must_exist) {
            return DelegationResponseInner {
                delegation: Delegation {
                    delegator_address: delegator_addr,
                    validator_address: validator_addr,
                    shares: vector[]
                },
                balance: vector[]
            }
        };
        let path = b"/initia.mstaking.v1.Query/Delegation";
        let request = DelegationRequest { validator_addr, delegator_addr };
        query<DelegationRequest, DelegationResponse>(path, request).delegation_response
    }

    fun get_unbonding_delegation(
        delegator_addr: address, validator_addr: String
    ): UnbondingDelegationResponse {
        let path = b"/initia.mstaking.v1.Query/UnbondingDelegation";
        let request = UnbondingDelegationRequest {
            validator_addr,
            delegator_addr: to_sdk(delegator_addr)
        };
        query<UnbondingDelegationRequest, UnbondingDelegationResponse>(path, request)
    }

    fun get_redelegations(
        delegator_addr: String, src_validator_addr: String, dst_validator_addr: String
    ): RedelegationsResponse {
        let path = b"/initia.mstaking.v1.Query/Redelegations";
        let request = RedelegationsRequest {
            delegator_addr,
            src_validator_addr,
            dst_validator_addr
        };
        query<RedelegationsRequest, RedelegationsResponse>(path, request)
    }

    fun query<Request: drop, Response: drop>(
        path: vector<u8>, data: Request
    ): Response {
        let response = query_stargate(path, marshal(&data));
        unmarshal<Response>(response)
    }

    // common cosmos types
    struct Delegation has drop, copy, store {
        delegator_address: String,
        validator_address: String,
        shares: vector<DecCoin>
    }

    struct Coin has drop, copy, store {
        denom: String,
        amount: u64
    }

    struct DecCoin has drop, copy, store {
        denom: String,
        amount: BigDecimal
    }

    struct UnbondingDelegation has drop, copy, store {
        delegator_address: String,
        validator_address: String,
        entries: vector<UnbondingDelegationEntry>
    }

    struct UnbondingDelegationEntry has drop, copy, store {
        creation_height: u64,
        completion_time: String,
        initial_balance: vector<Coin>,
        balance: vector<Coin>,
        unbonding_id: u64,
        unbonding_on_hold_ref_count: u64
    }

    struct RedelegationResponse has drop, copy, store {
        redelegation: Redelegation,
        entries: vector<RedelegationEntryResponse>
    }

    struct Redelegation has drop, copy, store {
        delegator_address: String,
        validator_src_address: String,
        validator_dst_address: String,
        entries: Option<vector<RedelegationEntry>> // Always None for query response
    }

    struct RedelegationEntry has drop, copy, store {
        creation_height: u32,
        completion_time: String,
        initial_balance: vector<Coin>,
        shares_dst: vector<DecCoin>,
        unbonding_id: u32
    }

    struct RedelegationEntryResponse has drop, copy, store {
        redelegation_entry: RedelegationEntry,
        balance: vector<Coin>
    }

    struct PageResponse has drop, copy, store {
        next_key: String, // hex string
        total: u64
    }

    // util functions
    public fun is_registered(addr: address): bool {
        let staking_account_addr = get_staking_address(addr);
        exists<StakingAccount>(staking_account_addr)
    }

    public fun unpack_locked_delegation(
        locked_delegation: &LockedDelegationResponse
    ): (Object<Metadata>, String, u64, u64) {
        (
            locked_delegation.metadata,
            locked_delegation.validator,
            locked_delegation.amount,
            locked_delegation.release_time
        )
    }

    public fun get_lock_period_limits(): (u64, u64) acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        (module_store.min_lock_period, module_store.max_lock_period)
    }

    fun get_staking_account_signer(account: &signer): signer acquires StakingAccount {
        let addr = signer::address_of(account);
        if (!is_registered(addr)) {
            let constructor_ref =
                object::create_named_object(
                    account, generate_staking_account_seed(addr)
                );
            let extend_ref = object::generate_extend_ref(&constructor_ref);
            let transfer_ref = object::generate_transfer_ref(&constructor_ref);
            let staking_account_signer = object::generate_signer(&constructor_ref);
            move_to(
                &staking_account_signer,
                StakingAccount {
                    extend_ref,
                    last_height: 0,
                    validators: table::new(),
                    delegations: table::new(),
                    total_locked_shares: table::new()
                }
            );
            object::disable_ungated_transfer(&transfer_ref);
        };

        let staking_account = borrow_global<StakingAccount>(get_staking_address(addr));
        object::generate_signer_for_extending(&staking_account.extend_ref)
    }

    fun generate_staking_account_seed(addr: address): vector<u8> {
        let type_name = type_info::type_name<StakingAccount>();
        let seed = *string::bytes(&type_name);
        vector::append(&mut seed, to_bytes(&addr));
        seed
    }

    fun create_coin(metadata: Object<Metadata>, amount: u64): Coin {
        let denom = coin::metadata_to_denom(metadata);
        Coin { denom, amount }
    }

    fun assert_staking_account(staking_account_addr: address) {
        assert!(
            exists<StakingAccount>(staking_account_addr),
            error::permission_denied(EUNAUTHORIZED)
        )
    }

    fun compare_denom(dec_coin: &DecCoin, denom: String): bool {
        dec_coin.denom == denom
    }

    fun generate_delegation_key(
        metadata: Object<Metadata>, release_time: u64, validator: String
    ): DelegationKey {
        DelegationKey {
            metadata,
            release_time: table_key::encode_u64(release_time),
            validator
        }
    }

    fun reentry_check(
        staking_account: &mut StakingAccount, with_update: bool
    ) {
        let (height, _) = block::get_block_info();
        assert!(staking_account.last_height != height, error::invalid_state(EREENTER));

        if (with_update) {
            staking_account.last_height = height;
        };
    }

    fun unlock_reentry_check(staking_account: &mut StakingAccount) {
        staking_account.last_height = 0;
    }

    fun withdraw_delegation(
        staking_account: &mut StakingAccount,
        metadata: Object<Metadata>,
        release_time: u64,
        validator: String,
        locked_share: Option<BigDecimal> // if none, withdraw all
    ): BigDecimal {
        let key = generate_delegation_key(metadata, release_time, validator);
        let locked_share_stored = table::borrow_mut(
            &mut staking_account.delegations, key
        );
        let locked_share =
            if (option::is_some(&locked_share)) {
                option::extract(&mut locked_share)
            } else {
                *locked_share_stored
            };

        assert!(
            bigdecimal::ge(*locked_share_stored, locked_share),
            error::invalid_argument(ENOT_ENOUGH_DELEGATION)
        );

        // update total locked share
        let total_locked_share =
            table::borrow_mut(
                &mut staking_account.total_locked_shares,
                LockedShareKey { metadata, validator }
            );
        *total_locked_share = bigdecimal::sub(*total_locked_share, locked_share);

        if (bigdecimal::is_zero(*total_locked_share)) {
            table::remove(
                &mut staking_account.total_locked_shares,
                LockedShareKey { metadata, validator }
            );
        };

        // update locked delegation
        if (bigdecimal::eq(*locked_share_stored, locked_share)) {
            table::remove(&mut staking_account.delegations, key);
            let count = table::borrow_mut(&mut staking_account.validators, validator);
            *count = *count - 1;
            if (count == &0) {
                table::remove(&mut staking_account.validators, validator);
            };
        } else {
            *locked_share_stored = bigdecimal::sub(*locked_share_stored, locked_share);
        };

        event::emit(
            WithdrawDelegationEvent {
                staking_account: object::address_from_extend_ref(
                    &staking_account.extend_ref
                ),
                metadata,
                release_time,
                validator,
                locked_share
            }
        );

        locked_share
    }

    fun deposit_delegation(
        staking_account: &mut StakingAccount,
        metadata: Object<Metadata>,
        validator: String,
        locked_share: BigDecimal,
        release_time: u64
    ) acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        let key = generate_delegation_key(metadata, release_time, validator);

        let (_, curr_time) = block::get_block_info();
        assert!(
            release_time <= curr_time + module_store.max_lock_period,
            error::invalid_argument(EMAX_LOCK_PERIOD)
        );

        // update total locked share
        let total_locked_share =
            table::borrow_mut_with_default(
                &mut staking_account.total_locked_shares,
                LockedShareKey { metadata, validator },
                bigdecimal::zero()
            );
        *total_locked_share = bigdecimal::add(*total_locked_share, locked_share);
        // update locked delegation
        if (!table::contains(&staking_account.delegations, key)) {
            let count =
                table::borrow_mut_with_default(
                    &mut staking_account.validators, validator, 0
                );
            *count = *count + 1;
            table::add(
                &mut staking_account.delegations,
                key,
                bigdecimal::zero() // locked share
            )
        };

        let locked_share_stored = table::borrow_mut(
            &mut staking_account.delegations, key
        );
        *locked_share_stored = bigdecimal::add(*locked_share_stored, locked_share);

        assert!(
            table::length(&staking_account.delegations)
                <= module_store.max_delegation_slot,
            error::invalid_state(EMAX_SLOT)
        );

        event::emit(
            DepositDelegationEvent {
                staking_account: object::address_from_extend_ref(
                    &staking_account.extend_ref
                ),
                metadata,
                release_time,
                validator,
                locked_share
            }
        );
    }

    fun get_share(
        shares: &vector<DecCoin>, denom: String, must_exist: bool
    ): BigDecimal {
        let (found, idx) = vector::find<DecCoin>(
            shares, |share| { compare_denom(share, denom) }
        );

        assert!(!must_exist || found, error::not_found(EDELEGATION_NOT_FOUND));

        if (found) {
            vector::borrow(shares, idx).amount
        } else {
            bigdecimal::zero()
        }
    }

    fun locked_share_to_share(
        staking_account: &StakingAccount,
        validator: String,
        metadata: Object<Metadata>,
        total_share: &BigDecimal,
        locked_share: &BigDecimal
    ): BigDecimal {
        let total_locked_share =
            table::borrow_with_default(
                &staking_account.total_locked_shares,
                LockedShareKey { metadata, validator },
                &bigdecimal::zero()
            );
        if (bigdecimal::is_zero(*total_share)
            || bigdecimal::is_zero(*total_locked_share)) {
            return *locked_share
        };

        // locked_share * total_share / total_locekd_share
        bigdecimal::div(
            bigdecimal::mul(*locked_share, *total_share), *total_locked_share
        )
    }

    fun share_to_locked_share(
        staking_account: &StakingAccount,
        validator: String,
        metadata: Object<Metadata>,
        total_share: &BigDecimal,
        share: &BigDecimal
    ): BigDecimal {
        let total_locked_share =
            table::borrow_with_default(
                &staking_account.total_locked_shares,
                LockedShareKey { metadata, validator },
                &bigdecimal::zero()
            );
        if (bigdecimal::is_zero(*total_locked_share)
            || bigdecimal::is_zero(*total_share)) {
            return *share
        };

        // share * total_locekd_share / total_share
        bigdecimal::div(bigdecimal::mul(*share, *total_locked_share), *total_share)
    }

    fun locked_share_to_amount(
        staking_account: &StakingAccount,
        validator: String,
        metadata: Object<Metadata>,
        total_share: &BigDecimal,
        locked_share: &BigDecimal
    ): u64 {
        let share =
            locked_share_to_share(
                staking_account,
                validator,
                metadata,
                total_share,
                locked_share
            );
        staking::share_to_amount(*string::bytes(&validator), &metadata, &share)
    }

    fun amount_to_locked_share(
        staking_account: &StakingAccount,
        validator: String,
        metadata: Object<Metadata>,
        total_share: &BigDecimal,
        amount: u64
    ): BigDecimal {
        let share = staking::amount_to_share(
            *string::bytes(&validator), &metadata, amount
        );
        share_to_locked_share(
            staking_account,
            validator,
            metadata,
            total_share,
            &share
        )
    }

    fun get_locked_share(
        staking_account: &StakingAccount,
        metadata: Object<Metadata>,
        release_time: u64,
        validator: String
    ): BigDecimal {
        let key = generate_delegation_key(metadata, release_time, validator);
        assert!(
            table::contains(&staking_account.delegations, key),
            error::not_found(EDELEGATION_NOT_FOUND)
        );
        *table::borrow(&staking_account.delegations, key)
    }

    fun get_exact_provide_amount(
        pair: Object<dex::Config>, coin_a_amount_in: u64, coin_b_amount_in: u64
    ): (u64, u64) {
        let pool_info = dex::get_pool_info(pair);
        let coin_a_amount = dex::get_coin_a_amount_from_pool_info_response(&pool_info);
        let coin_b_amount = dex::get_coin_b_amount_from_pool_info_response(&pool_info);
        let total_share = option::extract(&mut fungible_asset::supply(pair));

        // calculate the best coin amount
        if (total_share == 0) {
            (coin_a_amount_in, coin_b_amount_in)
        } else {
            let a_share_ratio =
                bigdecimal::from_ratio_u64(coin_a_amount_in, coin_a_amount);
            let b_share_ratio =
                bigdecimal::from_ratio_u64(coin_b_amount_in, coin_b_amount);
            if (bigdecimal::gt(a_share_ratio, b_share_ratio)) {
                coin_a_amount_in = bigdecimal::mul_by_u64_truncate(
                    b_share_ratio, coin_a_amount
                );
            } else {
                coin_b_amount_in = bigdecimal::mul_by_u64_truncate(
                    a_share_ratio, coin_b_amount
                );
            };

            (coin_a_amount_in, coin_b_amount_in)
        }
    }

    #[view]
    public fun get_staking_address(addr: address): address {
        object::create_object_address(
            &addr,
            generate_staking_account_seed(copy addr)
        )
    }

    #[view]
    public fun get_locked_delegations(
        addr: address
    ): vector<LockedDelegationResponse> acquires StakingAccount {
        let staking_account_addr = get_staking_address(addr);
        if (!exists<StakingAccount>(staking_account_addr)) {
            return vector[]
        };
        let staking_account = borrow_global<StakingAccount>(staking_account_addr);
        let iter =
            table::iter(
                &staking_account.delegations,
                option::none(),
                option::none(),
                1
            );

        let res = vector[];

        let delegations: SimpleMap<String, DelegationResponseInner> = simple_map::new();

        let metadata_denom_map: SimpleMap<Object<Metadata>, String> = simple_map::new();

        loop {
            if (!table::prepare<DelegationKey, BigDecimal>(iter)) { break };
            let (key, locked_share_ref) = table::next<DelegationKey, BigDecimal>(iter);
            let metadata = key.metadata;
            let validator = key.validator;

            if (!simple_map::contains_key(&delegations, &validator)) {
                let delegation =
                    get_delegation(
                        staking_account,
                        validator,
                        staking_account_addr,
                        false
                    );
                simple_map::add(&mut delegations, validator, delegation);
            };
            if (!simple_map::contains_key(&metadata_denom_map, &metadata)) {
                simple_map::add(
                    &mut metadata_denom_map,
                    metadata,
                    coin::metadata_to_denom(metadata)
                );
            };

            let delegation = simple_map::borrow(&delegations, &validator);
            let total_share =
                get_share(
                    &delegation.delegation.shares,
                    *simple_map::borrow(&metadata_denom_map, &metadata),
                    true
                );
            let amount =
                locked_share_to_amount(
                    staking_account,
                    validator,
                    metadata,
                    &total_share,
                    locked_share_ref
                );
            let release_time = table_key::decode_u64(key.release_time);

            vector::push_back(
                &mut res,
                LockedDelegationResponse {
                    metadata,
                    validator,
                    locked_share: *locked_share_ref,
                    amount,
                    release_time
                }
            );
        };

        res
    }

    #[test_only]
    use initia_std::mock_mstaking;

    #[test_only]
    public fun init_module_for_test(vip: &signer) {
        init_module(vip)
    }

    #[test_only]
    public fun mock_delegate(
        account: &signer,
        metadata: Object<Metadata>,
        amount: u64,
        release_time: u64,
        validator_address: String
    ) acquires StakingAccount, ModuleStore {
        let fa = coin::withdraw(account, metadata, amount);
        let (_, curr_time) = block::get_block_info();
        let module_store = borrow_global<ModuleStore>(@vip);
        assert!(
            release_time > curr_time + module_store.min_lock_period,
            error::invalid_argument(ESMALL_RELEASE_TIME)
        );

        let staking_account_signer = get_staking_account_signer(account);
        let staking_account_addr = signer::address_of(&staking_account_signer);
        let staking_account = borrow_global_mut<StakingAccount>(staking_account_addr);

        reentry_check(staking_account, true);
        let metadata = fungible_asset::metadata_from_asset(&fa);
        let amount = fungible_asset::amount(&fa);
        let denom = coin::metadata_to_denom(metadata);

        // deposit token to staking account addr
        coin::deposit(staking_account_addr, fa);

        let delegation =
            get_delegation(
                staking_account,
                validator_address,
                staking_account_addr,
                false
            );

        let share_before = get_share(&delegation.delegation.shares, denom, false);

        // delegate
        mock_mstaking::delegate(
            &staking_account_signer,
            validator_address,
            metadata,
            amount
        );

        // execute hook
        delegate_hook(
            &staking_account_signer,
            metadata,
            release_time,
            validator_address,
            share_before
        );
    }

    #[test_only]
    public fun mock_redelegate(
        account: &signer,
        metadata: Object<Metadata>,
        amount: Option<u64>, // if none, redelegate all
        src_release_time: u64,
        validator_src_address: String,
        dst_release_time: u64,
        validator_dst_address: String
    ) acquires StakingAccount, ModuleStore {
        let staking_account_signer = get_staking_account_signer(account);
        let staking_account_addr = signer::address_of(&staking_account_signer);
        let staking_account = borrow_global_mut<StakingAccount>(staking_account_addr);

        reentry_check(staking_account, true);
        assert!(
            dst_release_time >= src_release_time,
            error::invalid_argument(ESMALL_RELEASE_TIME)
        );
        // get current delegation shares
        let src_delegation =
            get_delegation(
                staking_account,
                validator_src_address,
                staking_account_addr,
                false
            );
        let locked_share =
            get_locked_share(
                staking_account,
                metadata,
                src_release_time,
                validator_src_address
            );
        let src_share_before =
            get_share(
                &src_delegation.delegation.shares,
                coin::metadata_to_denom(metadata),
                true
            );
        let dst_delegation =
            get_delegation(
                staking_account,
                validator_dst_address,
                staking_account_addr,
                false
            );
        let dst_share_before =
            get_share(
                &dst_delegation.delegation.shares,
                coin::metadata_to_denom(metadata),
                false
            );

        let locked_amount =
            locked_share_to_amount(
                staking_account,
                validator_src_address,
                metadata,
                &src_share_before,
                &locked_share
            );

        // get redelegate amount and share before
        let (amount, src_share_before) =
            if (option::is_none(&amount)) {
                // redelegate all
                (locked_amount, option::none())
            } else {
                let redelegate_amount = option::extract(&mut amount);
                assert!(redelegate_amount > 0, error::invalid_argument(EZERO_AMOUNT));
                assert!(
                    locked_amount >= redelegate_amount,
                    error::invalid_argument(ENOT_ENOUGH_DELEGATION)
                );

                (redelegate_amount, option::some(src_share_before))
            };

        // execute begin redelegate
        mock_mstaking::redelegate(
            &staking_account_signer,
            validator_src_address,
            validator_dst_address,
            metadata,
            amount
        );
        // execute redelegate hook
        redelegate_hook_v2(
            &staking_account_signer,
            metadata,
            src_release_time,
            validator_src_address,
            src_share_before,
            dst_release_time,
            validator_dst_address,
            dst_share_before
        );
    }

    #[test_only]
    public fun mock_undelegate(
        account: &signer,
        metadata: Object<Metadata>,
        amount: Option<u64>, // if none, undelegte all
        release_time: u64,
        validator: String
    ) acquires StakingAccount {
        let staking_account_signer = get_staking_account_signer(account);
        let staking_account_addr = signer::address_of(&staking_account_signer);
        let staking_account = borrow_global_mut<StakingAccount>(staking_account_addr);

        reentry_check(staking_account, true);

        // check can undelegate
        let (_, curr_time) = block::get_block_info();
        assert!(
            curr_time > release_time,
            error::invalid_state(ENOT_RELEASE)
        );
        // get current delegation share
        let delegation =
            get_delegation(
                staking_account,
                validator,
                staking_account_addr,
                false
            );
        let locked_share =
            get_locked_share(
                staking_account,
                metadata,
                release_time,
                validator
            );
        let share_before =
            get_share(
                &delegation.delegation.shares,
                coin::metadata_to_denom(metadata),
                true
            );

        let locked_amount =
            locked_share_to_amount(
                staking_account,
                validator,
                metadata,
                &share_before,
                &locked_share
            );

        // get undelegate amount and share before
        let (amount, share_before) =
            if (option::is_none(&amount)) {
                // undelegate all
                (locked_amount, option::none())
            } else {
                let undelegate_amount = option::extract(&mut amount);
                assert!(undelegate_amount > 0, error::invalid_argument(EZERO_AMOUNT));
                assert!(
                    locked_amount >= undelegate_amount,
                    error::invalid_argument(ENOT_ENOUGH_DELEGATION)
                );

                (undelegate_amount, option::some(share_before))
            };

        // execute undelegate
        mock_mstaking::undelegate(
            &staking_account_signer,
            validator,
            metadata,
            amount
        );

        // execute undelegate hook
        undelegate_hook(
            &staking_account_signer,
            metadata,
            release_time,
            validator,
            share_before
        );
    }

    const TEST_RELEASE_PERIOD: u64 = 1000;
    const DELEGATING_AMOUNT: u64 = 1000;

    #[
        test(
            chain = @initia_std,
            vip = @vip,
            delegator1 = @0x19c9b6007d21a996737ea527f46b160b0a057c37,
            delegator2 = @0x56ccf33c45b99546cd1da172cf6849395bbf8573
        )
    ]
    fun test_lock_staking_delegate_and_extend(
        chain: &signer,
        vip: &signer,
        delegator1: &signer,
        delegator2: &signer
    ) acquires ModuleStore, StakingAccount {
        mock_mstaking::initialize(chain);
        init_module_for_test(vip);
        let (_, time) = block::get_block_info();
        let release_time = time + TEST_RELEASE_PERIOD;
        let new_release_time = time + 2 * TEST_RELEASE_PERIOD;
        let metadata = mock_mstaking::get_lp_metadata();
        let validator = mock_mstaking::get_validator1();
        let val2 = mock_mstaking::get_validator2();

        let delegator1_addr = signer::address_of(delegator1);
        let delegator1_staking_account_addr = get_staking_address(delegator1_addr);
        let delegator2_addr = signer::address_of(delegator2);
        let delegator2_staking_account_addr = get_staking_address(delegator2_addr);
        // mock lp providing
        coin::transfer(
            chain,
            signer::address_of(delegator1),
            metadata,
            DELEGATING_AMOUNT
        );
        coin::transfer(
            chain,
            signer::address_of(delegator2),
            metadata,
            2 * DELEGATING_AMOUNT
        );

        // block increases
        utils::increase_block(1, 2);

        // delegate
        mock_delegate(
            delegator1,
            metadata,
            DELEGATING_AMOUNT,
            release_time,
            validator
        );

        // block increases
        utils::increase_block(1, 2);

        mock_delegate(
            delegator2,
            metadata,
            DELEGATING_AMOUNT,
            release_time,
            validator
        );

        // block increases
        utils::increase_block(1, 2);

        mock_delegate(
            delegator2,
            metadata,
            DELEGATING_AMOUNT,
            release_time,
            val2
        );

        // block increases
        utils::increase_block(1, 2);
        assert!(
            get_locked_delegations(signer::address_of(delegator1))
                == vector[
                    LockedDelegationResponse {
                        metadata,
                        validator,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: DELEGATING_AMOUNT,
                        release_time
                    }
                ],
            1
        );

        assert!(
            get_locked_delegations(signer::address_of(delegator2))
                == vector[
                    LockedDelegationResponse {
                        metadata,
                        validator,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: DELEGATING_AMOUNT,
                        release_time
                    },
                    LockedDelegationResponse {
                        metadata,
                        validator: val2,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: DELEGATING_AMOUNT,
                        release_time
                    }
                ],
            2
        );

        // check mstaking share and amount of mstaking
        assert!(
            get_delegation(
                borrow_global<StakingAccount>(delegator1_staking_account_addr),
                validator,
                delegator1_staking_account_addr,
                true
            ) == DelegationResponseInner {
                delegation: Delegation {
                    delegator_address: to_sdk(get_staking_address(delegator1_addr)),
                    validator_address: validator,
                    shares: vector[
                        DecCoin {
                            denom: coin::metadata_to_denom(metadata),
                            amount: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1)
                        }
                    ]
                },
                balance: vector[
                    Coin {
                        denom: coin::metadata_to_denom(metadata),
                        amount: DELEGATING_AMOUNT
                    }
                ]
            },
            3
        );

        assert!(
            get_delegation(
                borrow_global<StakingAccount>(delegator2_staking_account_addr),
                validator,
                delegator2_staking_account_addr,
                true
            ) == DelegationResponseInner {
                delegation: Delegation {
                    delegator_address: to_sdk(
                        get_staking_address(signer::address_of(delegator2))
                    ),
                    validator_address: validator,
                    shares: vector[
                        DecCoin {
                            denom: coin::metadata_to_denom(metadata),
                            amount: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1)
                        }
                    ]
                },
                balance: vector[
                    Coin {
                        denom: coin::metadata_to_denom(metadata),
                        amount: DELEGATING_AMOUNT
                    }
                ]
            },
            4
        );

        assert!(
            get_delegation(
                borrow_global<StakingAccount>(delegator2_staking_account_addr),
                val2,
                delegator2_staking_account_addr,
                true
            ) == DelegationResponseInner {
                delegation: Delegation {
                    delegator_address: to_sdk(
                        get_staking_address(signer::address_of(delegator2))
                    ),
                    validator_address: val2,
                    shares: vector[
                        DecCoin {
                            denom: coin::metadata_to_denom(metadata),
                            amount: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1)
                        }
                    ]
                },
                balance: vector[
                    Coin {
                        denom: coin::metadata_to_denom(metadata),
                        amount: DELEGATING_AMOUNT
                    }
                ]
            },
            5
        );
        //test extend
        extend(
            delegator1,
            metadata,
            option::none(),
            release_time,
            validator,
            new_release_time
        );

        assert!(
            get_locked_delegations(signer::address_of(delegator1))
                == vector[
                    LockedDelegationResponse {
                        metadata,
                        validator,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: DELEGATING_AMOUNT,
                        release_time: new_release_time
                    }
                ],
            6
        );
        // block increases
        utils::increase_block(1, 2);

        // delegator2 extend two positions of lock staking
        batch_extend(
            delegator2,
            vector[metadata, metadata],
            vector[option::none(), option::none()],
            vector[release_time, release_time],
            vector[validator, val2],
            vector[new_release_time, new_release_time]
        );

        assert!(
            get_locked_delegations(signer::address_of(delegator2))
                == vector[
                    LockedDelegationResponse {
                        metadata,
                        validator,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: DELEGATING_AMOUNT,
                        release_time: new_release_time
                    },
                    LockedDelegationResponse {
                        metadata,
                        validator: val2,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: DELEGATING_AMOUNT,
                        release_time: new_release_time
                    }
                ],
            7
        );

    }

    #[
        test(
            chain = @initia_std,
            vip = @vip,
            delegator1 = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun test_lock_staking_undelegate(
        chain: &signer, vip: &signer, delegator1: &signer
    ) acquires ModuleStore, StakingAccount {
        mock_mstaking::initialize(chain);
        init_module_for_test(vip);
        let (_, time) = block::get_block_info();
        let release_time = time + TEST_RELEASE_PERIOD;
        let metadata = mock_mstaking::get_lp_metadata();
        let validator = mock_mstaking::get_validator1();
        let val2 = mock_mstaking::get_validator2();
        let delegator1_addr = signer::address_of(delegator1);
        let delegator1_staking_account_addr = get_staking_address(delegator1_addr);

        // mock lp providing
        coin::transfer(
            chain,
            signer::address_of(delegator1),
            metadata,
            3 * DELEGATING_AMOUNT
        );

        // block increases
        utils::increase_block(1, 2);

        // delegate
        mock_delegate(
            delegator1,
            metadata,
            2 * DELEGATING_AMOUNT,
            release_time,
            validator
        );

        utils::increase_block(1, 2);

        mock_delegate(
            delegator1,
            metadata,
            DELEGATING_AMOUNT,
            release_time,
            val2
        );

        assert!(
            get_locked_delegations(signer::address_of(delegator1))
                == vector[
                    LockedDelegationResponse {
                        metadata,
                        validator,
                        amount: 2 * DELEGATING_AMOUNT,
                        locked_share: bigdecimal::from_ratio_u64(2 * DELEGATING_AMOUNT, 1),
                        release_time: TEST_RELEASE_PERIOD
                    },
                    LockedDelegationResponse {
                        metadata,
                        validator: val2,
                        amount: DELEGATING_AMOUNT,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        release_time: TEST_RELEASE_PERIOD
                    }
                ],
            1
        );

        assert!(
            get_delegation(
                borrow_global<StakingAccount>(delegator1_staking_account_addr),
                validator,
                delegator1_staking_account_addr,
                true
            ) == DelegationResponseInner {
                delegation: Delegation {
                    delegator_address: to_sdk(
                        get_staking_address(signer::address_of(delegator1))
                    ),
                    validator_address: validator,
                    shares: vector[
                        DecCoin {
                            denom: coin::metadata_to_denom(metadata),
                            amount: bigdecimal::from_ratio_u64(2 * DELEGATING_AMOUNT, 1)
                        }
                    ]
                },
                balance: vector[
                    Coin {
                        denom: coin::metadata_to_denom(metadata),
                        amount: 2 * DELEGATING_AMOUNT
                    }
                ]
            },
            2
        );

        assert!(
            get_delegation(
                borrow_global<StakingAccount>(delegator1_staking_account_addr),
                val2,
                delegator1_staking_account_addr,
                true
            ) == DelegationResponseInner {
                delegation: Delegation {
                    delegator_address: to_sdk(
                        get_staking_address(signer::address_of(delegator1))
                    ),
                    validator_address: val2,
                    shares: vector[
                        DecCoin {
                            denom: coin::metadata_to_denom(metadata),
                            amount: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1)
                        }
                    ]
                },
                balance: vector[
                    Coin {
                        denom: coin::metadata_to_denom(metadata),
                        amount: DELEGATING_AMOUNT
                    }
                ]
            },
            3
        );
        // block increases to release
        utils::increase_block(500, 1001);
        mock_undelegate(
            delegator1,
            metadata,
            option::some<u64>(DELEGATING_AMOUNT),
            release_time,
            validator
        );

        assert!(
            get_locked_delegations(signer::address_of(delegator1))
                == vector[
                    LockedDelegationResponse {
                        metadata,
                        validator,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: DELEGATING_AMOUNT,
                        release_time: TEST_RELEASE_PERIOD
                    },
                    LockedDelegationResponse {
                        metadata,
                        validator: val2,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: DELEGATING_AMOUNT,
                        release_time: TEST_RELEASE_PERIOD
                    }
                ],
            4
        );

        // check delegation share and amount
        assert!(
            get_delegation(
                borrow_global<StakingAccount>(delegator1_staking_account_addr),
                validator,
                delegator1_staking_account_addr,
                true
            ) == DelegationResponseInner {
                delegation: Delegation {
                    delegator_address: to_sdk(
                        get_staking_address(signer::address_of(delegator1))
                    ),
                    validator_address: validator,
                    shares: vector[
                        DecCoin {
                            denom: coin::metadata_to_denom(metadata),
                            amount: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1)
                        }
                    ]
                },
                balance: vector[
                    Coin {
                        denom: coin::metadata_to_denom(metadata),
                        amount: DELEGATING_AMOUNT
                    }
                ]
            },
            5
        );

        assert!(
            get_delegation(
                borrow_global<StakingAccount>(delegator1_staking_account_addr),
                val2,
                delegator1_staking_account_addr,
                true
            ) == DelegationResponseInner {
                delegation: Delegation {
                    delegator_address: to_sdk(
                        get_staking_address(signer::address_of(delegator1))
                    ),
                    validator_address: val2,
                    shares: vector[
                        DecCoin {
                            denom: coin::metadata_to_denom(metadata),
                            amount: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1)
                        }
                    ]
                },
                balance: vector[
                    Coin {
                        denom: coin::metadata_to_denom(metadata),
                        amount: DELEGATING_AMOUNT
                    }
                ]
            },
            6
        );
        // check unbonding entry
        assert!(
            get_unbonding_delegation(
                get_staking_address(signer::address_of(delegator1)), validator
            ) == UnbondingDelegationResponse {
                unbond: UnbondingDelegation {
                    delegator_address: to_sdk(
                        get_staking_address(signer::address_of(delegator1))
                    ),
                    validator_address: validator,
                    entries: vector[
                        UnbondingDelegationEntry {
                            creation_height: 502,
                            completion_time: string::utf8(b""), // mock mstaking module doesn't set compleation time
                            initial_balance: vector[
                                Coin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: DELEGATING_AMOUNT
                                }
                            ],
                            balance: vector[
                                Coin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: DELEGATING_AMOUNT
                                }
                            ],
                            unbonding_id: 1,
                            unbonding_on_hold_ref_count: 0
                        }
                    ]
                }
            },
            7
        );

        utils::increase_block(1, 2);
        mock_undelegate(
            delegator1,
            metadata,
            option::none<u64>(),
            release_time,
            validator
        );

        // check unbonding entry
        assert!(
            get_unbonding_delegation(
                get_staking_address(signer::address_of(delegator1)), validator
            ) == UnbondingDelegationResponse {
                unbond: UnbondingDelegation {
                    delegator_address: to_sdk(
                        get_staking_address(signer::address_of(delegator1))
                    ),
                    validator_address: validator,
                    entries: vector[
                        UnbondingDelegationEntry {
                            creation_height: 502,
                            completion_time: string::utf8(b""), // mock mstaking module doesn't set compleation time
                            initial_balance: vector[
                                Coin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: DELEGATING_AMOUNT
                                }
                            ],
                            balance: vector[
                                Coin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: DELEGATING_AMOUNT
                                }
                            ],
                            unbonding_id: 1,
                            unbonding_on_hold_ref_count: 0
                        },
                        UnbondingDelegationEntry {
                            creation_height: 503,
                            completion_time: string::utf8(b""), // mock mstaking module doesn't set compleation time
                            initial_balance: vector[
                                Coin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: DELEGATING_AMOUNT
                                }
                            ],
                            balance: vector[
                                Coin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: DELEGATING_AMOUNT
                                }
                            ],
                            unbonding_id: 2,
                            unbonding_on_hold_ref_count: 0
                        }
                    ]
                }
            },
            8
        );

        assert!(
            get_locked_delegations(signer::address_of(delegator1))
                == vector[
                    LockedDelegationResponse {
                        metadata,
                        validator: val2,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: DELEGATING_AMOUNT,
                        release_time
                    }
                ],
            9
        );

        // check mstaking share and amount of mstaking
        assert!(
            get_delegation(
                borrow_global<StakingAccount>(delegator1_staking_account_addr),
                val2,
                delegator1_staking_account_addr,
                true
            ) == DelegationResponseInner {
                delegation: Delegation {
                    delegator_address: to_sdk(
                        get_staking_address(signer::address_of(delegator1))
                    ),
                    validator_address: val2,
                    shares: vector[
                        DecCoin {
                            denom: coin::metadata_to_denom(metadata),
                            amount: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1)
                        }
                    ]
                },
                balance: vector[
                    Coin {
                        denom: coin::metadata_to_denom(metadata),
                        amount: DELEGATING_AMOUNT
                    }
                ]
            },
            10
        );
        // pass the unbonding period
        utils::increase_block(500, mock_mstaking::get_unbonding_period());
        // clear the unbonding entry
        mock_mstaking::clear_completed_entries();
        assert!(
            coin::balance(
                get_staking_address(signer::address_of(delegator1)), metadata
            ) == 2 * DELEGATING_AMOUNT,
            11
        );

        withdraw_asset(
            delegator1,
            metadata,
            option::some(DELEGATING_AMOUNT)
        );

        assert!(
            coin::balance(signer::address_of(delegator1), metadata) == DELEGATING_AMOUNT,
            12
        );
        withdraw_asset(delegator1, metadata, option::none());
        assert!(
            coin::balance(signer::address_of(delegator1), metadata)
                == 2 * DELEGATING_AMOUNT,
            13
        );
    }

    #[
        test(
            chain = @initia_std,
            vip = @vip,
            delegator1 = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun test_lock_staking_redelegate(
        chain: &signer, vip: &signer, delegator1: &signer
    ) acquires ModuleStore, StakingAccount {
        mock_mstaking::initialize(chain);
        init_module_for_test(vip);
        let (_, time) = block::get_block_info();
        let release_time = time + TEST_RELEASE_PERIOD;
        let new_release_time = time + 2 * TEST_RELEASE_PERIOD;
        let metadata = mock_mstaking::get_lp_metadata();
        let src_val = mock_mstaking::get_validator1();
        let dst_val = mock_mstaking::get_validator2();
        let delegator1_addr = signer::address_of(delegator1);
        let delegator1_staking_addr = get_staking_address(delegator1_addr);
        // mock lp providing
        coin::transfer(
            chain,
            delegator1_addr,
            metadata,
            3 * DELEGATING_AMOUNT
        );

        // block increases
        utils::increase_block(1, 2);

        // delegate
        mock_delegate(
            delegator1,
            metadata,
            2 * DELEGATING_AMOUNT,
            release_time,
            src_val
        );

        assert!(
            get_locked_delegations(delegator1_addr)
                == vector[
                    LockedDelegationResponse {
                        metadata,
                        validator: src_val,
                        locked_share: bigdecimal::from_ratio_u64(2 * DELEGATING_AMOUNT, 1),
                        amount: 2 * DELEGATING_AMOUNT,
                        release_time
                    }
                ],
            1
        );

        utils::increase_block(1, 2);

        mock_redelegate(
            delegator1,
            metadata,
            option::some<u64>(DELEGATING_AMOUNT),
            release_time,
            src_val,
            release_time,
            dst_val
        );

        // block increases to release
        utils::increase_block(500, 1001);
        assert!(
            get_redelegations(to_sdk(delegator1_staking_addr), src_val, dst_val)
                == RedelegationsResponse {
                    redelegation_responses: vector[
                        RedelegationResponse {
                            redelegation: Redelegation {
                                delegator_address: to_sdk(delegator1_staking_addr),
                                validator_src_address: src_val,
                                validator_dst_address: dst_val,
                                entries: option::none()
                            },
                            entries: vector[
                                RedelegationEntryResponse {
                                    redelegation_entry: RedelegationEntry {
                                        creation_height: 2,
                                        completion_time: string::utf8(b""),
                                        initial_balance: vector[
                                            Coin {
                                                denom: string::utf8(b"INIT-USDC"),
                                                amount: DELEGATING_AMOUNT
                                            }
                                        ],
                                        shares_dst: vector[
                                            DecCoin {
                                                denom: string::utf8(b"INIT-USDC"),
                                                amount: bigdecimal::from_ratio_u64(
                                                    DELEGATING_AMOUNT, 1
                                                )
                                            }
                                        ],
                                        unbonding_id: 1
                                    },
                                    balance: vector[
                                        Coin {
                                            denom: string::utf8(b"INIT-USDC"),
                                            amount: DELEGATING_AMOUNT
                                        }
                                    ]
                                }
                            ]
                        }
                    ],
                    pagination: option::none()
                },
            2
        );
        assert!(
            get_locked_delegations(delegator1_addr)
                == vector[
                    LockedDelegationResponse {
                        metadata,
                        validator: src_val,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: DELEGATING_AMOUNT,
                        release_time
                    },
                    LockedDelegationResponse {
                        metadata,
                        validator: dst_val,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: DELEGATING_AMOUNT,
                        release_time
                    }
                ],
            3
        );

        assert!(coin::balance(delegator1_staking_addr, metadata) == 0, 4);

        // pass the unbonding period
        utils::increase_block(500, mock_mstaking::get_unbonding_period());
        // clear the unbonding entry
        mock_mstaking::clear_completed_entries();

        assert!(coin::balance(delegator1_staking_addr, metadata) == 0, 5);

        // redelegate all of total amount to dst_val
        mock_redelegate(
            delegator1,
            metadata,
            option::none<u64>(),
            release_time,
            src_val,
            new_release_time,
            dst_val
        );

        // block increases to release
        utils::increase_block(500, 1001);

        assert!(
            get_redelegations(to_sdk(delegator1_staking_addr), src_val, dst_val)
                == RedelegationsResponse {
                    redelegation_responses: vector[
                        RedelegationResponse {
                            redelegation: Redelegation {
                                delegator_address: to_sdk(delegator1_staking_addr),
                                validator_src_address: src_val,
                                validator_dst_address: dst_val,
                                entries: option::none()
                            },
                            entries: vector[
                                RedelegationEntryResponse {
                                    redelegation_entry: RedelegationEntry {
                                        creation_height: 1002,
                                        completion_time: string::utf8(b""),
                                        initial_balance: vector[
                                            Coin {
                                                denom: string::utf8(b"INIT-USDC"),
                                                amount: DELEGATING_AMOUNT
                                            }
                                        ],
                                        shares_dst: vector[
                                            DecCoin {
                                                denom: string::utf8(b"INIT-USDC"),
                                                amount: bigdecimal::from_ratio_u64(
                                                    DELEGATING_AMOUNT, 1
                                                )
                                            }
                                        ],
                                        unbonding_id: 2
                                    },
                                    balance: vector[
                                        Coin {
                                            denom: string::utf8(b"INIT-USDC"),
                                            amount: DELEGATING_AMOUNT
                                        }
                                    ]
                                }
                            ]
                        }
                    ],
                    pagination: option::none()
                },
            6
        );
        assert!(
            get_locked_delegations(delegator1_addr)
                == vector[
                    LockedDelegationResponse {
                        metadata,
                        validator: dst_val,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: DELEGATING_AMOUNT,
                        release_time: release_time
                    },
                    LockedDelegationResponse {
                        metadata,
                        validator: dst_val,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: DELEGATING_AMOUNT,
                        release_time: new_release_time
                    }
                ],
            7
        );

        assert!(coin::balance(delegator1_staking_addr, metadata) == 0, 8);

        // pass the unbonding period
        utils::increase_block(500, mock_mstaking::get_unbonding_period());
        // clear the unbonding entry
        mock_mstaking::clear_completed_entries();

        assert!(coin::balance(delegator1_staking_addr, metadata) == 0, 9);
    }

    #[
        test(
            chain = @initia_std,
            vip = @vip,
            delegator1 = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun test_delegate_and_slash(
        chain: &signer, vip: &signer, delegator1: &signer
    ) acquires ModuleStore, StakingAccount {
        mock_mstaking::initialize(chain);
        init_module_for_test(vip);
        let (_, time) = block::get_block_info();
        let release_time = time + TEST_RELEASE_PERIOD;
        let metadata = mock_mstaking::get_lp_metadata();
        let validator = mock_mstaking::get_validator1();
        let delegator1_addr = signer::address_of(delegator1);
        let delegator1_staking_account_addr = get_staking_address(delegator1_addr);
        // mock lp providing
        coin::transfer(
            chain,
            delegator1_addr,
            metadata,
            DELEGATING_AMOUNT
        );

        // block increases
        utils::increase_block(1, 2);

        // delegate
        mock_delegate(
            delegator1,
            metadata,
            DELEGATING_AMOUNT,
            release_time,
            validator
        );

        assert!(
            get_locked_delegations(delegator1_addr)
                == vector[
                    LockedDelegationResponse {
                        metadata,
                        validator,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: DELEGATING_AMOUNT,
                        release_time
                    }
                ],
            1
        );
        assert!(
            get_delegation(
                borrow_global<StakingAccount>(delegator1_staking_account_addr),
                validator,
                delegator1_staking_account_addr,
                true
            ) == DelegationResponseInner {
                delegation: Delegation {
                    delegator_address: to_sdk(
                        get_staking_address(signer::address_of(delegator1))
                    ),
                    validator_address: validator,
                    shares: vector[
                        DecCoin {
                            denom: coin::metadata_to_denom(metadata),
                            amount: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1)
                        }
                    ]
                },
                balance: vector[
                    Coin {
                        denom: coin::metadata_to_denom(metadata),
                        amount: DELEGATING_AMOUNT
                    }
                ]
            },
            2
        );
        // block increases
        utils::increase_block(1, 2);
        // 10% slashing
        mock_mstaking::slash(validator, mock_mstaking::get_slash_factor());

        // check locked delgations share constant, amount decreased by 10%
        assert!(
            get_locked_delegations(signer::address_of(delegator1))
                == vector[
                    LockedDelegationResponse {
                        metadata,
                        validator,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: DELEGATING_AMOUNT * 9 / 10,
                        release_time
                    }
                ],
            3
        );

        assert!(
            get_delegation(
                borrow_global<StakingAccount>(delegator1_staking_account_addr),
                validator,
                delegator1_staking_account_addr,
                true
            ) == DelegationResponseInner {
                delegation: Delegation {
                    delegator_address: to_sdk(
                        get_staking_address(signer::address_of(delegator1))
                    ),
                    validator_address: validator,
                    shares: vector[
                        DecCoin {
                            denom: coin::metadata_to_denom(metadata),
                            amount: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1)
                        }
                    ]
                },
                balance: vector[
                    Coin {
                        denom: coin::metadata_to_denom(metadata),
                        amount: DELEGATING_AMOUNT * 9 / 10
                    }
                ]
            },
            4
        );

    }

    #[
        test(
            chain = @initia_std,
            vip = @vip,
            delegator1 = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun test_undelegate_and_slash(
        chain: &signer, vip: &signer, delegator1: &signer
    ) acquires ModuleStore, StakingAccount {
        mock_mstaking::initialize(chain);
        init_module_for_test(vip);
        let (_, time) = block::get_block_info();
        let release_time = time + TEST_RELEASE_PERIOD;
        let metadata = mock_mstaking::get_lp_metadata();
        let validator = mock_mstaking::get_validator1();

        let delegator1_addr = signer::address_of(delegator1);
        let delegator1_staking_account_addr = get_staking_address(delegator1_addr);
        // mock lp providing
        coin::transfer(
            chain,
            signer::address_of(delegator1),
            metadata,
            2 * DELEGATING_AMOUNT
        );

        // block increases
        utils::increase_block(1, 2);

        // delegate
        mock_delegate(
            delegator1,
            metadata,
            2 * DELEGATING_AMOUNT,
            release_time,
            validator
        );

        // pass the unbonding period
        utils::increase_block(500, mock_mstaking::get_unbonding_period());

        mock_undelegate(
            delegator1,
            metadata,
            option::some(DELEGATING_AMOUNT),
            release_time,
            validator
        );

        assert!(
            get_unbonding_delegation(delegator1_staking_account_addr, validator)
                == UnbondingDelegationResponse {
                    unbond: UnbondingDelegation {
                        delegator_address: to_sdk(delegator1_staking_account_addr),
                        validator_address: validator,
                        entries: vector[
                            UnbondingDelegationEntry {
                                creation_height: 501,
                                completion_time: string::utf8(b""), // mock mstaking module doesn't set compleation time
                                initial_balance: vector[
                                    Coin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: DELEGATING_AMOUNT
                                    }
                                ],
                                balance: vector[
                                    Coin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: DELEGATING_AMOUNT
                                    }
                                ],
                                unbonding_id: 1,
                                unbonding_on_hold_ref_count: 0
                            }
                        ]
                    }
                },
            1
        );

        // 10% slashing
        mock_mstaking::slash(validator, mock_mstaking::get_slash_factor());

        assert!(
            get_locked_delegations(signer::address_of(delegator1))
                == vector[
                    LockedDelegationResponse {
                        metadata,
                        validator,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: DELEGATING_AMOUNT * 9 / 10,
                        release_time
                    }
                ],
            2
        );

        assert!(
            get_delegation(
                borrow_global<StakingAccount>(delegator1_staking_account_addr),
                validator,
                delegator1_staking_account_addr,
                true
            ) == DelegationResponseInner {
                delegation: Delegation {
                    delegator_address: to_sdk(delegator1_staking_account_addr),
                    validator_address: validator,
                    shares: vector[
                        DecCoin {
                            denom: coin::metadata_to_denom(metadata),
                            amount: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1)
                        }
                    ]
                },
                balance: vector[
                    Coin {
                        denom: coin::metadata_to_denom(metadata),
                        amount: DELEGATING_AMOUNT * 9 / 10
                    }
                ]
            },
            3
        );

        assert!(
            get_unbonding_delegation(delegator1_staking_account_addr, validator)
                == UnbondingDelegationResponse {
                    unbond: UnbondingDelegation {
                        delegator_address: to_sdk(delegator1_staking_account_addr),
                        validator_address: validator,
                        entries: vector[
                            UnbondingDelegationEntry {
                                creation_height: 501,
                                completion_time: string::utf8(b""), // mock mstaking module doesn't set compleation time
                                initial_balance: vector[
                                    Coin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: DELEGATING_AMOUNT
                                    }
                                ],
                                balance: vector[
                                    Coin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: DELEGATING_AMOUNT * 9 / 10
                                    }
                                ],
                                unbonding_id: 1,
                                unbonding_on_hold_ref_count: 0
                            }
                        ]
                    }
                },
            4
        );

    }

    // slash the delegation of dst
    #[
        test(
            chain = @initia_std,
            vip = @vip,
            delegator1 = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun test_redelegate_and_slash1(
        chain: &signer, vip: &signer, delegator1: &signer
    ) acquires ModuleStore, StakingAccount {
        mock_mstaking::initialize(chain);
        init_module_for_test(vip);
        let (_, time) = block::get_block_info();
        let release_time = time + TEST_RELEASE_PERIOD;
        let new_release_time = time + TEST_RELEASE_PERIOD * 2;
        let metadata = mock_mstaking::get_lp_metadata();
        let validator = mock_mstaking::get_validator1();
        let val2 = mock_mstaking::get_validator2();
        let delegator1_addr = signer::address_of(delegator1);
        let delegator1_staking_account_addr = get_staking_address(delegator1_addr);

        // mock lp providing
        coin::transfer(
            chain,
            signer::address_of(delegator1),
            metadata,
            2 * DELEGATING_AMOUNT
        );

        // block increases
        utils::increase_block(1, 2);

        // delegate to val
        mock_delegate(
            delegator1,
            metadata,
            2 * DELEGATING_AMOUNT,
            release_time,
            validator
        );

        // block increases
        utils::increase_block(1, 2);

        // redelegate to val2
        mock_redelegate(
            delegator1,
            metadata,
            option::some(DELEGATING_AMOUNT),
            release_time,
            validator,
            new_release_time,
            val2
        );

        // 10% slashing
        mock_mstaking::slash(validator, mock_mstaking::get_slash_factor());

        // check share locked share constant
        assert!(
            get_locked_delegations(signer::address_of(delegator1))
                == vector[
                    LockedDelegationResponse {
                        metadata,
                        validator,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: 9 * DELEGATING_AMOUNT / 10,
                        release_time
                    },
                    LockedDelegationResponse {
                        metadata,
                        validator: val2,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: 9 * DELEGATING_AMOUNT / 10,
                        release_time: new_release_time
                    }
                ],
            1
        );
        // check cosmos mstaking amount of val decreased by 10%
        assert!(
            get_delegation(
                borrow_global<StakingAccount>(delegator1_staking_account_addr),
                validator,
                delegator1_staking_account_addr,
                true
            ) == DelegationResponseInner {
                delegation: Delegation {
                    delegator_address: to_sdk(
                        get_staking_address(signer::address_of(delegator1))
                    ),
                    validator_address: validator,
                    shares: vector[
                        DecCoin {
                            denom: coin::metadata_to_denom(metadata),
                            amount: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1)
                        }
                    ]
                },
                balance: vector[
                    Coin {
                        denom: coin::metadata_to_denom(metadata),
                        amount: 9 * DELEGATING_AMOUNT / 10
                    }
                ]
            },
            2
        );
        // check cosmos mstaking share and amount of val2 decreased by 10%
        assert!(
            get_delegation(
                borrow_global<StakingAccount>(delegator1_staking_account_addr),
                val2,
                delegator1_staking_account_addr,
                true
            ) == DelegationResponseInner {
                delegation: Delegation {
                    delegator_address: to_sdk(
                        get_staking_address(signer::address_of(delegator1))
                    ),
                    validator_address: val2,
                    shares: vector[
                        DecCoin {
                            denom: coin::metadata_to_denom(metadata),
                            amount: bigdecimal::from_ratio_u64(
                                DELEGATING_AMOUNT * 9 / 10, 1
                            )
                        }
                    ]
                },
                balance: vector[
                    Coin {
                        denom: coin::metadata_to_denom(metadata),
                        amount: 9 * DELEGATING_AMOUNT / 10
                    }
                ]
            },
            3
        );

    }

    // slash only on the unbonding of dst
    #[
        test(
            chain = @initia_std,
            vip = @vip,
            delegator1 = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun test_redelegate_and_slash2(
        chain: &signer, vip: &signer, delegator1: &signer
    ) acquires ModuleStore, StakingAccount {
        mock_mstaking::initialize(chain);
        init_module_for_test(vip);
        let (_, time) = block::get_block_info();
        let release_time = time + TEST_RELEASE_PERIOD;
        let new_release_time = time + TEST_RELEASE_PERIOD * 2;
        let metadata = mock_mstaking::get_lp_metadata();
        let validator = mock_mstaking::get_validator1();
        let val2 = mock_mstaking::get_validator2();
        let delegator1_addr = signer::address_of(delegator1);
        let delegator1_staking_account_addr = get_staking_address(delegator1_addr);

        // mock lp providing
        coin::transfer(
            chain,
            signer::address_of(delegator1),
            metadata,
            3 * DELEGATING_AMOUNT
        );

        // block increases
        utils::increase_block(1, 2);

        // delegate to val
        mock_delegate(
            delegator1,
            metadata,
            3 * DELEGATING_AMOUNT,
            release_time,
            validator
        );

        // block increases
        utils::increase_block(1, 2);

        // redelegate to val2
        mock_redelegate(
            delegator1,
            metadata,
            option::some(2 * DELEGATING_AMOUNT),
            release_time,
            validator,
            new_release_time,
            val2
        );

        // pass the release period
        utils::increase_block(1000, new_release_time);

        // undelegate val2
        mock_undelegate(
            delegator1,
            metadata,
            option::some(DELEGATING_AMOUNT),
            new_release_time,
            val2
        );

        // 10% slashing
        mock_mstaking::slash(validator, mock_mstaking::get_slash_factor());

        // check locked share constant
        assert!(
            get_locked_delegations(signer::address_of(delegator1))
                == vector[
                    LockedDelegationResponse {
                        metadata,
                        validator,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: 9 * DELEGATING_AMOUNT / 10,
                        release_time
                    },
                    LockedDelegationResponse {
                        metadata,
                        validator: val2,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: DELEGATING_AMOUNT,
                        release_time: new_release_time
                    }
                ],
            1
        );
        // check cosmos mstaking amount of val decreased by 10%
        assert!(
            get_delegation(
                borrow_global<StakingAccount>(delegator1_staking_account_addr),
                validator,
                delegator1_staking_account_addr,
                true
            ) == DelegationResponseInner {
                delegation: Delegation {
                    delegator_address: to_sdk(
                        get_staking_address(signer::address_of(delegator1))
                    ),
                    validator_address: validator,
                    shares: vector[
                        DecCoin {
                            denom: coin::metadata_to_denom(metadata),
                            amount: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1)
                        }
                    ]
                },
                balance: vector[
                    Coin {
                        denom: coin::metadata_to_denom(metadata),
                        amount: 9 * DELEGATING_AMOUNT / 10
                    }
                ]
            },
            2
        );

        // check cosmos mstaking share and amount of val2 not decreased
        assert!(
            get_delegation(
                borrow_global<StakingAccount>(delegator1_staking_account_addr),
                val2,
                delegator1_staking_account_addr,
                true
            ) == DelegationResponseInner {
                delegation: Delegation {
                    delegator_address: to_sdk(
                        get_staking_address(signer::address_of(delegator1))
                    ),
                    validator_address: val2,
                    shares: vector[
                        DecCoin {
                            denom: coin::metadata_to_denom(metadata),
                            amount: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1)
                        }
                    ]
                },
                balance: vector[
                    Coin {
                        denom: coin::metadata_to_denom(metadata),
                        amount: DELEGATING_AMOUNT
                    }
                ]
            },
            3
        );

        // check cosmos mstaking unbonding entry amount of val2 decreased by 20% by slashing val1
        assert!(
            get_unbonding_delegation(delegator1_staking_account_addr, val2)
                == UnbondingDelegationResponse {
                    unbond: UnbondingDelegation {
                        delegator_address: to_sdk(delegator1_staking_account_addr),
                        validator_address: val2,
                        entries: vector[
                            UnbondingDelegationEntry {
                                creation_height: 1002,
                                completion_time: string::utf8(b""), // mock mstaking module doesn't set compleation time
                                initial_balance: vector[
                                    Coin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: DELEGATING_AMOUNT
                                    }
                                ],
                                balance: vector[
                                    Coin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: 8 * DELEGATING_AMOUNT / 10
                                    }
                                ],
                                unbonding_id: 2,
                                unbonding_on_hold_ref_count: 0
                            }
                        ]
                    }
                },
            7
        );

    }

    // slash unbonding entry and delegation of dst
    #[
        test(
            chain = @initia_std,
            vip = @vip,
            delegator1 = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun test_redelegate_and_slash3(
        chain: &signer, vip: &signer, delegator1: &signer
    ) acquires ModuleStore, StakingAccount {
        mock_mstaking::initialize(chain);
        init_module_for_test(vip);
        let (_, time) = block::get_block_info();
        let release_time = time + TEST_RELEASE_PERIOD;
        let new_release_time = time + TEST_RELEASE_PERIOD * 2;
        let metadata = mock_mstaking::get_lp_metadata();
        let validator = mock_mstaking::get_validator1();
        let val2 = mock_mstaking::get_validator2();
        let delegator1_addr = signer::address_of(delegator1);
        let delegator1_staking_account_addr = get_staking_address(delegator1_addr);

        // mock lp providing
        coin::transfer(
            chain,
            signer::address_of(delegator1),
            metadata,
            3 * DELEGATING_AMOUNT
        );

        // block increases
        utils::increase_block(1, 2);

        // delegate to val
        mock_delegate(
            delegator1,
            metadata,
            3 * DELEGATING_AMOUNT,
            release_time,
            validator
        );

        // block increases
        utils::increase_block(1, 2);

        // redelegate to val2
        mock_redelegate(
            delegator1,
            metadata,
            option::some(2 * DELEGATING_AMOUNT),
            release_time,
            validator,
            new_release_time,
            val2
        );

        // pass the release period
        utils::increase_block(1000, new_release_time);

        // undelegate val2 100
        mock_undelegate(
            delegator1,
            metadata,
            option::some(DELEGATING_AMOUNT / 10),
            new_release_time,
            val2
        );

        // 10% slashing: -200
        mock_mstaking::slash(validator, mock_mstaking::get_slash_factor());
        // check locked share constant
        assert!(
            get_locked_delegations(signer::address_of(delegator1))
                == vector[
                    LockedDelegationResponse {
                        metadata,
                        validator,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: 9 * DELEGATING_AMOUNT / 10,
                        release_time
                    },
                    LockedDelegationResponse {
                        metadata,
                        validator: val2,
                        locked_share: bigdecimal::from_ratio_u64(
                            19 * DELEGATING_AMOUNT / 10, 1
                        ), // it's not same mstaking share
                        amount: 18 * DELEGATING_AMOUNT / 10,
                        release_time: new_release_time
                    }
                ],
            1
        );
        // check cosmos mstaking amount of val decreased by 10%
        assert!(
            get_delegation(
                borrow_global<StakingAccount>(delegator1_staking_account_addr),
                validator,
                delegator1_staking_account_addr,
                true
            ) == DelegationResponseInner {
                delegation: Delegation {
                    delegator_address: to_sdk(
                        get_staking_address(signer::address_of(delegator1))
                    ),
                    validator_address: validator,
                    shares: vector[
                        DecCoin {
                            denom: coin::metadata_to_denom(metadata),
                            amount: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1)
                        }
                    ]
                },
                balance: vector[
                    Coin {
                        denom: coin::metadata_to_denom(metadata),
                        amount: 9 * DELEGATING_AMOUNT / 10
                    }
                ]
            },
            2
        );

        // check cosmos mstaking share and amount of val2 decreased
        assert!(
            get_delegation(
                borrow_global<StakingAccount>(delegator1_staking_account_addr),
                val2,
                delegator1_staking_account_addr,
                true
            ) == DelegationResponseInner {
                delegation: Delegation {
                    delegator_address: to_sdk(
                        get_staking_address(signer::address_of(delegator1))
                    ),
                    validator_address: val2,
                    shares: vector[
                        DecCoin {
                            denom: coin::metadata_to_denom(metadata),
                            amount: bigdecimal::from_ratio_u64(
                                18 * DELEGATING_AMOUNT / 10, 1
                            )
                        }
                    ]
                },
                balance: vector[
                    Coin {
                        denom: coin::metadata_to_denom(metadata),
                        amount: 18 * DELEGATING_AMOUNT / 10
                    }
                ]
            },
            3
        );

        // check cosmos mstaking unbonding entry amount of val2 decreased by 20% by slashing val1
        assert!(
            get_unbonding_delegation(delegator1_staking_account_addr, val2)
                == UnbondingDelegationResponse {
                    unbond: UnbondingDelegation {
                        delegator_address: to_sdk(delegator1_staking_account_addr),
                        validator_address: val2,
                        entries: vector[
                            UnbondingDelegationEntry {
                                creation_height: 1002,
                                completion_time: string::utf8(b""), // mock mstaking module doesn't set compleation time
                                initial_balance: vector[
                                    Coin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: DELEGATING_AMOUNT / 10
                                    }
                                ],
                                balance: vector[Coin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: 0
                                }],
                                unbonding_id: 2,
                                unbonding_on_hold_ref_count: 0
                            }
                        ]
                    }
                },
            4
        );

    }

    // Test merging of existing delegation when the user makes duplicated lock staking
    // Verifies that the delegation key (validator, user, release time) is correctly merged
    // upon extension or new delegation and redelegations, rather than creating a new delegation
    #[
        test(
            chain = @initia_std,
            vip = @vip,
            delegator1 = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    fun test_merge_lock_staking(
        chain: &signer, vip: &signer, delegator1: &signer
    ) acquires ModuleStore, StakingAccount {
        mock_mstaking::initialize(chain);
        init_module_for_test(vip);
        let (_, time) = block::get_block_info();
        let release_time = time + TEST_RELEASE_PERIOD;
        let metadata = mock_mstaking::get_lp_metadata();
        let validator = mock_mstaking::get_validator1();
        let val2 = mock_mstaking::get_validator2();

        // mock lp providing
        coin::transfer(
            chain,
            signer::address_of(delegator1),
            metadata,
            4 * DELEGATING_AMOUNT
        );

        // block increases
        utils::increase_block(1, 2);

        // delegate
        mock_delegate(
            delegator1,
            metadata,
            DELEGATING_AMOUNT,
            release_time,
            validator
        );
        utils::increase_block(1, 2);

        mock_delegate(
            delegator1,
            metadata,
            DELEGATING_AMOUNT,
            release_time,
            val2
        );
        utils::increase_block(1, 2);

        assert!(
            get_locked_delegations(signer::address_of(delegator1))
                == vector[
                    LockedDelegationResponse {
                        metadata,
                        validator,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: DELEGATING_AMOUNT,
                        release_time
                    },
                    LockedDelegationResponse {
                        metadata,
                        validator: val2,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: DELEGATING_AMOUNT,
                        release_time
                    }
                ],
            1
        );
        // merge
        mock_delegate(
            delegator1,
            metadata,
            2 * DELEGATING_AMOUNT,
            release_time,
            validator
        );
        utils::increase_block(1, 2);

        assert!(
            get_locked_delegations(signer::address_of(delegator1))
                == vector[
                    LockedDelegationResponse {
                        metadata,
                        validator,
                        locked_share: bigdecimal::from_ratio_u64(3 * DELEGATING_AMOUNT, 1),
                        amount: 3 * DELEGATING_AMOUNT,
                        release_time
                    },
                    LockedDelegationResponse {
                        metadata,
                        validator: val2,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: DELEGATING_AMOUNT,
                        release_time
                    }
                ],
            2
        );

        mock_redelegate(
            delegator1,
            metadata,
            option::some(2 * DELEGATING_AMOUNT),
            release_time,
            validator,
            release_time,
            val2
        );
        utils::increase_block(1, 2);

        assert!(
            get_locked_delegations(signer::address_of(delegator1))
                == vector[
                    LockedDelegationResponse {
                        metadata,
                        validator,
                        locked_share: bigdecimal::from_ratio_u64(DELEGATING_AMOUNT, 1),
                        amount: DELEGATING_AMOUNT,
                        release_time
                    },
                    LockedDelegationResponse {
                        metadata,
                        validator: val2,
                        locked_share: bigdecimal::from_ratio_u64(3 * DELEGATING_AMOUNT, 1),
                        amount: 3 * DELEGATING_AMOUNT,
                        release_time
                    }
                ],
            3
        );
    }

    // fail test when the user delegates lock staking over than max_delegation_slot
    #[
        test(
            chain = @initia_std,
            vip = @vip,
            delegator1 = @0x19c9b6007d21a996737ea527f46b160b0a057c37
        )
    ]
    #[expected_failure(abort_code = 0x3000D, location = Self)]
    fun fail_test_merge_lock_staking_over_max_slots(
        chain: &signer, vip: &signer, delegator1: &signer
    ) acquires ModuleStore, StakingAccount {
        let max_delegation_slot = 4;
        mock_mstaking::initialize(chain);
        init_module_for_test(vip);
        let (_, time) = block::get_block_info();
        let release_time = time + TEST_RELEASE_PERIOD;
        let metadata = mock_mstaking::get_lp_metadata();
        let validator = mock_mstaking::get_validator1();
        update_params(
            chain,
            option::none(),
            option::none(),
            option::some(max_delegation_slot)
        );

        // mock lp providing
        coin::transfer(
            chain,
            signer::address_of(delegator1),
            metadata,
            5 * DELEGATING_AMOUNT
        );
        utils::increase_block(1, 2);
        // try delegate 5
        let i = 0;
        while (i < max_delegation_slot + 1) {
            // delegate
            mock_delegate(
                delegator1,
                metadata,
                DELEGATING_AMOUNT,
                release_time + i,
                validator
            );
            // block increases
            utils::increase_block(1, 2);
            i = i + 1
        };
    }
}
