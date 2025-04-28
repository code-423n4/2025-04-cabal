#[test_only]
module initia_std::mock_mstaking {
    use std::signer;
    use std::vector;

    use initia_std::primary_fungible_store;
    use initia_std::dex;
    use initia_std::staking;
    use initia_std::address::{to_sdk, from_sdk};
    use initia_std::block;
    use initia_std::coin;
    use initia_std::json::{marshal, unmarshal};
    use initia_std::bigdecimal::{Self, BigDecimal};
    use initia_std::fungible_asset::Metadata;
    use initia_std::object::{Self, Object, ExtendRef};
    use initia_std::option::{Self, Option};
    use initia_std::string::{Self, String};
    use initia_std::query::set_query_response;
    use initia_std::query::query_stargate;
    use initia_std::table::{Self, Table};
    use initia_std::table_key::{encode_u64, decode_u64};
    use vip::utils;
    struct TestState has key {
        extend_ref: ExtendRef, // for store asset
        unbonding_period: u64,
        unbonding_id: u64,
        whitelisted_validators: Table<String, bool>,
        // for check query is set
        delegation: Table<DelegationRequest, bool>,
        delegator_delegations: Table<DelegatorDelegationsRequest, bool>,
        unbonding_delegation: Table<UnbondingDelegationRequest, bool>,
        redelegations: Table<RedelegationsRequest, bool>,
        // distributed reward
        reward: Table<DelegationRequest, Coin>,
        // completion time => unbonding mapping
        completion_time_to_unbonding: Table<CompletionTimeKey, UnbondingDelegationRequest>,
        // completion time => redelegation mapping
        completion_time_to_redelegations: Table<CompletionTimeKey, RedelegationsRequest>,
    }

    struct CompletionTimeKey has copy, drop {
        completion_time: vector<u8>,
        unbonding_id: vector<u8>,
    }

    public fun init_module(chain: &signer, unbonding_period: u64) {
        set_pool(vector[], vector[], vector[]);
        let constructor_ref = object::create_object(@initia_std, false);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        move_to(
            chain,
            TestState {
                extend_ref,
                unbonding_period,
                unbonding_id: 0,
                whitelisted_validators: table::new(),
                delegation: table::new(),
                delegator_delegations: table::new(),
                unbonding_delegation: table::new(),
                redelegations: table::new(),
                reward: table::new(),
                completion_time_to_unbonding: table::new(),
                completion_time_to_redelegations: table::new(),
            },
        )
    }

    public fun delegate(
        account: &signer, validator_addr: String, metadata: Object<Metadata>, amount: u64
    ) acquires TestState {
        before_shares_modified(account, validator_addr);
        delegate_internal(account, validator_addr, metadata, amount, true);
    }

    public fun undelegate(
        account: &signer, validator_addr: String, metadata: Object<Metadata>, amount: u64
    ) acquires TestState {
        before_shares_modified(account, validator_addr);
        undelegate_internal(account, validator_addr, metadata, amount, true);
    }

    public fun redelegate(
        account: &signer,
        src_validator_addr: String,
        dst_validator_addr: String,
        metadata: Object<Metadata>,
        amount: u64,
    ) acquires TestState {
        before_shares_modified(account, src_validator_addr);
        before_shares_modified(account, dst_validator_addr);
        undelegate_internal(account, src_validator_addr, metadata, amount, false);
        delegate_internal(account, dst_validator_addr, metadata, amount, false);
        let test_state = borrow_global_mut<TestState>(@initia_std);
        let addr = signer::address_of(account);
        let delegator_addr = to_sdk(addr);
        let denom = coin::metadata_to_denom(metadata);

        // create redelegate
        let redelegations_req = RedelegationsRequest {
            delegator_addr,
            src_validator_addr,
            dst_validator_addr
        };
        let redelegations =
            if (table::contains(&test_state.redelegations, redelegations_req)) {
                get_redelegations(redelegations_req)
            } else {
                table::add(&mut test_state.redelegations, redelegations_req, true);
                RedelegationsResponse {
                    redelegation_responses: vector[],
                    pagination: option::none()
                }
            };

        // update balance
        let (found, redelegation_index) = vector::find(
            &redelegations.redelegation_responses,
            |redelegation_response| {
                let redelegation_response_: RedelegationResponse = *redelegation_response;
                redelegation_response_.redelegation.delegator_address == delegator_addr
                    && redelegation_response_.redelegation.validator_src_address
                        == src_validator_addr
                    && redelegation_response_.redelegation.validator_dst_address
                        == dst_validator_addr
            },
        );

        if (!found) {
            redelegation_index = vector::length(&redelegations.redelegation_responses);
            vector::push_back(
                &mut redelegations.redelegation_responses,
                RedelegationResponse {
                    redelegation: Redelegation {
                        delegator_address: delegator_addr,
                        validator_src_address: src_validator_addr,
                        validator_dst_address: dst_validator_addr,
                        entries: option::none(),
                    },
                    entries: vector[],
                },
            );
        };

        let (height, timestamp) = block::get_block_info();
        test_state.unbonding_id = test_state.unbonding_id + 1;
        let completion_time = timestamp + test_state.unbonding_period;

        table::add(
            &mut test_state.completion_time_to_redelegations,
            gen_key(completion_time, test_state.unbonding_id),
            redelegations_req,
        );

        let redelegation_response = vector::borrow_mut(
            &mut redelegations.redelegation_responses, redelegation_index
        );
        let new_entry = RedelegationEntryResponse {
            redelegation_entry: RedelegationEntry {
                creation_height: (height as u32),
                completion_time: string::utf8(b""),
                initial_balance: vector[Coin { denom, amount }],
                shares_dst: vector[DecCoin { denom, amount: bigdecimal::from_u64(amount) }],
                unbonding_id: (test_state.unbonding_id as u32),
            },
            balance: vector[Coin { denom, amount }],
        };
        vector::push_back(&mut redelegation_response.entries, new_entry);

        set_redelegations(&redelegations_req, &redelegations);
    }

    public fun withdraw_delegations_reward(
        account: &signer, validator_addr: String
    ) acquires TestState {
        let delegator = signer::address_of(account);
        let delegator_addr = to_sdk(delegator);
        let test_state = borrow_global_mut<TestState>(@initia_std);
        let test_signer = object::generate_signer_for_extending(&test_state.extend_ref);
        let key = DelegationRequest { validator_addr, delegator_addr };
        if (!table::contains(&test_state.reward, key)) { return };
        let coin = table::borrow_mut(&mut test_state.reward, key);
        // for simplicity, send tokens directly from the chain when claiming rewards.
        coin::transfer(
            &test_signer,
            delegator,
            coin::denom_to_metadata(coin.denom),
            coin.amount,
        );
        table::remove(&mut test_state.reward, key);
    }

    fun slash_unbonding_delegation(
        test_state: &TestState, validator_addr: String, slash_factor: BigDecimal
    ) {
        // iterate through unbonding delegations from slashed validator
        let iter =
            table::iter(
                &test_state.completion_time_to_unbonding,
                option::none(),
                option::none(),
                2,
            );
        loop {
            if (!table::prepare(iter)) { break };
            let (_key, unbonding_delegation_req) = table::next(iter);
            let unbonding_delegation =
                get_unbonding_delegation(*unbonding_delegation_req).unbond;
            let (unbonding_delegator_addr, unbonding_validator_address, unbonding_entries) =

                unpack_unbonding_delegation(unbonding_delegation);
            if (unbonding_validator_address != validator_addr) {
                continue
            };
            let new_unbonding_entries = vector<UnbondingDelegationEntry>[];
            vector::for_each_mut(
                &mut unbonding_entries,
                |entry| {
                    let initial_balance = entry.initial_balance;
                    let new_balance = entry.balance;

                    vector::enumerate_ref(
                        &initial_balance,
                        |i, initial_coin| {
                            let coin = vector::borrow_mut(&mut new_balance, i);
                            let slashing_amount =
                                bigdecimal::mul_by_u64_truncate(
                                    slash_factor, initial_coin.amount
                                );

                            if (coin.amount > slashing_amount) {
                                coin.amount = coin.amount - slashing_amount;
                            }
                        },
                    );
                    vector::push_back(
                        &mut new_unbonding_entries,
                        UnbondingDelegationEntry {
                            creation_height: entry.creation_height,
                            completion_time: entry.completion_time,
                            initial_balance: entry.initial_balance,
                            balance: new_balance,
                            unbonding_id: entry.unbonding_id,
                            unbonding_on_hold_ref_count: entry.unbonding_on_hold_ref_count
                        },
                    );
                },
            );

            set_unbonding_delegation(
                &UnbondingDelegationRequest {
                    delegator_addr: unbonding_delegator_addr,
                    validator_addr
                },
                &UnbondingDelegationResponse {
                    unbond: UnbondingDelegation {
                        delegator_address: unbonding_delegator_addr,
                        validator_address: validator_addr,
                        entries: new_unbonding_entries
                    }
                },
            );
        };
    }

