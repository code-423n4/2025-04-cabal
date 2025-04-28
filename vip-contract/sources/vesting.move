module vip::vesting {
    use std::bcs;
    use std::error;
    use std::event;
    use std::option;
    use std::signer;
    use std::vector;

    use initia_std::bigdecimal::{Self, BigDecimal};
    use initia_std::fungible_asset::{FungibleAsset};
    use initia_std::table::{Self, Table};
    use initia_std::table_key;
    use initia_std::type_info;

    use vip::vault;
    use vip::utils;

    friend vip::vip;

    //
    // Errors
    //

    const EVESTING_STORE_ALREADY_EXISTS: u64 = 1;
    const EVESTING_ALREADY_CLAIMED: u64 = 2;
    const EVESTING_NOT_FOUND: u64 = 3;
    const EREWARD_NOT_ENOUGH: u64 = 4;
    const EINVALID_VESTING_TYPE: u64 = 5;
    const EINVALID_STAGE: u64 = 6;

    //
    // Resources
    //

    struct ModuleStore has key {
        user_vestings: Table<vector<u8> /*table key*/, VestingStore<UserVesting>>,
        operator_vestings: Table<vector<u8> /*table key*/, VestingStore<OperatorVesting>>
    }

    struct VestingStore<phantom Vesting: copy + drop + store> has store {
        last_claimed_stage: u64,
        vestings: Table<vector<u8> /*vesting start stage*/, Vesting>
    }

    struct UserVesting has copy, drop, store {
        initial_reward: u64,
        remaining_reward: u64,
        penalty_reward: u64,
        start_stage: u64,
        end_stage: u64,
        vest_max_amount: u64,
        l2_score: u64,
        minimum_score: u64
    }

    struct OperatorVesting has copy, drop, store {
        initial_reward: u64,
        remaining_reward: u64,
        start_stage: u64,
        end_stage: u64
    }

    struct UserVestingClaimInfo has drop, copy {
        start_stage: u64,
        end_stage: u64,
        l2_score: u64,
        total_l2_score: u64,
        minimum_score_ratio: BigDecimal,
        funded_reward: u64
    }

    struct OperatorVestingClaimInfo has drop, copy {
        start_stage: u64,
        end_stage: u64,
        funded_reward: u64
    }

    struct UserVestingResponse has drop {
        initial_reward: u64,
        remaining_reward: u64,
        penalty_reward: u64,
        start_stage: u64,
        vest_max_amount: u64,
        end_stage: u64,
        l2_score: u64,
        minimum_score: u64
    }

    struct OperatorVestingResponse has drop {
        initial_reward: u64,
        remaining_reward: u64,
        start_stage: u64,
        end_stage: u64
    }

    //
    // Events
    //

    #[event]
    struct UserVestingCreateEvent has drop, store {
        account: address,
        bridge_id: u64,
        version: u64,
        start_stage: u64,
        end_stage: u64,
        l2_score: u64,
        minimum_score: u64,
        initial_reward: u64
    }

    #[event]
    struct OperatorVestingCreateEvent has drop, store {
        account: address,
        bridge_id: u64,
        version: u64,
        start_stage: u64,
        end_stage: u64,
        initial_reward: u64
    }

    #[event]
    struct UserVestingFinalizedEvent has drop, store {
        account: address,
        bridge_id: u64,
        version: u64,
        start_stage: u64,
        penalty_reward: u64
    }

    #[event]
    struct OperatorVestingFinalizedEvent has drop, store {
        account: address,
        bridge_id: u64,
        version: u64,
        start_stage: u64
    }

    #[event]
    struct UserVestingChangedEvent has drop, store {
        account: address,
        bridge_id: u64,
        version: u64,
        start_stage: u64,
        initial_reward: u64,
        remaining_reward: u64,
        penalty_reward: u64
    }

    #[event]
    struct OperatorVestingChangedEvent has drop, store {
        account: address,
        bridge_id: u64,
        version: u64,
        start_stage: u64,
        initial_reward: u64,
        remaining_reward: u64
    }

    fun init_module(chain: &signer) {
        move_to(
            chain,
            ModuleStore {
                user_vestings: table::new<vector<u8> /*table key*/, VestingStore<
                    UserVesting>>(),
                operator_vestings: table::new<vector<u8> /*table key*/, VestingStore<
                    OperatorVesting>>()
            }
        )
    }

    //
    // Implementations
    //
    public(friend) fun register_user_vesting_store(
        account: &signer, bridge_id: u64, version: u64
    ) acquires ModuleStore {
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        let account_addr = signer::address_of(account);
        let table_key = generate_key(bridge_id, version, account_addr);
        assert!(
            !table::contains(&mut module_store.user_vestings, table_key),
            error::already_exists(EVESTING_STORE_ALREADY_EXISTS)
        );
        table::add(
            &mut module_store.user_vestings,
            table_key,
            VestingStore {
                last_claimed_stage: 0,
                vestings: table::new<vector<u8>, UserVesting>()
            }
        );
    }

    public(friend) fun register_operator_vesting_store(
        bridge_id: u64, version: u64
    ) acquires ModuleStore {
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        let table_key = generate_key(bridge_id, version, @0x0);
        assert!(
            !table::contains(
                &mut module_store.operator_vestings,
                table_key
            ),
            error::already_exists(EVESTING_STORE_ALREADY_EXISTS)
        );
        table::add(
            &mut module_store.operator_vestings,
            table_key,
            VestingStore {
                last_claimed_stage: 0,
                vestings: table::new<vector<u8>, OperatorVesting>()
            }
        );
    }

    public(friend) fun batch_claim_user_reward(
        account_addr: address,
        bridge_id: u64,
        version: u64,
        claim_infos: vector<UserVestingClaimInfo> /*asc sorted claim info*/
    ): FungibleAsset acquires ModuleStore {
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        let total_vested_reward = 0; // net reward vested to user
        let total_penalty_reward = 0;
        let user_vestings =
            load_user_vestings_mut(module_store, bridge_id, version, account_addr);
        // use a user_vestings vector instead of a table to avoid high-cost operations.
        let vestings_vec = extract_user_vestings_vector(user_vestings);
        let last_claimed_stage = 0;
        // claim
        vector::for_each_ref<UserVestingClaimInfo>(
            &claim_infos,
            |claim_info| {
                // claim previous user vestings position
                let (vested_reward, penalty_reward) =
                    batch_claim_previous_user_vestings(
                        account_addr,
                        bridge_id,
                        version,
                        &mut vestings_vec,
                        user_vestings,
                        claim_info
                    );
                total_vested_reward = total_vested_reward + vested_reward;
                total_penalty_reward = total_penalty_reward + penalty_reward;

                let initial_reward_amount =
                    if (claim_info.total_l2_score == 0) { 0 }
                    else {
                        let total_user_reward = claim_info.funded_reward;
                        utils::mul_div_u64(
                            total_user_reward,
                            claim_info.l2_score,
                            claim_info.total_l2_score
                        )
                    };
                assert!(
                    !table::contains(
                        user_vestings,
                        table_key::encode_u64(claim_info.start_stage)
                    ),
                    error::already_exists(EVESTING_ALREADY_CLAIMED)
                );

                // create user vesting
                if (initial_reward_amount > 0) {
                    create_user_vesting(
                        account_addr,
                        bridge_id,
                        version,
                        user_vestings,
                        &mut vestings_vec,
                        claim_info,
                        initial_reward_amount
                    );
                } else {
                    // if user score is 0 emit create, finalize event
                    event::emit(
                        UserVestingCreateEvent {
                            account: account_addr,
                            bridge_id,
                            version,
                            start_stage: claim_info.start_stage,
                            end_stage: claim_info.end_stage,
                            l2_score: claim_info.l2_score,
                            minimum_score: 0,
                            initial_reward: 0
                        }
                    );
                    event::emit(
                        UserVestingFinalizedEvent {
                            account: account_addr,
                            bridge_id,
                            version,
                            start_stage: claim_info.start_stage,
                            penalty_reward: 0
                        }
                    );
                };

                last_claimed_stage = claim_info.start_stage;
            }
        );

        // update or insert from unfinalized vestings to vesting data of module store
        vector::for_each(
            vestings_vec,
            |vesting| {
                table::upsert(
                    user_vestings,
                    table_key::encode_u64(vesting.start_stage),
                    vesting
                );
                // emit only user vesting happen
                if (vesting.initial_reward != vesting.remaining_reward) {
                    event::emit(
                        UserVestingChangedEvent {
                            account: account_addr,
                            bridge_id,
                            version,
                            start_stage: vesting.start_stage,
                            initial_reward: vesting.initial_reward,
                            remaining_reward: vesting.remaining_reward,
                            penalty_reward: vesting.penalty_reward
                        }
                    );
                };
            }
        );

        // update last claimed stage
        if (last_claimed_stage != 0) {
            update_user_last_claimed_stage(
                module_store,
                bridge_id,
                version,
                account_addr,
                last_claimed_stage
            );
        };

        // withdraw net reward from vault
        vault::withdraw(total_vested_reward)
    }

    public(friend) fun batch_claim_operator_reward(
        operator_addr: address,
        bridge_id: u64,
        version: u64,
        last_submitted_stage: u64,
        claim_infos: vector<OperatorVestingClaimInfo> /*asc sorted claim info*/
    ): FungibleAsset acquires ModuleStore {
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        let total_vested_reward = 0;
        let operator_vestings =
            load_operator_vestings_mut(module_store, bridge_id, version);
        let last_claimed_stage = 0;
        // extract unfinalized operator vesting from operator vestings

        let finalized_keys = vector[];

        // create vestings
        vector::for_each_ref<OperatorVestingClaimInfo>(
            &claim_infos,
            |claim_info| {
                let OperatorVestingClaimInfo { start_stage, end_stage: _, funded_reward } =
                    *claim_info;
                let initial_reward = funded_reward;

                assert!(
                    !table::contains(
                        operator_vestings,
                        table_key::encode_u64(start_stage)
                    ),
                    error::already_exists(EVESTING_ALREADY_CLAIMED)
                );

                // create operator vesting position
                create_operator_vesting(
                    operator_addr,
                    bridge_id,
                    version,
                    operator_vestings,
                    claim_info,
                    initial_reward
                );
                last_claimed_stage = start_stage;
            }
        );

        utils::walk_mut(
            operator_vestings,
            option::none(),
            option::none(),
            1,
            |stage_key, operator_vesting| {
                let reward_amount =
                    if (last_submitted_stage >= operator_vesting.end_stage) {
                        vector::push_back(&mut finalized_keys, stage_key);
                        operator_vesting.remaining_reward
                    } else {
                        let stage_diff =
                            last_submitted_stage - operator_vesting.start_stage;
                        let vesting_period =
                            operator_vesting.end_stage - operator_vesting.start_stage;
                        let vested_amount =
                            operator_vesting.initial_reward
                                - operator_vesting.remaining_reward;
                        let reward_amount =
                            utils::mul_div_u64(
                                operator_vesting.initial_reward,
                                stage_diff,
                                vesting_period
                            ) - vested_amount;
                        operator_vesting.remaining_reward =
                            operator_vesting.remaining_reward - reward_amount;
                        reward_amount
                    };

                event::emit(
                    OperatorVestingChangedEvent {
                        account: operator_addr,
                        bridge_id,
                        version,
                        start_stage: operator_vesting.start_stage,
                        initial_reward: operator_vesting.initial_reward,
                        remaining_reward: operator_vesting.remaining_reward
                    }
                );

                total_vested_reward = total_vested_reward + reward_amount;
                false
            }
        );

        // remove finalized vesting
        vector::for_each(
            finalized_keys,
            |stage_key| {
                let vesting = table::remove(operator_vestings, stage_key);
                event::emit(
                    OperatorVestingFinalizedEvent {
                        account: operator_addr,
                        bridge_id,
                        version,
                        start_stage: vesting.start_stage
                    }
                );
            }
        );

        // update last claimed stage
        if (last_claimed_stage != 0) {
            update_operator_last_claimed_stage(
                module_store,
                bridge_id,
                version,
                last_claimed_stage
            );
        };

        // withdraw total vested reward from reward store
        vault::withdraw(total_vested_reward)
    }

    public(friend) fun withdraw_vesting(
        account_addr: address,
        bridge_id: u64,
        version: u64,
        stage: u64,
        withdraw_amount: u64
    ): FungibleAsset acquires ModuleStore {
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        let user_vesting_store =
            table::borrow_mut(
                &mut module_store.user_vestings,
                generate_key(bridge_id, version, account_addr)
            );
        let stage_key = table_key::encode_u64(stage);
        // force claim_vesting
        assert!(
            table::contains(&user_vesting_store.vestings, stage_key),
            error::not_found(EVESTING_NOT_FOUND)
        );

        let user_vesting = table::borrow_mut(&mut user_vesting_store.vestings, stage_key);

        assert!(
            user_vesting.remaining_reward >= withdraw_amount,
            error::invalid_argument(EREWARD_NOT_ENOUGH)
        );
        user_vesting.remaining_reward = user_vesting.remaining_reward - withdraw_amount;
        event::emit(
            UserVestingChangedEvent {
                account: account_addr,
                bridge_id,
                version,
                start_stage: user_vesting.start_stage,
                initial_reward: user_vesting.initial_reward,
                remaining_reward: user_vesting.remaining_reward,
                penalty_reward: user_vesting.penalty_reward
            }
        );
        // handle vesting positions
        if (user_vesting.remaining_reward == 0) {
            let start_stage = user_vesting.start_stage;
            let penalty_reward = user_vesting.penalty_reward;
            // mark vesting positions finalized and emit event.
            table::remove(&mut user_vesting_store.vestings, stage_key);
            event::emit(
                UserVestingFinalizedEvent {
                    account: account_addr,
                    bridge_id,
                    version,
                    start_stage,
                    penalty_reward
                }
            );
        };

        vault::withdraw(withdraw_amount)
    }

    public(friend) fun build_user_vesting_claim_info(
        start_stage: u64,
        end_stage: u64,
        l2_score: u64,
        minimum_score_ratio: BigDecimal,
        total_l2_score: u64,
        funded_reward: u64
    ): UserVestingClaimInfo {
        UserVestingClaimInfo {
            start_stage,
            end_stage,
            l2_score,
            minimum_score_ratio,
            total_l2_score,
            funded_reward
        }
    }

    public(friend) fun build_operator_vesting_claim_info(
        start_stage: u64, end_stage: u64, funded_reward: u64
    ): OperatorVestingClaimInfo {
        OperatorVestingClaimInfo { start_stage, end_stage, funded_reward }
    }

    //
    // Public Functions
    //

    public fun is_user_vesting_store_registered(
        account_addr: address, bridge_id: u64, version: u64
    ): bool acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        table::contains(
            &module_store.user_vestings,
            generate_key(bridge_id, version, account_addr)
        )
    }

    public fun is_operator_vesting_store_registered(
        bridge_id: u64, version: u64
    ): bool acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        table::contains(
            &module_store.operator_vestings,
            generate_key(bridge_id, version, @0x0)
        )
    }

    public fun has_user_vesting_position(
        account_addr: address,
        bridge_id: u64,
        version: u64,
        stage: u64
    ): bool acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        let user_vestings =
            load_user_vestings_imut(module_store, bridge_id, version, account_addr);
        let stage_key = table_key::encode_u64(stage);
        table::contains(user_vestings, stage_key)
    }

    // calculate user vesting til current stage
    // ex. if claim_info.start_stage is 3, then calculate vesting reward of stage 1, 2
    // ex. 53 -> calculate 1~52 vesting reward
    fun batch_claim_previous_user_vestings(
        account_addr: address,
        bridge_id: u64,
        version: u64,
        vestings: &mut vector<UserVesting>,
        user_vestings: &mut Table<vector<u8> /*stage key*/, UserVesting>,
        claim_info: &UserVestingClaimInfo
    ): (u64, u64) {
        let net_vested_reward = 0u64;
        let net_penalty_reward = 0u64;
        let finalized_vestings_idx: vector<u64> = vector[]; // to delete from unfinalized vestings

        vector::enumerate_mut<UserVesting>(
            vestings,
            |idx, value| {
                let vest_amount =
                    if (claim_info.l2_score >= value.minimum_score) {
                        value.vest_max_amount
                    } else {
                        utils::mul_div_u64(
                            value.vest_max_amount,
                            claim_info.l2_score,
                            value.minimum_score
                        )
                    };
                if (value.remaining_reward >= value.vest_max_amount) {
                    net_vested_reward = net_vested_reward + vest_amount;
                    let penalty_amount = value.vest_max_amount - vest_amount;
                    net_penalty_reward = net_penalty_reward + penalty_amount;
                    value.remaining_reward = value.remaining_reward
                        - value.vest_max_amount;
                    value.penalty_reward = value.penalty_reward + penalty_amount;
                } else if (value.remaining_reward > vest_amount) {
                    net_vested_reward = net_vested_reward + vest_amount;
                    let penalty_amount = value.remaining_reward - vest_amount;
                    net_penalty_reward =
                        net_penalty_reward + value.remaining_reward - vest_amount;
                    value.remaining_reward = 0;
                    value.penalty_reward = value.penalty_reward + penalty_amount;
                } else {
                    net_vested_reward = net_vested_reward + value.remaining_reward;
                    value.remaining_reward = 0;
                };

                // position finalized when stage is over the end stage or remaining reward is 0
                if (claim_info.start_stage == value.end_stage
                    || value.remaining_reward == 0) {
                    event::emit(
                        UserVestingFinalizedEvent {
                            account: account_addr,
                            bridge_id,
                            version,
                            start_stage: value.start_stage,
                            penalty_reward: value.penalty_reward
                        }
                    );
                    // give the remaining reward occured by rounding error to user
                    if (value.remaining_reward > 0) {
                        net_vested_reward = net_vested_reward + value.remaining_reward;
                        value.remaining_reward = 0;
                    };
                    vector::push_back(&mut finalized_vestings_idx, idx);
                };
            }
        );

        // cleanup finalized vestings
        vector::for_each_reverse(
            finalized_vestings_idx,
            |index| {
                // remove finalized vesting
                let vesting = vector::remove(vestings, index);
                let start_stage = vesting.start_stage;

                // remove from vesting store
                let key = table_key::encode_u64(start_stage);
                if (table::contains(user_vestings, key)) {
                    table::remove(user_vestings, key);
                }
            }
        );

        (net_vested_reward, net_penalty_reward)
    }

    fun create_user_vesting(
        account_addr: address,
        bridge_id: u64,
        version: u64,
        user_vestings: &mut Table<vector<u8>, UserVesting>,
        vestings: &mut vector<UserVesting>,
        claim_info: &UserVestingClaimInfo,
        vesting_reward_amount: u64
    ) {
        let minimum_score =
            bigdecimal::mul_by_u64_truncate(
                claim_info.minimum_score_ratio,
                claim_info.l2_score
            );

        let user_vesting = UserVesting {
            initial_reward: vesting_reward_amount,
            remaining_reward: vesting_reward_amount,
            penalty_reward: 0,
            start_stage: claim_info.start_stage,
            end_stage: claim_info.end_stage,
            l2_score: claim_info.l2_score,
            minimum_score,
            vest_max_amount: vesting_reward_amount
                / (claim_info.end_stage - claim_info.start_stage)
        };

        // create user vesting position
        table::add(
            user_vestings,
            table_key::encode_u64(claim_info.start_stage),
            user_vesting
        );

        // add user vestings
        vector::push_back(vestings, user_vesting);

        event::emit(
            UserVestingCreateEvent {
                account: account_addr,
                bridge_id,
                version,
                start_stage: claim_info.start_stage,
                end_stage: claim_info.end_stage,
                l2_score: claim_info.l2_score,
                minimum_score,
                initial_reward: vesting_reward_amount
            }
        );
    }

    fun create_operator_vesting(
        account_addr: address,
        bridge_id: u64,
        version: u64,
        operator_vestings: &mut Table<vector<u8>, OperatorVesting>,
        claim_info: &OperatorVestingClaimInfo,
        initial_reward: u64
    ) {
        table::add(
            operator_vestings,
            table_key::encode_u64(claim_info.start_stage),
            OperatorVesting {
                initial_reward: initial_reward,
                remaining_reward: initial_reward,
                start_stage: claim_info.start_stage,
                end_stage: claim_info.end_stage
            }
        );

        event::emit(
            OperatorVestingCreateEvent {
                account: account_addr,
                bridge_id,
                version,
                start_stage: claim_info.start_stage,
                end_stage: claim_info.end_stage,
                initial_reward: initial_reward
            }
        );
    }

    //
    // Helper function
    //
    // get table key by bridge_id, version, account address
    fun generate_key(
        bridge_id: u64, version: u64, account_addr: address
    ): vector<u8> {
        let key = table_key::encode_u64(bridge_id);
        vector::append(&mut key, table_key::encode_u64(version));
        vector::append(&mut key, bcs::to_bytes(&account_addr));
        key
    }

    fun extract_user_vestings_vector(
        user_vestings: &mut Table<vector<u8>, UserVesting>
    ): vector<UserVesting> {
        let unfinalized_vestings: vector<UserVesting> = vector[];
        utils::walk(
            user_vestings,
            option::none(),
            option::none(),
            1,
            |_stage_key, user_vesting| {
                vector::push_back(&mut unfinalized_vestings, *user_vesting);
                false
            }
        );
        unfinalized_vestings
    }

    fun get_last_claimed_stage<Vesting: copy + drop + store>(
        account_addr: address, bridge_id: u64, version: u64
    ): u64 acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        let table_key = generate_key(bridge_id, version, account_addr);
        if (type_info::type_name<Vesting>() == type_info::type_name<OperatorVesting>()) {
            let operator_vesting_store =
                table::borrow(&module_store.operator_vestings, table_key);
            operator_vesting_store.last_claimed_stage
        } else if (type_info::type_name<Vesting>()
            == type_info::type_name<UserVesting>()) {
            let user_vesting_store = table::borrow(
                &module_store.user_vestings, table_key
            );
            user_vesting_store.last_claimed_stage
        } else {
            abort(error::invalid_argument(EINVALID_VESTING_TYPE))
        }
    }

    fun load_user_vestings_mut(
        module_store: &mut ModuleStore,
        bridge_id: u64,
        version: u64,
        account_addr: address
    ): &mut Table<vector<u8>, UserVesting> {
        let vesting_table_key = generate_key(bridge_id, version, account_addr);
        assert!(
            table::contains(
                &mut module_store.user_vestings,
                vesting_table_key
            ),
            error::not_found(EVESTING_NOT_FOUND)
        );
        let user_vesting_store =
            table::borrow_mut(
                &mut module_store.user_vestings,
                vesting_table_key
            );
        &mut user_vesting_store.vestings
    }

    fun load_user_vestings_imut(
        module_store: &ModuleStore,
        bridge_id: u64,
        version: u64,
        account_addr: address
    ): &Table<vector<u8>, UserVesting> {
        let vesting_table_key = generate_key(bridge_id, version, account_addr);
        assert!(
            table::contains(
                &module_store.user_vestings,
                vesting_table_key
            ),
            error::not_found(EVESTING_NOT_FOUND)
        );
        let user_vesting_store =
            table::borrow(
                &module_store.user_vestings,
                vesting_table_key
            );
        &user_vesting_store.vestings
    }

    fun load_user_vesting_imut(
        module_store: &ModuleStore,
        bridge_id: u64,
        version: u64,
        account_addr: address,
        stage: u64
    ): &UserVesting {
        let user_vestings =
            load_user_vestings_imut(module_store, bridge_id, version, account_addr);
        let stage_key = table_key::encode_u64(stage);
        assert!(
            table::contains(user_vestings, stage_key),
            error::not_found(EINVALID_STAGE)
        );
        table::borrow(user_vestings, stage_key)
    }

    fun update_user_last_claimed_stage(
        module_store: &mut ModuleStore,
        bridge_id: u64,
        version: u64,
        account_addr: address,
        last_claimed_stage: u64
    ) {
        let vesting_table_key = generate_key(bridge_id, version, account_addr);
        assert!(
            table::contains(
                &mut module_store.user_vestings,
                vesting_table_key
            ),
            error::not_found(EVESTING_NOT_FOUND)
        );
        let user_vesting_store =
            table::borrow_mut(
                &mut module_store.user_vestings,
                vesting_table_key
            );
        user_vesting_store.last_claimed_stage = last_claimed_stage;
    }

    fun load_operator_vestings_mut(
        module_store: &mut ModuleStore, bridge_id: u64, version: u64
    ): &mut Table<vector<u8>, OperatorVesting> {
        let vesting_table_key = generate_key(bridge_id, version, @0x0);
        assert!(
            table::contains(
                &mut module_store.operator_vestings,
                vesting_table_key
            ),
            error::not_found(EVESTING_NOT_FOUND)
        );
        let operator_vesting_store =
            table::borrow_mut(
                &mut module_store.operator_vestings,
                vesting_table_key
            );
        &mut operator_vesting_store.vestings
    }

    fun load_operator_vestings_imut(
        module_store: &ModuleStore, bridge_id: u64, version: u64
    ): &Table<vector<u8>, OperatorVesting> {
        let vesting_table_key = generate_key(bridge_id, version, @0x0);
        assert!(
            table::contains(
                &module_store.operator_vestings,
                vesting_table_key
            ),
            error::not_found(EVESTING_NOT_FOUND)
        );
        let operator_vesting_store =
            table::borrow(
                &module_store.operator_vestings,
                vesting_table_key
            );
        &operator_vesting_store.vestings
    }

    fun load_operator_vesting_imut(
        module_store: &ModuleStore,
        bridge_id: u64,
        version: u64,
        stage: u64
    ): &OperatorVesting {
        let operator_vestings =
            load_operator_vestings_imut(module_store, bridge_id, version);
        let stage_key = table_key::encode_u64(stage);
        assert!(
            table::contains(operator_vestings, stage_key),
            error::not_found(EINVALID_STAGE)
        );
        table::borrow(operator_vestings, stage_key)
    }

    fun update_operator_last_claimed_stage(
        module_store: &mut ModuleStore,
        bridge_id: u64,
        version: u64,
        last_claimed_stage: u64
    ) {
        let vesting_table_key = generate_key(bridge_id, version, @0x0);
        assert!(
            table::contains(
                &mut module_store.operator_vestings,
                vesting_table_key
            ),
            error::not_found(EVESTING_NOT_FOUND)
        );
        let operator_vesting_store =
            table::borrow_mut(
                &mut module_store.operator_vestings,
                vesting_table_key
            );
        operator_vesting_store.last_claimed_stage = last_claimed_stage;
    }

    public fun get_user_last_claimed_stage(
        account_addr: address, bridge_id: u64, version: u64
    ): u64 acquires ModuleStore {
        get_last_claimed_stage<UserVesting>(account_addr, bridge_id, version)
    }

    public fun get_operator_last_claimed_stage(
        bridge_id: u64, version: u64
    ): u64 acquires ModuleStore {
        get_last_claimed_stage<OperatorVesting>(@0x0, bridge_id, version)
    }

    //
    // View Functions
    //
    // <----- USER ----->
    #[view]
    public fun get_user_vesting(
        account_addr: address,
        bridge_id: u64,
        version: u64,
        stage: u64
    ): UserVestingResponse acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        let user_vesting =
            load_user_vesting_imut(
                module_store,
                bridge_id,
                version,
                account_addr,
                stage
            );
        UserVestingResponse {
            initial_reward: user_vesting.initial_reward,
            remaining_reward: user_vesting.remaining_reward,
            penalty_reward: user_vesting.penalty_reward,
            start_stage: user_vesting.start_stage,
            vest_max_amount: user_vesting.vest_max_amount,
            end_stage: user_vesting.end_stage,
            l2_score: user_vesting.l2_score,
            minimum_score: user_vesting.minimum_score
        }
    }

    // <----- OPERATOR ----->
    #[view]
    public fun get_operator_vesting(
        bridge_id: u64, version: u64, stage: u64
    ): OperatorVestingResponse acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        let operator_vesting =
            load_operator_vesting_imut(module_store, bridge_id, version, stage);
        OperatorVestingResponse {
            initial_reward: operator_vesting.initial_reward,
            remaining_reward: operator_vesting.remaining_reward,
            start_stage: operator_vesting.start_stage,
            end_stage: operator_vesting.end_stage
        }
    }

    //
    // Tests
    //

    #[test_only]
    use std::string;

    #[test_only]
    use initia_std::coin;

    #[test_only]
    use initia_std::object::Object;

    #[test_only]
    use initia_std::fungible_asset::Metadata;

    #[test_only]
    struct TestVesting has copy, drop, store {
        initial_reward: u64,
        remaining_reward: u64,
        start_stage: u64,
        end_stage: u64
    }

    #[test_only]
    public fun init_module_for_test(chain: &signer) {
        init_module(chain);
    }

    #[test_only]
    public fun get_user_vesting_minimum_score(
        account_addr: address,
        bridge_id: u64,
        version: u64,
        stage: u64
    ): u64 acquires ModuleStore {
        get_user_vesting(account_addr, bridge_id, version, stage).minimum_score
    }

    #[test_only]
    public fun get_user_vesting_initial_reward(
        account_addr: address,
        bridge_id: u64,
        version: u64,
        stage: u64
    ): u64 acquires ModuleStore {
        get_user_vesting(account_addr, bridge_id, version, stage).initial_reward
    }

    #[test_only]
    public fun get_user_vesting_remaining_reward(
        account_addr: address,
        bridge_id: u64,
        version: u64,
        stage: u64
    ): u64 acquires ModuleStore {
        get_user_vesting(account_addr, bridge_id, version, stage).remaining_reward
    }

    #[test_only]
    public fun get_user_vesting_penalty_reward(
        account_addr: address,
        bridge_id: u64,
        version: u64,
        stage: u64
    ): u64 acquires ModuleStore {
        get_user_vesting(account_addr, bridge_id, version, stage).penalty_reward
    }

    #[test_only]
    public fun get_user_vesting_remaining(
        account_addr: address,
        bridge_id: u64,
        version: u64,
        stage: u64
    ): u64 acquires ModuleStore {
        get_user_vesting(account_addr, bridge_id, version, stage).remaining_reward
    }

    #[test_only]
    public fun get_operator_vesting_initial_reward(
        bridge_id: u64, version: u64, stage: u64
    ): u64 acquires ModuleStore {
        get_operator_vesting(bridge_id, version, stage).initial_reward
    }

    #[test_only]
    public fun get_operator_vesting_remaining_reward(
        bridge_id: u64, version: u64, stage: u64
    ): u64 acquires ModuleStore {
        get_operator_vesting(bridge_id, version, stage).remaining_reward
    }

    #[test_only]
    public fun initialize_coin(
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

    // <-- VESTING ----->

    #[test(vip = @vip, account = @0x99)]
    fun test_register_vesting_store(vip: &signer, account: &signer) acquires ModuleStore {
        init_module_for_test(vip);
        let account_addr = signer::address_of(account);
        assert!(
            !is_user_vesting_store_registered(account_addr, 1, 1),
            1
        );
        register_user_vesting_store(account, 1, 1);
        assert!(
            is_user_vesting_store_registered(account_addr, 1, 1),
            2
        );
        register_user_vesting_store(account, 2, 1);
    }

    #[test(vip = @vip, account = @0x99)]
    #[expected_failure(abort_code = 0x80001, location = Self)]
    fun failed_register_vesting_store_twice(
        vip: &signer, account: &signer
    ) acquires ModuleStore {
        init_module_for_test(vip);
        register_user_vesting_store(account, 1, 1);
        register_user_vesting_store(account, 1, 1);
    }
}