    fun slash_redelegations(
        test_state: &TestState, validator_addr: String, slash_factor: BigDecimal
    ) {
        // iterate through redelegations from slashed source validator
        let iter =
            table::iter(
                &test_state.completion_time_to_redelegations,
                option::none(),
                option::none(),
                2,
            );

        loop {
            if (!table::prepare(iter)) { break };
            let (_key, redelegation_delegation_req) = table::next(iter);
            let redelegation_responses =
                get_redelegations(*redelegation_delegation_req).redelegation_responses;
            let redelegation_response = vector::borrow(&redelegation_responses, 0);
            let redelegation_entries = redelegation_response.entries; // vector<RedelegationEntryResponse>
            let redelegations = redelegation_response.redelegation;
            let (delegator_addr, src_validator_addr, dst_validator_addr) =
                unpack_redelegation_req(redelegations);
            // slash redelegation moved from src val
            if (src_validator_addr != validator_addr) {
                continue
            };
            // search redelegation from src val
            vector::for_each_ref(
                &redelegation_entries,
                |entry| {
                    let initial_balances = entry.redelegation_entry.initial_balance;
                    let slashing_coins = vector<Coin>[];
                    // calculate slash amount proportional to stake contributing to infraction
                    vector::enumerate_ref(
                        &initial_balances,
                        |_i, initial_balance| {
                            let slashing_amount =
                                bigdecimal::mul_by_u64_truncate(
                                    slash_factor, initial_balance.amount
                                );
                            vector::push_back(
                                &mut slashing_coins,
                                Coin {
                                    denom: initial_balance.denom,
                                    amount: slashing_amount
                                },
                            );
                        },
                    );
                    // 1. if there are slashing unbonding delegation entries of dst val, slashing
                    if (table::contains(
                            &test_state.unbonding_delegation,
                            UnbondingDelegationRequest {
                                delegator_addr,
                                validator_addr: dst_validator_addr
                            },
                        )) {

                        let unbonding_entries =
                            get_unbonding_delegation(
                                UnbondingDelegationRequest {
                                    delegator_addr,
                                    validator_addr: dst_validator_addr
                                },
                            ).unbond.entries;

                        let new_unbonding_entries = vector<UnbondingDelegationEntry>[];

                        vector::for_each_ref(
                            &unbonding_entries,
                            |entry| {
                                // calc unbonding slashing coins,
                                let unbonding_slashing_coins =
                                    min_coins(slashing_coins, entry.balance);

                                slashing_coins = sub_coins(
                                    slashing_coins, unbonding_slashing_coins
                                );

                                let new_balance =
                                    sub_coins(entry.balance, unbonding_slashing_coins);
                                vector::push_back(
                                    &mut new_unbonding_entries,
                                    UnbondingDelegationEntry {
                                        creation_height: entry.creation_height,
                                        completion_time: entry.completion_time,
                                        initial_balance: entry.initial_balance,
                                        balance: new_balance,
                                        unbonding_id: entry.unbonding_id,
                                        unbonding_on_hold_ref_count: entry.unbonding_on_hold_ref_count
                                    },
                                );
                            },
                        );
                        // set unbonding delegation with new balance
                        set_unbonding_delegation(
                            &UnbondingDelegationRequest {
                                delegator_addr,
                                validator_addr: dst_validator_addr,
                            },
                            &UnbondingDelegationResponse {
                                unbond: UnbondingDelegation {
                                    delegator_address: delegator_addr,
                                    validator_address: dst_validator_addr,
                                    entries: new_unbonding_entries
                                }
                            },
                        );

                    };

                    // if there are no reserved slashing coins, done
                    // 2. slashing delegations on dst addr; reserved slashing amount
                    if (!is_zero_coins(slashing_coins)) {
                        let del_iter =
                            table::iter(
                                &test_state.delegation,
                                option::none(),
                                option::none(),
                                2,
                            );
                        loop {
                            if (!table::prepare(del_iter)) { break };
                            let (delegation_req, _v) = table::next(del_iter);
                            if (delegation_req.validator_addr != dst_validator_addr) {
                                continue
                            };
                            let inner =
                                get_delegation(delegation_req).delegation_response;
                            let balances = inner.balance;

                            let new_balances = sub_coins(balances, slashing_coins);
                            let new_shares = vector<DecCoin>[];
                            // calculate shares based on the 'amount_to_share', since the staking ratio remains constant.
                            vector::for_each_ref(
                                &new_balances,
                                |new_balance| {
                                    vector::push_back(
                                        &mut new_shares,
                                        DecCoin {
                                            denom: new_balance.denom,
                                            amount: staking::amount_to_share(
                                                *string::bytes(&dst_validator_addr),
                                                &coin::denom_to_metadata(
                                                    new_balance.denom
                                                ),
                                                new_balance.amount,
                                            ),
                                        },
                                    );
                                },
                            );
                            let delegation = DelegationResponse {
                                delegation_response: DelegationResponseInner {
                                    delegation: Delegation {
                                        delegator_address: delegation_req.delegator_addr,
                                        validator_address: delegation_req.validator_addr,
                                        shares: new_shares
                                    },
                                    balance: new_balances,
                                }
                            };
                            // reset delegation with new shares and balances
                            set_delegation(
                                &delegation_req,
                                &delegation,
                            );

                            // get delegator delegations
                            let delegator_delegations_req = DelegatorDelegationsRequest {
                                delegator_addr,
                                pagination: option::none()
                            };
                            let delegator_delegations =
                                get_delegator_delegations(delegator_delegations_req);

                            // update delegator delegations
                            let (_, delegation_index) = vector::find(
                                &delegator_delegations.delegation_responses,
                                |delegation| {
                                    let DelegationResponseInner { delegation, balance: _ } =
                                        *delegation;
                                    let Delegation {
                                        delegator_address,
                                        validator_address,
                                        shares: _
                                    } = delegation;
                                    delegator_address == delegator_addr
                                        && validator_address == validator_addr
                                },
                            );
                            let delegation_responses =
                                delegator_delegations.delegation_responses;
                            vector::remove(
                                &mut delegation_responses,
                                delegation_index,
                            );
                            vector::push_back(
                                &mut delegation_responses, delegation.delegation_response
                            );

                            // set delegator delegations
                            set_delegator_delegations(
                                &delegator_delegations_req,
                                &DelegatorDelegationsResponse {
                                    delegation_responses,
                                    pagination: option::none()
                                },
                            );
                        }
                    }
                },
            );
        };
    }

    fun slash_delegations(
        test_state: &TestState, validator_addr: String, slash_factor: BigDecimal
    ) {
        let iter = table::iter(
            &test_state.delegation,
            option::none(),
            option::none(),
            2,
        );
        let total_shares = vector<DecCoin>[];
        let new_total_balances = vector<Coin>[];
        loop {
            if (!table::prepare(iter)) { break };
            let (delegation_req, _v) = table::next(iter);
            if (delegation_req.validator_addr != validator_addr) {
                continue
            };
            let inner = get_delegation(delegation_req).delegation_response;
            let balances = inner.balance;
            let new_balance = vector<Coin>[];
            vector::for_each_ref(
                &balances,
                |balance| {
                    let slashing_amount =
                        bigdecimal::mul_by_u64_truncate(slash_factor, balance.amount);
                    let reserve = balance.amount - slashing_amount;
                    vector::push_back(
                        &mut new_balance,
                        Coin { denom: balance.denom, amount: reserve },
                    );
                },
            );

            total_shares = add_dec_coins(total_shares, inner.delegation.shares);
            new_total_balances = add_coins(new_total_balances, new_balance);

            let delegation_response = DelegationResponseInner {
                delegation: Delegation {
                    delegator_address: delegation_req.delegator_addr,
                    validator_address: delegation_req.validator_addr,
                    shares: inner.delegation.shares
                },
                balance: new_balance,
            };
            // reset delegation
            set_delegation(
                &delegation_req,
                &DelegationResponse { delegation_response },
            );

            // get delegator delegations
            let delegator_delegations_req = DelegatorDelegationsRequest {
                delegator_addr: delegation_req.delegator_addr,
                pagination: option::none()
            };
            let delegator_delegations =
                get_delegator_delegations(delegator_delegations_req);

            // update delegator delegations
            let (_, delegation_index) = vector::find(
                &delegator_delegations.delegation_responses,
                |delegation| {
                    let DelegationResponseInner { delegation, balance: _ } = *delegation;
                    let Delegation { delegator_address, validator_address, shares: _ } =
                        delegation;
                    delegator_address == delegation_req.delegator_addr
                        && validator_address == validator_addr
                },
            );
            let old_delegation = vector::borrow_mut(
                &mut delegator_delegations.delegation_responses,
                delegation_index,
            );
            *old_delegation = delegation_response;

            // set delegator delegations
            set_delegator_delegations(
                &delegator_delegations_req, &delegator_delegations
            );
        };

        // reset staking ratio of shares and amounts
        vector::for_each_ref(
            &total_shares,
            |s| {
                let DecCoin { denom, amount } = *s;
                let total_share_amount = amount;
                let (_, idx) = vector::find(
                    &new_total_balances,
                    |new_total_balance| {
                        new_total_balance.denom == denom
                    },
                );
                let total_balance = vector::borrow(&new_total_balances, idx);
                staking::set_staking_share_ratio(
                    *string::bytes(&validator_addr),
                    &coin::denom_to_metadata(denom),
                    &total_share_amount,
                    total_balance.amount,
                );
            },
        );
    }

    public fun slash(validator_addr: String, slash_factor: BigDecimal) acquires TestState {
        let test_state = borrow_global<TestState>(@initia_std);
        slash_unbonding_delegation(
            test_state,
            validator_addr,
            slash_factor,
        );

        slash_redelegations(
            test_state,
            validator_addr,
            slash_factor,
        );

        slash_delegations(
            test_state,
            validator_addr,
            slash_factor,
        );
    }

    public fun clear_completed_entries() acquires TestState {
        let test_state = borrow_global_mut<TestState>(@initia_std);
        let test_signer = object::generate_signer_for_extending(&test_state.extend_ref);
        let (_, timestamp) = block::get_block_info();
        let end_key = CompletionTimeKey {
            completion_time: encode_u64(timestamp + 1),
            unbonding_id: encode_u64(0),
        };

        // handle unbonding
        let key_to_delete = vector[];
        let iter =
            table::iter_mut(
                &mut test_state.completion_time_to_unbonding,
                option::none(),
                option::some(end_key),
                2,
            );
        loop {
            if (!table::prepare_mut(iter)) { break };
            let (key, unbonding_delegation_req) = table::next_mut(iter);
            let unbonding_delegation =
                get_unbonding_delegation(*unbonding_delegation_req);
            let unbonding_id = decode_u64(key.unbonding_id);
            let (found, entry_index) = vector::find(
                &unbonding_delegation.unbond.entries,
                |entry| {
                    let entry: UnbondingDelegationEntry = *entry;
                    entry.unbonding_id == unbonding_id
                },
            );
            assert!(found, 1);

            let entry = vector::remove(
                &mut unbonding_delegation.unbond.entries, entry_index
            );

            // release token
            let balance = vector::borrow(&entry.balance, 0);
            let metadata = coin::denom_to_metadata(balance.denom);
            let addr = from_sdk(unbonding_delegation.unbond.delegator_address);
            coin::transfer(&test_signer, addr, metadata, balance.amount);

            // set query
            set_unbonding_delegation(unbonding_delegation_req, &unbonding_delegation);

            // if no entry remove
            if (vector::length(&unbonding_delegation.unbond.entries) == 0) {
                vector::push_back(&mut key_to_delete, key);
            };
        };

        vector::for_each_ref(
            &key_to_delete,
            |key| {
                let req = table::remove(
                    &mut test_state.completion_time_to_unbonding, *key
                );
                unset_unbonding_delegation(&req);
            },
        );

        // handle redelegate
        let key_to_delete = vector[];
        let iter =
            table::iter_mut(
                &mut test_state.completion_time_to_redelegations,
                option::none(),
                option::some(end_key),
                2,
            );
        loop {
            if (!table::prepare_mut(iter)) { break };
            let (key, redelegations_req) = table::next_mut(iter);
            let redelegations = get_redelegations(*redelegations_req);
            let unbonding_id = decode_u64(key.unbonding_id);
            let redelegation = vector::borrow_mut(
                &mut redelegations.redelegation_responses, 0
            );
            let (found, entry_index) = vector::find(
                &redelegation.entries,
                |entry| {
                    let entry: RedelegationEntryResponse = *entry;
                    entry.redelegation_entry.unbonding_id == (unbonding_id as u32)
                },
            );
            assert!(found, 1);

            vector::remove(&mut redelegation.entries, entry_index);

            // if no entry remove
            if (vector::length(&redelegation.entries) == 0) {
                vector::push_back(&mut key_to_delete, key);
            };

            // set query
            set_redelegations(redelegations_req, &redelegations);
        };

        vector::for_each_ref(
            &key_to_delete,
            |key| {
                let req =
                    table::remove(&mut test_state.completion_time_to_redelegations, *key);
                unset_redelegations(&req);
            },
        );
    }

    public fun register_validators(validators: vector<String>) acquires TestState {
        let test_state = borrow_global_mut<TestState>(@initia_std);
        let pool = get_pool().pool;
        vector::for_each(
            validators,
            |v| {
                table::upsert(&mut test_state.whitelisted_validators, v, true);
                vector::for_each_ref(
                    &pool.not_bonded_tokens,
                    |token| {
                        staking::set_staking_share_ratio(
                            *string::bytes(&v),
                            &coin::denom_to_metadata(token.denom),
                            &bigdecimal::one(),
                            1,
                        );
                    },
                );
                vector::for_each_ref(
                    &pool.bonded_tokens,
                    |token| {
                        staking::set_staking_share_ratio(
                            *string::bytes(&v),
                            &coin::denom_to_metadata(token.denom),
                            &bigdecimal::one(),
                            1,
                        );
                    },
                );
            },
        )
    }

    public fun deregister_validators(validators: vector<String>) acquires TestState {
        let test_state = borrow_global_mut<TestState>(@initia_std);

        vector::for_each(
            validators,
            |v| {
                table::upsert(&mut test_state.whitelisted_validators, v, false);
            },
        )
    }

    public fun update_voting_power_weights(
        denoms: vector<String>, weights: vector<BigDecimal>
    ) {
        assert!(vector::length(&denoms) == vector::length(&weights), 1);
        let voting_power_weights = vector[];
        let i = 0;
        let length = vector::length(&denoms);
        while (i < length) {
            let denom = *vector::borrow(&denoms, i);
            let amount = *vector::borrow(&weights, i);
            vector::push_back(&mut voting_power_weights, DecCoin { denom, amount });
            i = i + 1;
        };
        let pool = get_pool().pool;
        set_pool(pool.not_bonded_tokens, pool.bonded_tokens, voting_power_weights);
    }

    fun delegate_internal(
        account: &signer,
        validator_addr: String,
        metadata: Object<Metadata>,
        amount: u64,
        with_transfer: bool
    ) acquires TestState {
        let test_state = borrow_global_mut<TestState>(@initia_std);
        let addr = signer::address_of(account);
        let delegator_addr = to_sdk(addr);
        let denom = coin::metadata_to_denom(metadata);

        // transfer asset to test account
        if (with_transfer) {
            let test_account_addr =
                object::address_from_extend_ref(&test_state.extend_ref);
            coin::transfer(account, test_account_addr, metadata, amount);
        };

        // get and update delegation
        let delegation_req = DelegationRequest { validator_addr, delegator_addr };
        let delegation =
            if (table::contains(&test_state.delegation, delegation_req)) {
                get_delegation(delegation_req)
            } else {
                table::add(&mut test_state.delegation, delegation_req, true);
                DelegationResponse {
                    delegation_response: DelegationResponseInner {
                        delegation: Delegation {
                            delegator_address: delegator_addr,
                            validator_address: validator_addr,
                            shares: vector[]
                        },
                        balance: vector[],
                    },
                }
            };

        // update balance
        let (found, balance_index) = vector::find(
            &delegation.delegation_response.balance,
            |balance| {
                let Coin { denom: coin_denom, amount: _ } = *balance;
                coin_denom == denom
            },
        );
        if (!found) {
            balance_index = vector::length(&delegation.delegation_response.balance);
            vector::push_back(
                &mut delegation.delegation_response.balance,
                Coin { denom, amount: 0 },
            );
        };
        let balance = vector::borrow_mut(
            &mut delegation.delegation_response.balance, balance_index
        );
        balance.amount = balance.amount + amount;
        // update share
        let (found, share_index) = vector::find(
            &delegation.delegation_response.delegation.shares,
            |share| {
                let DecCoin { denom: coin_denom, amount: _ } = *share;
                coin_denom == denom
            },
        );
        if (!found) {
            share_index = vector::length(
                &delegation.delegation_response.delegation.shares
            );
            vector::push_back(
                &mut delegation.delegation_response.delegation.shares,
                DecCoin { denom, amount: bigdecimal::zero() },
            );
        };
        let share = vector::borrow_mut(
            &mut delegation.delegation_response.delegation.shares, share_index
        );
        share.amount = bigdecimal::add(
            share.amount,
            staking::amount_to_share(
                *string::bytes(&validator_addr),
                &metadata,
                amount,
            ),
        );
        // set delegation
        set_delegation(&delegation_req, &delegation);

        // get delegator delegations
        let delegator_delegations_req = DelegatorDelegationsRequest {
            delegator_addr,
            pagination: option::none()
        };
        let delegator_delegations =
            if (table::contains(
                    &test_state.delegator_delegations, delegator_delegations_req
                )) {
                get_delegator_delegations(delegator_delegations_req)
            } else {
                table::add(
                    &mut test_state.delegator_delegations, delegator_delegations_req, true
                );
                DelegatorDelegationsResponse {
                    delegation_responses: vector[],
                    pagination: option::none(),
                }
            };

        // update delegator delegations
        let (found, delegation_index) = vector::find(
            &delegator_delegations.delegation_responses,
            |delegation| {
                let DelegationResponseInner { delegation, balance: _ } = *delegation;
                let Delegation { delegator_address, validator_address, shares: _ } =
                    delegation;
                delegator_address == delegator_addr && validator_address == validator_addr
            },
        );

        if (found) {
            let old_delegation = vector::borrow_mut(
                &mut delegator_delegations.delegation_responses, delegation_index
            );
            *old_delegation = delegation.delegation_response;
        } else {
            vector::push_back(
                &mut delegator_delegations.delegation_responses,
                delegation.delegation_response,
            );
        };
        // set delegator delegations
        set_delegator_delegations(&delegator_delegations_req, &delegator_delegations);
    }

    fun undelegate_internal(
        account: &signer,
        validator_addr: String,
        metadata: Object<Metadata>,
        amount: u64,
        create_unbonding: bool
    ) acquires TestState {
        let test_state = borrow_global_mut<TestState>(@initia_std);
        let addr = signer::address_of(account);
        let delegator_addr = to_sdk(addr);
        let denom = coin::metadata_to_denom(metadata);

        // get and update delegation
        let delegation_req = DelegationRequest { validator_addr, delegator_addr };
        assert!(table::contains(&test_state.delegation, delegation_req), 1);
        let delegation = get_delegation(delegation_req);

        // update balance
        let (found, balance_index) = vector::find(
            &delegation.delegation_response.balance,
            |balance| {
                let Coin { denom: coin_denom, amount: _ } = *balance;
                coin_denom == denom
            },
        );
        assert!(found, 1);
        let balance = vector::borrow_mut(
            &mut delegation.delegation_response.balance, balance_index
        );
        let new_amount = balance.amount - amount;
        balance.amount = new_amount;
        if (new_amount == 0) {
            vector::remove(&mut delegation.delegation_response.balance, balance_index);
        };

        // update share
        let (found, share_index) = vector::find(
            &delegation.delegation_response.delegation.shares,
            |share| {
                let DecCoin { denom: coin_denom, amount: _ } = *share;
                coin_denom == denom
            },
        );
        assert!(found, 1);
        let share = vector::borrow_mut(
            &mut delegation.delegation_response.delegation.shares, share_index
        );
        share.amount = bigdecimal::sub(
            share.amount,
            staking::amount_to_share(
                *string::bytes(&validator_addr),
                &metadata,
                amount,
            ),
        );

        if (share.amount == bigdecimal::zero()) {
            vector::remove<DecCoin>(
                &mut delegation.delegation_response.delegation.shares, share_index
            );
        };

        // set delegation
        set_delegation(&delegation_req, &delegation);

        let delegation_deleted =
            if (vector::length(&mut delegation.delegation_response.delegation.shares) == 0) {
                table::remove(&mut test_state.delegation, delegation_req);
                unset_delegation(&delegation_req);
                true
            } else { false };

        // get delegator delegations
        let delegator_delegations_req = DelegatorDelegationsRequest {
            delegator_addr,
            pagination: option::none()
        };
        assert!(
            table::contains(&test_state.delegator_delegations, delegator_delegations_req),
            1,
        );
        let delegator_delegations = get_delegator_delegations(delegator_delegations_req);

        // update delegator delegations
        let (found, delegation_index) = vector::find(
            &delegator_delegations.delegation_responses,
            |delegation| {
                let DelegationResponseInner { delegation, balance: _ } = *delegation;
                let Delegation { delegator_address, validator_address, shares: _ } =
                    delegation;
                delegator_address == delegator_addr && validator_address == validator_addr
            },
        );

        assert!(found, 1);
        if (delegation_deleted) {
            vector::remove(
                &mut delegator_delegations.delegation_responses, delegation_index
            );
        } else {
            let old_delegation = vector::borrow_mut(
                &mut delegator_delegations.delegation_responses, delegation_index
            );
            *old_delegation = delegation.delegation_response;
        };

        if (vector::length(&delegator_delegations.delegation_responses) == 0) {
            table::remove(
                &mut test_state.delegator_delegations, delegator_delegations_req
            );
            unset_delegator_delegations(&delegator_delegations_req);

        } else {
            // set delegator delegations
            set_delegator_delegations(&delegator_delegations_req, &delegator_delegations);
        };

        // set unbonding
        if (create_unbonding) {
            let unbonding_delegation_req = UnbondingDelegationRequest {
                delegator_addr,
                validator_addr
            };
            let unbonding_delegation =
                if (table::contains(
                        &test_state.unbonding_delegation, unbonding_delegation_req
                    )) {
                    get_unbonding_delegation(unbonding_delegation_req)
                } else {
                    table::add(
                        &mut test_state.unbonding_delegation,
                        unbonding_delegation_req,
                        true,
                    );
                    UnbondingDelegationResponse {
                        unbond: UnbondingDelegation {
                            delegator_address: delegator_addr,
                            validator_address: validator_addr,
                            entries: vector[]
                        }
                    }
                };

            let (height, timestamp) = block::get_block_info();
            test_state.unbonding_id = test_state.unbonding_id + 1;
            let completion_time = timestamp + test_state.unbonding_period;

            table::add(
                &mut test_state.completion_time_to_unbonding,
                gen_key(completion_time, test_state.unbonding_id),
                unbonding_delegation_req,
            );

            let new_entry = UnbondingDelegationEntry {
                creation_height: height,
                completion_time: string::utf8(b""),
                initial_balance: vector[Coin { denom, amount }],
                balance: vector[Coin { denom, amount }],
                unbonding_id: test_state.unbonding_id,
                unbonding_on_hold_ref_count: 0,
            };

            vector::push_back(&mut unbonding_delegation.unbond.entries, new_entry);
            set_unbonding_delegation(&unbonding_delegation_req, &unbonding_delegation);
        }
    }

    fun set_delegation(req: &DelegationRequest, res: &DelegationResponse) {
        set_query_response(
            b"/initia.mstaking.v1.Query/Delegation",
            marshal(req),
            marshal(res),
        );
    }

    fun unset_delegation(req: &DelegationRequest) {
        set_query_response(
            b"/initia.mstaking.v1.Query/Delegation", marshal(req), vector[]
        );
    }

    fun set_unbonding_delegation(
        req: &UnbondingDelegationRequest, res: &UnbondingDelegationResponse
    ) {
        set_query_response(
            b"/initia.mstaking.v1.Query/UnbondingDelegation",
            marshal(req),
            marshal(res),
        );
    }

    fun unset_unbonding_delegation(req: &UnbondingDelegationRequest) {
        set_query_response(
            b"/initia.mstaking.v1.Query/UnbondingDelegation",
            marshal(req),
            vector[],
        );
    }

    fun set_redelegations(
        req: &RedelegationsRequest, res: &RedelegationsResponse
    ) {
        
        set_query_response(
            b"/initia.mstaking.v1.Query/Redelegations",
            marshal(req),
            marshal(res),
        );
    }

    fun unset_redelegations(req: &RedelegationsRequest) {
        set_query_response(
            b"/initia.mstaking.v1.Query/Redelegations", marshal(req), vector[]
        );
    }

    fun set_delegator_delegations(
        req: &DelegatorDelegationsRequest, res: &DelegatorDelegationsResponse
    ) {
        let req = if(option::is_none(&req.pagination)) {
            let new_req = &DelegatorDelegationsRequest{
                delegator_addr: req.delegator_addr,
                pagination: option::some(PageRequest {
                    key: option::none(),
                    offset: option::none(),
                    limit: option::none(),
                    count_total: option::none(),
                    reverse: option::none(),
                })
            };
            new_req
        } else {
            req
        };
        set_query_response(
            b"/initia.mstaking.v1.Query/DelegatorDelegations",
            marshal(req),
            marshal(res),
        );
    }

    fun unset_delegator_delegations(req: &DelegatorDelegationsRequest) {
        let req = if(option::is_none(&req.pagination)) {
            let new_req = &DelegatorDelegationsRequest{
                delegator_addr: req.delegator_addr,
                pagination: option::some(PageRequest {
                    key: option::none(),
                    offset: option::none(),
                    limit: option::none(),
                    count_total: option::none(),
                    reverse: option::none(),
                })
            };
            new_req
        } else {
            req
        };
        set_query_response(
            b"/initia.mstaking.v1.Query/DelegatorDelegations",
            marshal(req),
            vector[],
        );
    }

    fun set_pool(
        not_bonded_tokens: vector<Coin>,
        bonded_tokens: vector<Coin>,
        voting_power_weights: vector<DecCoin>
    ) {
        let req = PoolRequest {};

        let res = PoolResponse {
            pool: Pool { not_bonded_tokens, bonded_tokens, voting_power_weights, },
        };

        set_query_response(
            b"/initia.mstaking.v1.Query/Pool", marshal(&req), marshal(&res)
        );
    }

    fun get_delegation(req: DelegationRequest): DelegationResponse {
        let path = b"/initia.mstaking.v1.Query/Delegation";
        let response = query_stargate(path, marshal(&req));
        if (response == b"") {
            return get_none_delegation_response()
        };
        unmarshal<DelegationResponse>(response)
    }

    fun get_unbonding_delegation(req: UnbondingDelegationRequest): UnbondingDelegationResponse {
        let path = b"/initia.mstaking.v1.Query/UnbondingDelegation";
        let response = query_stargate(path, marshal(&req));
        if (response == b"") {
            return get_none_unbonding_delegation_response()
        };
        unmarshal<UnbondingDelegationResponse>(response)
    }

    fun get_redelegations(req: RedelegationsRequest): RedelegationsResponse {
        let path = b"/initia.mstaking.v1.Query/Redelegations";
        let response = query_stargate(path, marshal(&req));
        if (response == b"") {
            return get_none_redelegations_response()
        };
        unmarshal<RedelegationsResponse>(response)
    }

    fun get_delegator_delegations(req: DelegatorDelegationsRequest)
        : DelegatorDelegationsResponse {
        let req = if(option::is_none(&req.pagination)) {
            let new_req = DelegatorDelegationsRequest{
                delegator_addr: req.delegator_addr,
                pagination: option::some(PageRequest {
                    key: option::none(),
                    offset: option::none(),
                    limit: option::none(),
                    count_total: option::none(),
                    reverse: option::none(),
                })
            };
            new_req
        } else {
            req
        };
        let path = b"/initia.mstaking.v1.Query/DelegatorDelegations";
        let response = query_stargate(path, marshal(&req));
        if (response == b"") {
            return get_none_delegator_delegations_response()
        };
        unmarshal<DelegatorDelegationsResponse>(response)
    }

    fun get_pool(): PoolResponse {
        let path = b"/initia.mstaking.v1.Query/Pool";
        let response = query_stargate(path, marshal(&PoolRequest {}));
        unmarshal<PoolResponse>(response)
    }

    fun gen_key(completion_time: u64, unbonding_id: u64): CompletionTimeKey {
        CompletionTimeKey {
            completion_time: initia_std::table_key::encode_u64(completion_time),
            unbonding_id: initia_std::table_key::encode_u64(unbonding_id),
        }
    }

    // query req/res types
    struct DelegatorDelegationsRequest has copy, drop, store {
        delegator_addr: String,
        pagination: Option<PageRequest>
    }

    struct DelegatorDelegationsResponse has copy, drop, store {
        delegation_responses: vector<DelegationResponseInner>,
        pagination: Option<PageResponse>,
    }

    struct PoolRequest has copy, drop, store {}

    struct PoolResponse has copy, drop, store {
        pool: Pool,
    }

    struct DelegationRequest has copy, drop, store {
        validator_addr: String,
        delegator_addr: String,
    }

    struct DelegationResponse has copy, drop, store {
        delegation_response: DelegationResponseInner
    }

    struct UnbondingDelegationRequest has copy, drop, store {
        delegator_addr: String,
        validator_addr: String,
    }

    struct UnbondingDelegationResponse has copy, drop, store {
        unbond: UnbondingDelegation,
    }

    // only allow single redelegation query
    struct RedelegationsRequest has copy, drop, store {
        delegator_addr: String,
        src_validator_addr: String,
        dst_validator_addr: String,
    }

    struct RedelegationsResponse has copy, drop, store {
        redelegation_responses: vector<RedelegationResponse>, // Always contains exactly one item, as only single redelegation queries are allowed
        pagination: Option<PageResponse>, // Always None, as only single redelegation queries are allowed
    }

    // cosmos types
    struct Pool has copy, drop, store {
        not_bonded_tokens: vector<Coin>,
        bonded_tokens: vector<Coin>,
        voting_power_weights: vector<DecCoin>,
    }

    struct PageRequest has copy, drop, store {
        key: Option<String>,
        offset: Option<u64>,
        limit: Option<u64>,
        count_total: Option<bool>,
        reverse: Option<bool>,
    }

    struct PageResponse has copy, drop, store {
        next_key: Option<String>,
        total: Option<u64>,
    }

    struct DelegationResponseInner has copy, drop, store {
        delegation: Delegation,
        balance: vector<Coin>
    }

    struct Delegation has copy, drop, store {
        delegator_address: String,
        validator_address: String,
        shares: vector<DecCoin>
    }

    struct Coin has copy, drop, store {
        denom: String,
        amount: u64,
    }

    fun min_coins(a: vector<Coin>, b: vector<Coin>): vector<Coin> {
        let results = vector<Coin>[];
        vector::for_each_ref(
            &a,
            |a_c| {
                let Coin {denom, amount} = *a_c;
                let (find, idx) = vector::find(
                    &b,
                    |b_c| {
                        b_c.denom == denom
                    },
                );
                let amount =
                    if (find) {
                        let b_c = vector::borrow(&b, idx);
                        let _amount =
                            if (amount > b_c.amount) {
                                b_c.amount
                            } else {
                                amount
                            };
                        _amount
                    } else { 0 };
                vector::push_back(
                    &mut results,
                    Coin { denom: denom, amount, },
                );
            },
        );
        results
    }

    // a - b
    // always a_c.amount > b_c.amount, otherwise make error
    fun sub_coins(a: vector<Coin>, b: vector<Coin>): vector<Coin> {
        let results = a;
        vector::for_each_ref(
            &b,
            |b_c| {
                let Coin {denom, amount} = *b_c;
                let (find, idx) = vector::find(
                    &results,
                    |r_c| {
                        denom == r_c.denom
                    },
                );
                assert!(find, 1);
                let res_c = vector::borrow_mut(&mut results, idx);
                res_c.amount = res_c.amount - amount;
            },
        );
        results
    }

    // a + b
    fun add_coins(a: vector<Coin>, b: vector<Coin>): vector<Coin> {
        let results = a;
        vector::for_each_ref(
            &b,
            |b_c| {
                let Coin {denom, amount} = *b_c;
                let (find, idx) = vector::find(
                    &results,
                    |r_c| {
                        denom == r_c.denom
                    },
                );
                if (find) {
                    let res_c = vector::borrow_mut(&mut results, idx);
                    res_c.amount = res_c.amount + amount;
                } else {
                    vector::push_back(&mut results, *b_c);
                }
            },
        );
        results
    }

    fun is_zero_coins(coins: vector<Coin>): bool {
        let is_zero = true;
        vector::for_each_ref(
            &coins,
            |c| {
                if (c.amount != 0) {
                    is_zero = false
                }
            },
        );
        is_zero
    }

    struct DecCoin has copy, drop, store {
        denom: String,
        amount: BigDecimal,
    }

    fun add_dec_coins(a: vector<DecCoin>, b: vector<DecCoin>): vector<DecCoin> {
        let results = a;
        vector::for_each_ref(
            &b,
            |b_c| {
                let DecCoin {denom, amount} = *b_c;
                let (find, idx) = vector::find(
                    &results,
                    |r_c| {
                        denom == r_c.denom
                    },
                );
                if (find) {
                    let res_c = vector::borrow_mut(&mut results, idx);
                    res_c.amount = bigdecimal::add(res_c.amount, amount);
                } else {
                    vector::push_back(&mut results, *b_c);
                }
            },
        );
        results
    }

    struct UnbondingDelegation has copy, drop, store {
        delegator_address: String,
        validator_address: String,
        entries: vector<UnbondingDelegationEntry>
    }

    fun unpack_unbonding_delegation(
        unbonding_delegation: UnbondingDelegation
    ): (String, String, vector<UnbondingDelegationEntry>) {
        (
            unbonding_delegation.delegator_address,
            unbonding_delegation.validator_address,
            unbonding_delegation.entries
        )
    }

    struct UnbondingDelegationEntry has copy, drop, store {
        creation_height: u64,
        completion_time: String,
        initial_balance: vector<Coin>,
        balance: vector<Coin>,
        unbonding_id: u64,
        unbonding_on_hold_ref_count: u64,
    }

    struct RedelegationEntryResponse has copy, drop, store {
        redelegation_entry: RedelegationEntry,
        balance: vector<Coin>,
    }

    struct RedelegationResponse has copy, drop, store {
        redelegation: Redelegation,
        entries: vector<RedelegationEntryResponse>,
    }

    struct Redelegation has copy, drop, store {
        delegator_address: String,
        validator_src_address: String,
        validator_dst_address: String,
        entries: Option<vector<RedelegationEntry>>, // Always None for query response
    }

    fun unpack_redelegation_req(redelegation: Redelegation): (String, String, String) {
        (
            redelegation.delegator_address,
            redelegation.validator_src_address,
            redelegation.validator_dst_address
        )
    }

    struct RedelegationEntry has copy, drop, store {
        creation_height: u32,
        completion_time: String,
        initial_balance: vector<Coin>,
        shares_dst: vector<DecCoin>,
        unbonding_id: u32,
    }

    public fun set_reward(
        delegator_addr: String, validator_addr: String, amount: u64
    ) acquires TestState {
        let metadata = get_init_metadata();
        let test_state = borrow_global_mut<TestState>(@initia_std);
        let key = DelegationRequest { validator_addr, delegator_addr, };
        assert!(table::contains(&test_state.delegation, key), 1);
        table::upsert(
            &mut test_state.reward,
            key,
            Coin { denom: coin::metadata_to_denom(metadata), amount, },
        );
    }

    // cosmos hook
    // calc reward before delegation shares modified
    fun before_shares_modified(
        account: &signer, // delegator
        validator_addr: String
    ) acquires TestState {
        // mock up function supports only lp(USDC-INIT)
        withdraw_delegations_reward(account, validator_addr);
    }

    fun init_and_mint_coin(creator: &signer, symbol: String, amount: u64): Object<Metadata> {
        let (init_mint_cap, _, _) =
            coin::initialize(
                creator,
                option::none(),
                string::utf8(b""),
                symbol,
                6,
                string::utf8(b""),
                string::utf8(b""),
            );
        coin::mint_to(&init_mint_cap, signer::address_of(creator), amount);
        coin::metadata(signer::address_of(creator), symbol)
    }

    fun get_none_delegation_response(): DelegationResponse {
        DelegationResponse {
            delegation_response: DelegationResponseInner {
                delegation: Delegation {
                    delegator_address: string::utf8(b""),
                    validator_address: string::utf8(b""),
                    shares: vector[]
                },
                balance: vector[]
            }
        }
    }

    fun get_none_unbonding_delegation_response(): UnbondingDelegationResponse {
        UnbondingDelegationResponse {
            unbond: UnbondingDelegation {
                delegator_address: string::utf8(b""),
                validator_address: string::utf8(b""),
                entries: vector[],
            }
        }
    }

    fun get_none_redelegations_response(): RedelegationsResponse {
        RedelegationsResponse {
            redelegation_responses: vector<RedelegationResponse>[],
            pagination: option::none(),
        }
    }

    fun get_none_delegator_delegations_response(): DelegatorDelegationsResponse {
        DelegatorDelegationsResponse {
            delegation_responses: vector<DelegationResponseInner>[],
            pagination: option::none(),
        }
    }

    public fun get_validator1(): String {
        std::string::utf8(b"validator")
    }

    public fun get_validator2(): String {
        std::string::utf8(b"validator2")
    }

    public fun get_usdc_metadata(): Object<Metadata> {
        coin::metadata(@initia_std, string::utf8(b"uusdc"))
    }

    public fun get_init_metadata(): Object<Metadata> {
        coin::metadata(@initia_std, string::utf8(b"uinit"))
    }

    public fun get_lp_metadata(): Object<Metadata> {
        coin::metadata(@initia_std, string::utf8(b"INIT-USDC"))
    }

    public fun get_unbonding_period(): u64 {
        1000
    }

    public fun get_slash_factor(): BigDecimal {
        bigdecimal::from_ratio_u64(1, 10)
    }

    public fun initialize(chain: &signer) acquires TestState {
        init_module(chain, get_unbonding_period());
        primary_fungible_store::init_module_for_test();
        dex::init_module_for_test();

        let init_metadata =
            init_and_mint_coin(chain, string::utf8(b"uinit"), 10000000000000000);

        let usdc_metadata =
            init_and_mint_coin(chain, string::utf8(b"uusdc"), 10000000000000000);

        dex::create_pair_script(
            chain,
            string::utf8(b"pair"),
            string::utf8(b"INIT-USDC"),
            bigdecimal::from_ratio_u64(3, 1000),
            bigdecimal::from_ratio_u64(5, 10),
            bigdecimal::from_ratio_u64(5, 10),
            init_metadata,
            usdc_metadata,
            1000_000,
            1000_000,
        );

        let test_state = borrow_global_mut<TestState>(@initia_std);
        let test_signer_addr = object::address_from_extend_ref(&test_state.extend_ref);
        coin::transfer(
            chain,
            test_signer_addr,
            get_lp_metadata(),
            coin::balance(signer::address_of(chain), get_lp_metadata()) / 3,
        );

        coin::transfer(
            chain,
            test_signer_addr,
            get_init_metadata(),
            coin::balance(signer::address_of(chain), get_init_metadata()) / 3,
        );

        // set pool "INIT-USDC" for bonded tokes
        set_pool(
            vector[],
            vector[Coin { denom: string::utf8(b"INIT-USDC"), amount: 500_000 }, Coin { denom: string::utf8(b"uinit"), amount: 500_000 }],
            vector[],
        );
        update_voting_power_weights(
            vector[string::utf8(b"INIT-USDC"),string::utf8(b"uinit")],
            vector[bigdecimal::one(),bigdecimal::one()],
        );
        // set staking ratio of val1, val2
        register_validators(vector[get_validator1(), get_validator2()]);

    }

    #[test(chain = @initia_std, delegator1 = @0x19c9b6007d21a996737ea527f46b160b0a057c37, delegator2 = @0x56ccf33c45b99546cd1da172cf6849395bbf8573)]
    fun test_delegate(
        chain: &signer, delegator1: &signer, delegator2: &signer
    ) acquires TestState {
        initialize(chain);
        let delegating_amount = 1000;
        let metadata = get_lp_metadata();
        // mock lp providing
        coin::transfer(chain, signer::address_of(delegator1), metadata, delegating_amount);
        coin::transfer(
            chain,
            signer::address_of(delegator2),
            metadata,
            2 * delegating_amount,
        );

        // delegator1,2 delegate
        delegate(delegator1, get_validator1(), get_lp_metadata(), delegating_amount);
        delegate(delegator2, get_validator1(), get_lp_metadata(), 2 * delegating_amount);
        // check staking ratio
        let share1 =
            staking::amount_to_share(
                *string::bytes(&get_validator1()), &metadata, delegating_amount
            );
        let share2 =
            staking::amount_to_share(
                *string::bytes(&get_validator1()), &metadata, 2 * delegating_amount
            );
        assert!(share1 == bigdecimal::from_u64(delegating_amount), 1);
        assert!(share2 == bigdecimal::from_u64(2 * delegating_amount), 2);

        let response1 =
            get_delegation(
                DelegationRequest {
                    validator_addr: get_validator1(),
                    delegator_addr: to_sdk(signer::address_of(delegator1))
                },
            );
        assert!(
            response1
                == DelegationResponse {
                    delegation_response: DelegationResponseInner {
                        delegation: Delegation {
                            delegator_address: to_sdk(signer::address_of(delegator1)),
                            validator_address: get_validator1(),
                            shares: vector[
                                DecCoin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: bigdecimal::from_ratio_u64(
                                        delegating_amount, 1
                                    )
                                }]
                        },
                        balance: vector[
                            Coin {
                                denom: string::utf8(b"INIT-USDC"),
                                amount: delegating_amount
                            }]
                    }
                },
            3,
        );
        let response2 =
            get_delegation(
                DelegationRequest {
                    validator_addr: get_validator1(),
                    delegator_addr: to_sdk(signer::address_of(delegator2))
                },
            );
        assert!(
            response2
                == DelegationResponse {
                    delegation_response: DelegationResponseInner {
                        delegation: Delegation {
                            delegator_address: to_sdk(signer::address_of(delegator2)),
                            validator_address: get_validator1(),
                            shares: vector[
                                DecCoin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: bigdecimal::from_ratio_u64(
                                        2 * delegating_amount, 1
                                    )
                                }]
                        },
                        balance: vector[
                            Coin {
                                denom: string::utf8(b"INIT-USDC"),
                                amount: 2 * delegating_amount
                            }]
                    }
                },
            4,
        );
        // check get delegator delegations
        let delegator1_delegations =
            get_delegator_delegations(
                DelegatorDelegationsRequest {
                    delegator_addr: to_sdk(signer::address_of(delegator1)),
                    pagination: option::none()
                },
            );

        let delegator2_delegations =
            get_delegator_delegations(
                DelegatorDelegationsRequest {
                    delegator_addr: to_sdk(signer::address_of(delegator2)),
                    pagination: option::none()
                },
            );

        assert!(
            delegator1_delegations
                == DelegatorDelegationsResponse {
                    delegation_responses: vector[
                        DelegationResponseInner {
                            delegation: Delegation {
                                delegator_address: to_sdk(signer::address_of(delegator1)),
                                validator_address: get_validator1(),
                                shares: vector[
                                    DecCoin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: bigdecimal::from_ratio_u64(
                                            delegating_amount, 1
                                        )
                                    }]
                            },
                            balance: vector[
                                Coin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: delegating_amount
                                }]
                        }],
                    pagination: option::none()
                },
            5,
        );
        assert!(
            delegator2_delegations
                == DelegatorDelegationsResponse {
                    delegation_responses: vector[
                        DelegationResponseInner {
                            delegation: Delegation {
                                delegator_address: to_sdk(signer::address_of(delegator2)),
                                validator_address: get_validator1(),
                                shares: vector[
                                    DecCoin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: bigdecimal::from_ratio_u64(
                                            2 * delegating_amount, 1
                                        )
                                    }]
                            },
                            balance: vector[
                                Coin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: 2 * delegating_amount
                                }]
                        }],
                    pagination: option::none()
                },
            6,
        );

    }

    #[test(chain = @initia_std, delegator = @0x19c9b6007d21a996737ea527f46b160b0a057c37)]
    fun test_undelegate(chain: &signer, delegator: &signer) acquires TestState {
        initialize(chain);
        let delegating_amount = 1000;
        let metadata = get_lp_metadata();
        // mock lp providing
        coin::transfer(chain, signer::address_of(delegator), metadata, delegating_amount);

        // delegate
        delegate(delegator, get_validator1(), get_lp_metadata(), delegating_amount);
        // check staking ratio
        let share1 =
            staking::amount_to_share(
                *string::bytes(&get_validator1()), &metadata, delegating_amount
            );
        assert!(share1 == bigdecimal::from_u64(delegating_amount), 1);
        let response =
            get_delegation(
                DelegationRequest {
                    validator_addr: get_validator1(),
                    delegator_addr: to_sdk(signer::address_of(delegator))
                },
            );
        assert!(
            response
                == DelegationResponse {
                    delegation_response: DelegationResponseInner {
                        delegation: Delegation {
                            delegator_address: to_sdk(signer::address_of(delegator)),
                            validator_address: get_validator1(),
                            shares: vector[
                                DecCoin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: bigdecimal::from_ratio_u64(
                                        delegating_amount, 1
                                    )
                                }]
                        },
                        balance: vector[
                            Coin {
                                denom: string::utf8(b"INIT-USDC"),
                                amount: delegating_amount
                            }]
                    }
                },
            1,
        );
        // undelegate
        undelegate(delegator, get_validator1(), get_lp_metadata(), delegating_amount / 2);
        share1 = staking::amount_to_share(
            *string::bytes(&get_validator1()), &metadata, 1
        );
        assert!(share1 == bigdecimal::from_u64(1), 2);
        response = get_delegation(
            DelegationRequest {
                validator_addr: get_validator1(),
                delegator_addr: to_sdk(signer::address_of(delegator))
            },
        );
        assert!(
            response
                == DelegationResponse {
                    delegation_response: DelegationResponseInner {
                        delegation: Delegation {
                            delegator_address: to_sdk(signer::address_of(delegator)),
                            validator_address: get_validator1(),
                            shares: vector[
                                DecCoin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: bigdecimal::from_ratio_u64(
                                        delegating_amount / 2, 1
                                    )
                                }]
                        },
                        balance: vector[
                            Coin {
                                denom: string::utf8(b"INIT-USDC"),
                                amount: delegating_amount / 2
                            }]
                    }
                },
            3,
        );
        undelegate(delegator, get_validator1(), get_lp_metadata(), delegating_amount / 2);
        share1 = staking::amount_to_share(
            *string::bytes(&get_validator1()), &metadata, 0
        );
        assert!(share1 == bigdecimal::from_u64(0), 1);
        response = get_delegation(
            DelegationRequest {
                validator_addr: get_validator1(),
                delegator_addr: to_sdk(signer::address_of(delegator))
            },
        );
        assert!(response == get_none_delegation_response(), 2);

        // check unbonding_delegation state
        let unbonding_response =
            get_unbonding_delegation(
                UnbondingDelegationRequest {
                    delegator_addr: to_sdk(signer::address_of(delegator)),
                    validator_addr: get_validator1()
                },
            );
        assert!(
            unbonding_response
                == UnbondingDelegationResponse {
                    unbond: UnbondingDelegation {
                        delegator_address: to_sdk(signer::address_of(delegator)),
                        validator_address: get_validator1(),
                        entries: vector[
                            UnbondingDelegationEntry {
                                creation_height: 0,
                                completion_time: string::utf8(b""),
                                initial_balance: vector[
                                    Coin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: delegating_amount / 2
                                    }],
                                balance: vector[
                                    Coin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: delegating_amount / 2
                                    }],
                                unbonding_id: 1,
                                unbonding_on_hold_ref_count: 0
                            },
                            UnbondingDelegationEntry {
                                creation_height: 0,
                                completion_time: string::utf8(b""),
                                initial_balance: vector[
                                    Coin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: delegating_amount / 2
                                    }],
                                balance: vector[
                                    Coin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: delegating_amount / 2
                                    }],
                                unbonding_id: 2,
                                unbonding_on_hold_ref_count: 0
                            }]
                    }
                },
            3,
        );

        // check get delegator delegations
        let delegator_delegations =
            get_delegator_delegations(
                DelegatorDelegationsRequest {
                    delegator_addr: to_sdk(signer::address_of(delegator)),
                    pagination: option::none()
                },
            );
        assert!(
            delegator_delegations
                == DelegatorDelegationsResponse {
                    delegation_responses: vector[],
                    pagination: option::none()
                },
            4,
        );
    }

    #[test(chain = @initia_std, delegator = @0x19c9b6007d21a996737ea527f46b160b0a057c37)]
    fun test_redelegate(chain: &signer, delegator: &signer) acquires TestState {
        initialize(chain);
        let delegating_amount = 1000;
        let metadata = get_lp_metadata();
        // mock lp providing
        coin::transfer(chain, signer::address_of(delegator), metadata, delegating_amount);

        // delegate
        delegate(delegator, get_validator1(), get_lp_metadata(), delegating_amount);
        let share =
            staking::amount_to_share(*string::bytes(&get_validator1()), &metadata, 1);
        assert!(share == bigdecimal::from_u64(1), 1);
        let response =
            get_delegation(
                DelegationRequest {
                    validator_addr: get_validator1(),
                    delegator_addr: to_sdk(signer::address_of(delegator))
                },
            );

        // check the delegation state of src validator
        assert!(
            response
                == DelegationResponse {
                    delegation_response: DelegationResponseInner {
                        delegation: Delegation {
                            delegator_address: to_sdk(signer::address_of(delegator)),
                            validator_address: get_validator1(),
                            shares: vector[
                                DecCoin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: bigdecimal::from_ratio_u64(
                                        delegating_amount, 1
                                    )
                                }]
                        },
                        balance: vector[
                            Coin {
                                denom: string::utf8(b"INIT-USDC"),
                                amount: delegating_amount
                            }]
                    }
                },
            1,
        );

        // redelegate
        redelegate(
            delegator,
            get_validator1(),
            get_validator2(),
            get_lp_metadata(),
            delegating_amount,
        );
        let share1 =
            staking::amount_to_share(*string::bytes(&get_validator1()), &metadata, 1);
        assert!(share1 == bigdecimal::from_u64(1), 1);
        let share2 =
            staking::amount_to_share(*string::bytes(&get_validator2()), &metadata, 1);
        assert!(share2 == bigdecimal::from_u64(1), 1);
        // check the delegation state of src validator
        response = get_delegation(
            DelegationRequest {
                validator_addr: get_validator1(),
                delegator_addr: to_sdk(signer::address_of(delegator))
            },
        );
        assert!(response == get_none_delegation_response(), 2);

        // check the delegation state of dst validator
        response = get_delegation(
            DelegationRequest {
                validator_addr: get_validator2(),
                delegator_addr: to_sdk(signer::address_of(delegator))
            },
        );
        assert!(
            response
                == DelegationResponse {
                    delegation_response: DelegationResponseInner {
                        delegation: Delegation {
                            delegator_address: to_sdk(signer::address_of(delegator)),
                            validator_address: get_validator2(),
                            shares: vector[
                                DecCoin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: bigdecimal::from_ratio_u64(
                                        delegating_amount, 1
                                    )
                                }]
                        },
                        balance: vector[
                            Coin {
                                denom: string::utf8(b"INIT-USDC"),
                                amount: delegating_amount
                            }]
                    }
                },
            3,
        );
        //check redelegation state
        let redelegation_response =
            get_redelegations(
                RedelegationsRequest {
                    delegator_addr: to_sdk(signer::address_of(delegator)),
                    src_validator_addr: get_validator1(),
                    dst_validator_addr: get_validator2()
                },
            );
        assert!(
            redelegation_response
                == RedelegationsResponse {
                    redelegation_responses: vector[
                        RedelegationResponse {
                            redelegation: Redelegation {
                                delegator_address: to_sdk(signer::address_of(delegator)),
                                validator_src_address: get_validator1(),
                                validator_dst_address: get_validator2(),
                                entries: option::none()
                            },
                            entries: vector[
                                RedelegationEntryResponse {
                                    redelegation_entry: RedelegationEntry {
                                        creation_height: 0,
                                        completion_time: string::utf8(b""),
                                        initial_balance: vector[
                                            Coin {
                                                denom: string::utf8(b"INIT-USDC"),
                                                amount: delegating_amount
                                            }],
                                        shares_dst: vector[
                                            DecCoin {
                                                denom: string::utf8(b"INIT-USDC"),
                                                amount: bigdecimal::from_ratio_u64(
                                                    delegating_amount, 1
                                                )
                                            }],
                                        unbonding_id: 1
                                    },
                                    balance: vector[
                                        Coin {
                                            denom: string::utf8(b"INIT-USDC"),
                                            amount: delegating_amount
                                        }]
                                }]
                        }],
                    pagination: option::none()
                },
            7,
        );

        let delegator_delegations =
            get_delegator_delegations(
                DelegatorDelegationsRequest {
                    delegator_addr: to_sdk(signer::address_of(delegator)),
                    pagination: option::none()
                },
            );

        assert!(
            delegator_delegations
                == DelegatorDelegationsResponse {
                    delegation_responses: vector[
                        DelegationResponseInner {
                            delegation: Delegation {
                                delegator_address: to_sdk(signer::address_of(delegator)),
                                validator_address: get_validator2(),
                                shares: vector[
                                    DecCoin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: bigdecimal::from_ratio_u64(
                                            delegating_amount, 1
                                        )
                                    }]
                            },
                            balance: vector[
                                Coin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: delegating_amount
                                }]
                        }],
                    pagination: option::none()
                },
            8,
        );

    }

    #[test(chain = @initia_std, delegator1 = @0x19c9b6007d21a996737ea527f46b160b0a057c37, delegator2 = @0x56ccf33c45b99546cd1da172cf6849395bbf8573)]
    fun e2e_test(
        chain: &signer, delegator1: &signer, delegator2: &signer
    ) acquires TestState {
        initialize(chain);

        let delegating_amount = 1000;
        let metadata = get_lp_metadata();
        // mock lp providing
        coin::transfer(
            chain,
            signer::address_of(delegator1),
            metadata,
            3 * delegating_amount,
        );
        coin::transfer(
            chain,
            signer::address_of(delegator2),
            metadata,
            3 * delegating_amount,
        );

        // delegator 1,2 delegate to val1 and val2
        // del1 -> val1: 2 * delegating_amount
        // del1 -> val2: delegating_amount
        // del2 -> val1: delegating_amount
        // del2 -> val2: 2 * delegating_amount
        delegate(delegator1, get_validator1(), get_lp_metadata(), 2 * delegating_amount);
        delegate(delegator1, get_validator2(), get_lp_metadata(), delegating_amount);
        delegate(delegator2, get_validator1(), get_lp_metadata(), delegating_amount);
        delegate(delegator2, get_validator2(), get_lp_metadata(), 2 * delegating_amount);

        // delegator1 redelgate val1 to val2
        redelegate(
            delegator1,
            get_validator1(),
            get_validator2(),
            get_lp_metadata(),
            delegating_amount,
        );

        // check state of delegations
        let delegations1 =
            get_delegator_delegations(
                DelegatorDelegationsRequest {
                    delegator_addr: to_sdk(signer::address_of(delegator1)),
                    pagination: option::none()
                },
            );

        // after redelegation
        // del1 -> val1: delegating_amount
        // del1 -> val2: 2 * delegating_amount
        assert!(
            delegations1
                == DelegatorDelegationsResponse {
                    delegation_responses: vector[
                        // del1 -> val1: delegating_amount
                        DelegationResponseInner {
                            delegation: Delegation {
                                delegator_address: to_sdk(signer::address_of(delegator1)),
                                validator_address: get_validator1(),
                                shares: vector[
                                    DecCoin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: bigdecimal::from_ratio_u64(
                                            delegating_amount, 1
                                        )
                                    }]
                            },
                            balance: vector[
                                Coin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: delegating_amount
                                }]
                        },
                        // del1 -> val2: 2 * delegating_amount
                        DelegationResponseInner {
                            delegation: Delegation {
                                delegator_address: to_sdk(signer::address_of(delegator1)),
                                validator_address: get_validator2(),
                                shares: vector[
                                    DecCoin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: bigdecimal::from_ratio_u64(
                                            2 * delegating_amount, 1
                                        )
                                    }]
                            },
                            balance: vector[
                                Coin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: 2 * delegating_amount
                                }]
                        }],
                    pagination: option::none(),
                },
            1,
        );

        // delegator2 undelegate val1
        // del2 -> val1: 0
        // del2 -> val2: 2 * delegating_amount
        undelegate(delegator2, get_validator1(), get_lp_metadata(), delegating_amount);

        let delegations2 =
            get_delegator_delegations(
                DelegatorDelegationsRequest {
                    delegator_addr: to_sdk(signer::address_of(delegator2)),
                    pagination: option::none()
                },
            );
        assert!(
            delegations2
                == DelegatorDelegationsResponse {
                    delegation_responses: vector[
                        // del2 -> val1: 0
                        // del2 -> val2: 2 * delegating_amount
                        DelegationResponseInner {
                            delegation: Delegation {
                                delegator_address: to_sdk(signer::address_of(delegator2)),
                                validator_address: get_validator2(),
                                shares: vector[
                                    DecCoin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: bigdecimal::from_ratio_u64(
                                            2 * delegating_amount, 1
                                        )
                                    }]
                            },
                            balance: vector[
                                Coin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: 2 * delegating_amount
                                }]
                        }],
                    pagination: option::none(),
                },
            2,
        );

        // snapshot balance
        let balance1_before =
            primary_fungible_store::balance(
                signer::address_of(delegator1), get_lp_metadata()
            );
        let balance2_before =
            primary_fungible_store::balance(
                signer::address_of(delegator2), get_lp_metadata()
            );

        // block height and timestamp increases to clear completed entries
        utils::increase_block(500, get_unbonding_period() + 1);
        clear_completed_entries();

        // check state of redelegation and unbonding_delegation
        // to check clear completed entries working
        let redelegations =
            get_redelegations(
                RedelegationsRequest {
                    delegator_addr: to_sdk(signer::address_of(delegator1)),
                    src_validator_addr: get_validator1(),
                    dst_validator_addr: get_validator2()
                },
            );
        assert!(redelegations == get_none_redelegations_response(), 4);

        let unbonding_del2_val1 =
            get_unbonding_delegation(
                UnbondingDelegationRequest {
                    delegator_addr: to_sdk(signer::address_of(delegator2)),
                    validator_addr: get_validator1()
                },
            );
        assert!(unbonding_del2_val1 == get_none_unbonding_delegation_response(), 5);

        let balance1_after =
            primary_fungible_store::balance(
                signer::address_of(delegator1), get_lp_metadata()
            );
        let balance2_after =
            primary_fungible_store::balance(
                signer::address_of(delegator2), get_lp_metadata()
            );
        // del1: same balance
        // del2: + delegating_amount
        assert!(balance1_after == balance1_before, 6);
        assert!(balance2_after == balance2_before + delegating_amount, 7);

    }

    // distributed reward
    #[test(chain = @initia_std, delegator = @0x19c9b6007d21a996737ea527f46b160b0a057c37)]
    fun test_withdraw_reward(chain: &signer, delegator: &signer) acquires TestState {
        initialize(chain);

        let test_state = borrow_global_mut<TestState>(@initia_std);
        let test_signer = object::generate_signer_for_extending(&test_state.extend_ref);

        let delegating_amount = 1000;
        let reward = 100;
        coin::transfer(
            &test_signer,
            signer::address_of(delegator),
            get_lp_metadata(),
            delegating_amount,
        );
        // delegator delegate
        delegate(delegator, get_validator1(), get_lp_metadata(), delegating_amount);

        set_reward(
            to_sdk(signer::address_of(delegator)),
            get_validator1(),
            reward,
        );

        withdraw_delegations_reward(delegator, get_validator1());

        assert!(
            coin::balance(signer::address_of(delegator), get_init_metadata()) == 100,
            1,
        );
    }

    // slash
    #[test(chain = @initia_std, delegator = @0x19c9b6007d21a996737ea527f46b160b0a057c37)]
    fun test_only_delegations_slash(chain: &signer, delegator: &signer) acquires TestState {
        // delegate val1
        initialize(chain);
        let delegating_amount = 1000;
        let metadata = get_lp_metadata();
        coin::transfer(
            chain,
            signer::address_of(delegator),
            metadata,
            delegating_amount,
        );
        delegate(delegator, get_validator1(), get_lp_metadata(), delegating_amount);
        let response =
            get_delegation(
                DelegationRequest {
                    validator_addr: get_validator1(),
                    delegator_addr: to_sdk(signer::address_of(delegator))
                },
            );

        assert!(
            response
                == DelegationResponse {
                    delegation_response: DelegationResponseInner {
                        delegation: Delegation {
                            delegator_address: to_sdk(signer::address_of(delegator)),
                            validator_address: get_validator1(),
                            shares: vector[
                                DecCoin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: bigdecimal::from_ratio_u64(
                                        delegating_amount, 1
                                    )
                                }]
                        },
                        balance: vector[
                            Coin {
                                denom: string::utf8(b"INIT-USDC"),
                                amount: delegating_amount
                            }]
                    }
                },
            2,
        );
        // val1 slash 10%
        slash(get_validator1(), get_slash_factor());
        // check delegations
        response = get_delegation(
            DelegationRequest {
                validator_addr: get_validator1(),
                delegator_addr: to_sdk(signer::address_of(delegator))
            },
        );
        assert!(
            response
                == DelegationResponse {
                    delegation_response: DelegationResponseInner {
                        delegation: Delegation {
                            delegator_address: to_sdk(signer::address_of(delegator)),
                            validator_address: get_validator1(),
                            shares: vector[
                                DecCoin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: bigdecimal::from_ratio_u64(
                                        delegating_amount, 1
                                    )
                                }]
                        },
                        balance: vector[
                            Coin {
                                denom: string::utf8(b"INIT-USDC"),
                                amount: (delegating_amount * 9) / 10
                            }]
                    }
                },
            2,
        );
        // check delegator delegations
        let delegator_delegations =
            get_delegator_delegations(
                DelegatorDelegationsRequest {
                    delegator_addr: to_sdk(signer::address_of(delegator)),
                    pagination: option::none()
                },
            );
        assert!(
            delegator_delegations
                == DelegatorDelegationsResponse {
                    delegation_responses: vector[
                        DelegationResponseInner {
                            delegation: Delegation {
                                delegator_address: to_sdk(signer::address_of(delegator)),
                                validator_address: get_validator1(),
                                shares: vector[
                                    DecCoin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: bigdecimal::from_ratio_u64(
                                            delegating_amount, 1
                                        )
                                    }]
                            },
                            balance: vector[
                                Coin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: (delegating_amount * 9) / 10
                                }]
                        }],
                    pagination: option::none(),
                },
            4,
        );
        // check share to amount
        let share_to_amount =
            staking::share_to_amount(
                *string::bytes(&get_validator1()),
                &metadata,
                &bigdecimal::from_u64(100000),
            );
        assert!(share_to_amount == 90000, 3);
    }

    #[test(chain = @initia_std, delegator = @0x19c9b6007d21a996737ea527f46b160b0a057c37)]
    fun test_unbonding_delegations_slash(
        chain: &signer, delegator: &signer
    ) acquires TestState {

        // check amount to share
        // clear completion
        // check balance

        // delegate val1
        initialize(chain);
        let delegating_amount = 1000;
        let metadata = get_lp_metadata();
        coin::transfer(
            chain,
            signer::address_of(delegator),
            metadata,
            delegating_amount,
        );
        delegate(delegator, get_validator1(), get_lp_metadata(), delegating_amount);
        utils::increase_block(1, 1);
        // undelegate val1 half of delegating amount
        undelegate(delegator, get_validator1(), get_lp_metadata(), delegating_amount / 2);
        // val1 slash 10%
        slash(get_validator1(), get_slash_factor());
        // check delegations
        let delegation =
            get_delegation(
                DelegationRequest {
                    validator_addr: get_validator1(),
                    delegator_addr: to_sdk(signer::address_of(delegator))
                },
            );
        let unbonding_delegation =
            get_unbonding_delegation(
                UnbondingDelegationRequest {
                    validator_addr: get_validator1(),
                    delegator_addr: to_sdk(signer::address_of(delegator))
                },
            );

        assert!(
            delegation
                == DelegationResponse {
                    delegation_response: DelegationResponseInner {
                        delegation: Delegation {
                            delegator_address: to_sdk(signer::address_of(delegator)),
                            validator_address: get_validator1(),
                            shares: vector[
                                DecCoin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: bigdecimal::from_ratio_u64(
                                        delegating_amount / 2, 1
                                    )
                                }]
                        },
                        balance: vector[Coin {
                                denom: string::utf8(b"INIT-USDC"),
                                amount: 450
                            }]
                    }
                },
            1,
        );

        assert!(
            unbonding_delegation
                == UnbondingDelegationResponse {
                    unbond: UnbondingDelegation {
                        delegator_address: to_sdk(signer::address_of(delegator)),
                        validator_address: get_validator1(),
                        entries: vector[
                            UnbondingDelegationEntry {
                                creation_height: 1,
                                completion_time: string::utf8(b""),
                                initial_balance: vector[Coin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: 500
                                    }],
                                balance: vector[Coin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: 450
                                    }],
                                unbonding_id: 1,
                                unbonding_on_hold_ref_count: 0
                            }]
                    }
                },
            2,
        );
        // check share to amount
        let share_to_amount =
            staking::share_to_amount(
                *string::bytes(&get_validator1()),
                &metadata,
                &bigdecimal::from_u64(100000),
            );
        assert!(share_to_amount == 90000, 3);
        utils::increase_block(500, get_unbonding_period() + 1);
        let balance_before =
            coin::balance(signer::address_of(delegator), get_lp_metadata());
        // clear completed entries
        clear_completed_entries();
        let balance_after =
            coin::balance(signer::address_of(delegator), get_lp_metadata());
        assert!(balance_after - balance_before == 450, 4);

    }

    // slash the delegation and unbonding dst val
    #[test(chain = @initia_std, delegator = @0x19c9b6007d21a996737ea527f46b160b0a057c37)]
    fun test_redelegations_slash1(chain: &signer, delegator: &signer) acquires TestState {
        initialize(chain);
        let delegating_amount = 1000;
        let metadata = get_lp_metadata();
        coin::transfer(
            chain,
            signer::address_of(delegator),
            metadata,
            delegating_amount,
        );
        delegate(delegator, get_validator1(), get_lp_metadata(), delegating_amount);
        utils::increase_block(1, 1);
        // redelegate half of delegating amount from val1 to val2
        redelegate(
            delegator,
            get_validator1(),
            get_validator2(),
            get_lp_metadata(),
            delegating_amount / 2,
        );
        // val1 slash 10%
        slash(get_validator1(), get_slash_factor());
        // check delegations
        let delegation1 =
            get_delegation(
                DelegationRequest {
                    validator_addr: get_validator1(),
                    delegator_addr: to_sdk(signer::address_of(delegator))
                },
            );
        let delegation2 =
            get_delegation(
                DelegationRequest {
                    validator_addr: get_validator2(),
                    delegator_addr: to_sdk(signer::address_of(delegator))
                },
            );
        assert!(
            delegation1
                == DelegationResponse {
                    delegation_response: DelegationResponseInner {
                        delegation: Delegation {
                            delegator_address: to_sdk(signer::address_of(delegator)),
                            validator_address: get_validator1(),
                            shares: vector[
                                DecCoin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: bigdecimal::from_ratio_u64(
                                        delegating_amount / 2, 1
                                    )
                                }]
                        },
                        balance: vector[Coin {
                                denom: string::utf8(b"INIT-USDC"),
                                amount: 450
                            }]
                    }
                },
            1,
        );

        assert!(
            delegation2
                == DelegationResponse {
                    delegation_response: DelegationResponseInner {
                        delegation: Delegation {
                            delegator_address: to_sdk(signer::address_of(delegator)),
                            validator_address: get_validator2(),
                            shares: vector[
                                DecCoin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: bigdecimal::from_ratio_u64(450, 1)
                                }]
                        },
                        balance: vector[Coin {
                                denom: string::utf8(b"INIT-USDC"),
                                amount: 450
                            }]
                    }
                },
            2,
        );

        // check delegator delegations
        let delegator_delegations =
            get_delegator_delegations(
                DelegatorDelegationsRequest {
                    delegator_addr: to_sdk(signer::address_of(delegator)),
                    pagination: option::none()
                },
            );
        assert!(
            delegator_delegations
                == DelegatorDelegationsResponse {
                    delegation_responses: vector[
                        DelegationResponseInner {
                            delegation: Delegation {
                                delegator_address: to_sdk(signer::address_of(delegator)),
                                validator_address: get_validator1(),
                                shares: vector[
                                    DecCoin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: bigdecimal::from_ratio_u64(
                                            delegating_amount / 2, 1
                                        )
                                    }]
                            },
                            balance: vector[Coin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: 450
                                }]
                        },
                        DelegationResponseInner {
                            delegation: Delegation {
                                delegator_address: to_sdk(signer::address_of(delegator)),
                                validator_address: get_validator2(),
                                shares: vector[
                                    DecCoin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: bigdecimal::from_ratio_u64(450, 1)
                                    }]
                            },
                            balance: vector[Coin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: 450
                                }]
                        }],
                    pagination: option::none()
                },
            3,
        );
        // check share to amount
        let share_to_amount1 =
            staking::share_to_amount(
                *string::bytes(&get_validator1()),
                &metadata,
                &bigdecimal::from_u64(100000),
            );
        assert!(share_to_amount1 == 90000, 3);

        let share_to_amount2 =
            staking::share_to_amount(
                *string::bytes(&get_validator1()),
                &metadata,
                &bigdecimal::from_u64(100000),
            );
        assert!(share_to_amount2 == 90000, 4);
        let balance_before =
            coin::balance(signer::address_of(delegator), get_lp_metadata());
        utils::increase_block(500, get_unbonding_period() + 1);
        // clear completed entries
        clear_completed_entries();
        let balance_after =
            coin::balance(signer::address_of(delegator), get_lp_metadata());
        assert!(balance_before == balance_after, 4);
    }

    // slash the delegation and unbonding dst val
    #[test(chain = @initia_std, delegator = @0x19c9b6007d21a996737ea527f46b160b0a057c37)]
    fun test_redelegations_slash2(chain: &signer, delegator: &signer) acquires TestState {
        initialize(chain);
        let delegating_amount = 1000;
        let metadata = get_lp_metadata();
        coin::transfer(
            chain,
            signer::address_of(delegator),
            metadata,
            delegating_amount,
        );
        delegate(delegator, get_validator1(), get_lp_metadata(), delegating_amount);
        utils::increase_block(1, 1);
        // redelegate half of delegating amount from val1 to val2
        redelegate(
            delegator,
            get_validator1(),
            get_validator2(),
            get_lp_metadata(),
            delegating_amount / 2,
        );
        utils::increase_block(1, 1);
        undelegate(delegator, get_validator2(), get_lp_metadata(), delegating_amount / 4);
        // undelegate val2 quarter of delegating amount
        // val1 slash 10%
        slash(get_validator1(), get_slash_factor());
        // check delegations
        let delegation1 =
            get_delegation(
                DelegationRequest {
                    validator_addr: get_validator1(),
                    delegator_addr: to_sdk(signer::address_of(delegator))
                },
            );

        let delegation2 =
            get_delegation(
                DelegationRequest {
                    validator_addr: get_validator2(),
                    delegator_addr: to_sdk(signer::address_of(delegator))
                },
            );

        let unbonding_delegation2 =
            get_unbonding_delegation(
                UnbondingDelegationRequest {
                    delegator_addr: to_sdk(signer::address_of(delegator)),
                    validator_addr: get_validator2()
                },
            );

        assert!(
            delegation1
                == DelegationResponse {
                    delegation_response: DelegationResponseInner {
                        delegation: Delegation {
                            delegator_address: to_sdk(signer::address_of(delegator)),
                            validator_address: get_validator1(),
                            shares: vector[
                                DecCoin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: bigdecimal::from_ratio_u64(
                                        delegating_amount / 2, 1
                                    )
                                }]
                        },
                        balance: vector[
                            Coin {
                                denom: string::utf8(b"INIT-USDC"),
                                amount: delegating_amount * 9 / 20 // 10% slashing
                            }]
                    }
                },
            1,
        );

        assert!(
            delegation2
                == DelegationResponse {
                    delegation_response: DelegationResponseInner {
                        delegation: Delegation {
                            delegator_address: to_sdk(signer::address_of(delegator)),
                            validator_address: get_validator2(),
                            shares: vector[
                                DecCoin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: bigdecimal::from_ratio_u64(
                                        delegating_amount / 4, 1
                                    )
                                }]
                        },
                        balance: vector[
                            Coin {
                                denom: string::utf8(b"INIT-USDC"),
                                amount: delegating_amount / 4
                            }]
                    }
                },
            2,
        );
        assert!(
            unbonding_delegation2
                == UnbondingDelegationResponse {
                    unbond: UnbondingDelegation {
                        delegator_address: to_sdk(signer::address_of(delegator)),
                        validator_address: get_validator2(),
                        entries: vector[
                            UnbondingDelegationEntry {
                                creation_height: 2,
                                completion_time: string::utf8(b""),
                                initial_balance: vector[
                                    Coin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: delegating_amount / 4
                                    }],
                                balance: vector[
                                    Coin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: delegating_amount / 4
                                            - delegating_amount / 20 // slash half of the delegating amount
                                    }],
                                unbonding_id: 2,
                                unbonding_on_hold_ref_count: 0
                            }]
                    }
                },
            3,
        );
        // check delegator delegations
        let delegator_delegations =
            get_delegator_delegations(
                DelegatorDelegationsRequest {
                    delegator_addr: to_sdk(signer::address_of(delegator)),
                    pagination: option::none()
                },
            );
        assert!(
            delegator_delegations
                == DelegatorDelegationsResponse {
                    delegation_responses: vector[
                        DelegationResponseInner {
                            delegation: Delegation {
                                delegator_address: to_sdk(signer::address_of(delegator)),
                                validator_address: get_validator1(),
                                shares: vector[
                                    DecCoin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: bigdecimal::from_ratio_u64(
                                            delegating_amount / 2, 1
                                        )
                                    }]
                            },
                            balance: vector[Coin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: 450
                                }]
                        },
                        DelegationResponseInner {
                            delegation: Delegation {
                                delegator_address: to_sdk(signer::address_of(delegator)),
                                validator_address: get_validator2(),
                                shares: vector[
                                    DecCoin {
                                        denom: string::utf8(b"INIT-USDC"),
                                        amount: bigdecimal::from_ratio_u64(
                                            delegating_amount / 4, 1
                                        )
                                    }]
                            },
                            balance: vector[
                                Coin {
                                    denom: string::utf8(b"INIT-USDC"),
                                    amount: delegating_amount / 4
                                }]
                        }],
                    pagination: option::none()
                },
            3,
        );
        // check share to amount
        let share_to_amount1 =
            staking::share_to_amount(
                *string::bytes(&get_validator1()),
                &metadata,
                &bigdecimal::from_u64(100000),
            );
        // slash only on unbonding delegation; there are no changes on the share_to_amount of val2
        let share_to_amount2 =
            staking::share_to_amount(
                *string::bytes(&get_validator2()),
                &metadata,
                &bigdecimal::from_u64(100000),
            );
        assert!(share_to_amount1 == 90000, 4);
        assert!(share_to_amount2 == 100000, 5);

        utils::increase_block(500, get_unbonding_period() + 1);
        let balance_before =
            coin::balance(signer::address_of(delegator), get_lp_metadata());
        // clear completed entries
        clear_completed_entries();
        let balance_after =
            coin::balance(signer::address_of(delegator), get_lp_metadata());
        assert!(balance_after - balance_before == delegating_amount / 5, 6);
    }
}
