module vip::weight_vote {
    use std::error;
    use std::option::{Self, Option};
    use std::signer;
    use std::string;
    use std::vector;

    use initia_std::block::get_block_info;
    use initia_std::coin;
    use initia_std::bigdecimal::{Self, BigDecimal};
    use initia_std::event;
    use initia_std::fungible_asset::Metadata;
    use initia_std::object::Object;
    use initia_std::simple_map;
    use initia_std::table::{Self, Table};
    use initia_std::table_key;

    use vip::lock_staking;
    use vip::utils;
    use vip::vip;

    use vesting::vesting;

    //
    // Errors
    //

    const EMODULE_STORE_ALREADY_EXISTS: u64 = 1;
    const EUNAUTHORIZED: u64 = 2;
    // VOTE ERROR
    const EVOTING_END: u64 = 3;
    // EINVALID ERROR
    const EINVALID_PARAMETER: u64 = 6;
    const EINVALID_BRIDGE: u64 = 7;
    const EINVALID_VOTING_POWER: u64 = 8;
    const EINVALID_ARGS_LENGTH: u64 = 9;
    // NOT FOUND ERROR
    const ECYCLE_NOT_FOUND: u64 = 10;

    // LOCK TIME WEIGHT MULTIPLIER
    const DEFAULT_MIN_WEIGHT_MULTIPLIER: u64 = 1;
    const DEFAULT_MAX_WEIGHT_MULTIPLIER: u64 = 4;

    struct ModuleStore has key {
        // current cycle
        current_cycle: u64,
        // cycle interval
        cycle_interval: u64,
        // current cycle start time
        cycle_start_time: u64,
        // current cycle end time
        cycle_end_time: u64,
        // change bridge weights proposals
        proposals: Table<vector<u8> /* cycle */, Proposal>,
        // voting period
        voting_period: u64,
        // pair weight
        pair_multipliers: Table<Object<Metadata>, BigDecimal>,
        // core vesting creator
        core_vesting_creator: address,
        // max lock staking multplier for voting
        max_lock_period_multiplier: u64,
        // min lock staking multplier for voting
        min_lock_period_multiplier: u64
    }

    struct Proposal has store {
        votes: Table<address, WeightVote>,
        total_tally: u64,
        tallies: Table<vector<u8> /* bridge id */, u64 /* tally */>,
        voting_end_time: u64,
        executed: bool
    }

    struct WeightVote has store {
        max_voting_power: u64,
        voting_power: u64,
        weights: vector<Weight>
    }

    struct Weight has copy, drop, store {
        bridge_id: u64,
        weight: BigDecimal
    }

    struct Vote has store {
        vote_option: bool,
        voting_power: u64
    }

    //
    // responses
    //
    struct ProposalResponse has drop {
        total_tally: u64,
        voting_end_time: u64,
        executed: bool
    }

    struct WeightVoteResponse has drop {
        max_voting_power: u64,
        voting_power: u64,
        weights: vector<Weight>
    }

    struct TallyResponse has drop {
        bridge_id: u64,
        tally: u64
    }

    // events

    #[event]
    struct VoteEvent has drop, store {
        account: address,
        cycle: u64,
        max_voting_power: u64,
        voting_power: u64,
        weights: vector<Weight>
    }

    #[event]
    struct ExecuteProposalEvent has drop, store {
        cycle: u64,
        bridge_ids: vector<u64>,
        weights: vector<BigDecimal>
    }

    // initialize function

    public entry fun initialize(
        chain: &signer,
        cycle_start_time: u64,
        cycle_interval: u64,
        voting_period: u64,
        vesting_creator: address
    ) {
        assert!(
            signer::address_of(chain) == @vip,
            error::permission_denied(EUNAUTHORIZED)
        );
        assert!(
            !exists<ModuleStore>(@vip),
            error::already_exists(EMODULE_STORE_ALREADY_EXISTS)
        );

        move_to(
            chain,
            ModuleStore {
                current_cycle: 0,
                cycle_interval,
                cycle_start_time,
                cycle_end_time: cycle_start_time,
                proposals: table::new(),
                voting_period,
                pair_multipliers: table::new(),
                core_vesting_creator: vesting_creator,
                min_lock_period_multiplier: DEFAULT_MIN_WEIGHT_MULTIPLIER,
                max_lock_period_multiplier: DEFAULT_MAX_WEIGHT_MULTIPLIER
            }
        )
    }

    public entry fun update_params(
        chain: &signer,
        cycle_interval: Option<u64>,
        voting_period: Option<u64>,
        core_vesting_creator: Option<address>,
        max_lock_period_multiplier: Option<u64>,
        min_lock_period_multiplier: Option<u64>
    ) acquires ModuleStore {
        utils::check_chain_permission(chain);
        let module_store = borrow_global_mut<ModuleStore>(@vip);

        if (option::is_some(&cycle_interval)) {
            module_store.cycle_interval = option::extract(&mut cycle_interval);
        };

        if (option::is_some(&voting_period)) {
            module_store.voting_period = option::extract(&mut voting_period);
        };

        if (option::is_some(&core_vesting_creator)) {
            module_store.core_vesting_creator = option::extract(
                &mut core_vesting_creator
            );
        };

        if (option::is_some(&max_lock_period_multiplier)) {
            module_store.max_lock_period_multiplier = option::extract(
                &mut max_lock_period_multiplier
            );
        };

        if (option::is_some(&min_lock_period_multiplier)) {
            module_store.min_lock_period_multiplier = option::extract(
                &mut min_lock_period_multiplier
            );
        };

        // voting period must be less than cycle interval
        assert!(
            module_store.voting_period < module_store.cycle_interval,
            error::invalid_argument(EINVALID_PARAMETER)
        );

        // check lock period multiplier
        assert!(
            module_store.min_lock_period_multiplier
                <= module_store.max_lock_period_multiplier,
            error::invalid_argument(EINVALID_PARAMETER)
        );
    }

    public entry fun update_pair_multiplier(
        chain: &signer, metadata: Object<Metadata>, multiplier: BigDecimal
    ) acquires ModuleStore {
        utils::check_chain_permission(chain);
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        table::upsert(
            &mut module_store.pair_multipliers,
            metadata,
            multiplier
        );
    }

    //
    // entry functions
    //

    // weight vote

    public entry fun vote(
        account: &signer,
        cycle: u64,
        bridge_ids: vector<u64>,
        weights: vector<BigDecimal>
    ) acquires ModuleStore {
        create_proposal();
        vip::add_tvl_snapshot();
        let addr = signer::address_of(account);
        let max_voting_power = get_voting_power(addr);
        assert!(max_voting_power != 0, error::unavailable(EINVALID_VOTING_POWER));
        assert!(
            vector::length(&bridge_ids) == vector::length(&weights),
            EINVALID_ARGS_LENGTH
        );

        let module_store = borrow_global_mut<ModuleStore>(@vip);
        let (_, time) = get_block_info();

        // check bridge valid
        vector::for_each(
            bridge_ids,
            |bridge_id| {
                assert!(
                    vip::is_registered(bridge_id),
                    error::invalid_argument(EINVALID_BRIDGE)
                );
            }
        );
        let weight_sum = bigdecimal::zero();
        vector::for_each_ref(
            &weights,
            |weight| {
                weight_sum = bigdecimal::add(weight_sum, *weight);
            }
        );
        assert!(
            bigdecimal::le(weight_sum, bigdecimal::one()),
            error::invalid_argument(EINVALID_PARAMETER)
        );
        let voting_power_used =
            bigdecimal::mul_by_u64_truncate(weight_sum, max_voting_power);
        // check vote condition
        let cycle_key = table_key::encode_u64(cycle);
        assert!(
            table::contains(&module_store.proposals, cycle_key),
            error::not_found(ECYCLE_NOT_FOUND)
        );
        let proposal = table::borrow_mut(&mut module_store.proposals, cycle_key);
        assert!(
            time <= proposal.voting_end_time,
            error::invalid_state(EVOTING_END)
        );

        // remove former vote
        if (table::contains(&proposal.votes, addr)) {
            let WeightVote { max_voting_power, voting_power: _, weights } =
                table::remove(&mut proposal.votes, addr);
            remove_vote(proposal, max_voting_power, weights);
        };

        let weight_vector = vector[];
        vector::zip_reverse(
            bridge_ids,
            weights,
            |bridge_id, weight| {
                vector::push_back(&mut weight_vector, Weight { bridge_id, weight });
            }
        );

        // apply vote
        apply_vote(proposal, max_voting_power, weight_vector);

        // store user votes
        table::add(
            &mut proposal.votes,
            addr,
            WeightVote {
                max_voting_power,
                voting_power: voting_power_used,
                weights: weight_vector
            }
        );

        // emit event
        event::emit(
            VoteEvent {
                account: addr,
                cycle,
                max_voting_power,
                voting_power: voting_power_used,
                weights: weight_vector
            }
        )
    }

    public entry fun create_proposal() acquires ModuleStore {
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        let (_, time) = get_block_info();

        // cycle not end
        if (module_store.cycle_end_time >= time) { return };

        // get the last voted proposal
        // execute proposal not executed
        if (module_store.current_cycle != 0) {
            let proposal =
                table::borrow_mut(
                    &mut module_store.proposals,
                    table_key::encode_u64(module_store.current_cycle)
                );
            if (!proposal.executed && proposal.voting_end_time < time) {
                execute_proposal_internal(proposal, module_store.current_cycle);
            };
        };
        // update cycle
        module_store.current_cycle = module_store.current_cycle + 1;
        module_store.cycle_start_time = calculate_cycle_start_time(module_store);
        let voting_end_time = module_store.cycle_start_time
            + module_store.voting_period;

        // set cycle end time
        module_store.cycle_end_time =
            module_store.cycle_start_time + module_store.cycle_interval;

        // initiate weight vote
        table::add(
            &mut module_store.proposals,
            table_key::encode_u64(module_store.current_cycle),
            Proposal {
                votes: table::new(),
                total_tally: 0,
                tallies: table::new(),
                voting_end_time,
                executed: false
            }
        );
    }

    // it will be executed by agent; but there is no permission to execute proposal
    public entry fun execute_proposal() acquires ModuleStore {
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        let (_, time) = get_block_info();

        // get the last voting proposal
        // check vote state
        let proposal =
            table::borrow_mut(
                &mut module_store.proposals,
                table_key::encode_u64(module_store.current_cycle)
            );

        if (proposal.voting_end_time >= time) { return };

        if (proposal.executed) { return };

        execute_proposal_internal(proposal, module_store.current_cycle);
    }

    fun execute_proposal_internal(
        proposal: &mut Proposal, current_cycle: u64
    ) {
        // update vip weights
        let (bridge_ids, _) = vip::get_whitelisted_bridge_ids();

        let index = 0;
        let len = vector::length(&bridge_ids);
        let weights: vector<BigDecimal> = vector[];
        while (index < len) {
            let bridge_id = *vector::borrow(&bridge_ids, index);
            let tally =
                table::borrow_with_default(
                    &proposal.tallies,
                    table_key::encode_u64(bridge_id),
                    &0
                );
            let weight =
                if (proposal.total_tally == 0) {
                    bigdecimal::from_ratio_u64(1, len)
                } else {
                    bigdecimal::from_ratio_u64(*tally, proposal.total_tally)
                };
            vector::push_back(&mut weights, weight);
            index = index + 1;
        };

        vip::update_vip_weights_for_friend(bridge_ids, weights);

        // emit event
        event::emit(ExecuteProposalEvent { cycle: current_cycle, bridge_ids, weights });

        // update proposal state
        proposal.executed = true;
    }

    // helper functions
    fun last_finalized_proposal(module_store: &ModuleStore, time: u64): (u64, &Proposal) {
        let iter = table::iter(
            &module_store.proposals,
            option::none(),
            option::none(),
            2
        );
        assert!(
            table::prepare<vector<u8>, Proposal>(iter),
            error::not_found(ECYCLE_NOT_FOUND)
        );
        let (cycle_key, proposal) = table::next<vector<u8>, Proposal>(iter);

        // if last proposal is in progress, use former proposal
        if (proposal.voting_end_time > time) {
            assert!(
                table::prepare<vector<u8>, Proposal>(iter),
                error::not_found(ECYCLE_NOT_FOUND)
            );
            (cycle_key, _) = table::next<vector<u8>, Proposal>(iter);
        };

        let last_finalized_proposal_cycle = table_key::decode_u64(cycle_key);
        let last_finalized_proposal = table::borrow(&module_store.proposals, cycle_key);
        (last_finalized_proposal_cycle, last_finalized_proposal)
    }

    // weight vote

    fun remove_vote(
        proposal: &mut Proposal, max_voting_power: u64, weights: vector<Weight>
    ) {
        let voting_power_removed = 0;
        vector::for_each(
            weights,
            |w| {
                let bridge_vp =
                    bigdecimal::mul_by_u64_truncate(w.weight, max_voting_power);
                voting_power_removed = voting_power_removed + bridge_vp;
                let tally =
                    table::borrow_mut_with_default(
                        &mut proposal.tallies,
                        table_key::encode_u64(w.bridge_id),
                        0
                    );
                *tally = *tally - bridge_vp;
            }
        );
        proposal.total_tally = proposal.total_tally - voting_power_removed;
    }

    fun apply_vote(
        proposal: &mut Proposal, max_voting_power: u64, weights: vector<Weight>
    ) {
        let voting_power_used = 0;
        vector::for_each(
            weights,
            |w| {
                let bridge_vp =
                    bigdecimal::mul_by_u64_truncate(w.weight, max_voting_power);
                voting_power_used = voting_power_used + bridge_vp;
                let tally =
                    table::borrow_mut_with_default(
                        &mut proposal.tallies,
                        table_key::encode_u64(w.bridge_id),
                        0
                    );
                *tally = *tally + bridge_vp;
            }
        );
        proposal.total_tally = proposal.total_tally + voting_power_used
    }

    // To handle case that proposal not create more than one cycle period
    // set cycle start time to former cycle end time + skipped cycle count * cycle interval
    fun calculate_cycle_start_time(module_store: &ModuleStore): u64 {
        let (_, time) = get_block_info();
        let skiped_cycle = (time - module_store.cycle_end_time)
            / module_store.cycle_interval;
        let voting_start_time =
            module_store.cycle_end_time + skiped_cycle * module_store.cycle_interval;
        voting_start_time
    }

    fun get_vesting_voting_power(creator: address, addr: address): u64 {
        if (!vesting::has_vesting(creator, addr)) {
            return 0
        };

        // https://github.com/initia-labs/initia/blob/937dacd87704437e0713f913d9c468a0a92dae60/x/move/keeper/vesting.go#L133
        let vesting_info = vesting::vesting_info(creator, addr);
        let (allocation, claimed_amount, start_time, vesting_period, _, _) =
            vesting::lookup_vesting(&vesting_info);
        let (_, time) = get_block_info();

        if (time < start_time) {
            return 0
        };

        if (time >= start_time + vesting_period) {
            return allocation - claimed_amount
        };

        allocation * (time - start_time) / vesting_period - claimed_amount
    }

    fun get_lock_period_multiplier(
        module_store: &ModuleStore, lock_period: u64
    ): BigDecimal {
        let (min_lock_period, max_lock_period) = lock_staking::get_lock_period_limits();
        let max_multiplier = module_store.max_lock_period_multiplier;
        let min_multiplier = module_store.min_lock_period_multiplier;

        if (lock_period <= min_lock_period) {
            return bigdecimal::from_u64(min_multiplier)
        };

        if (lock_period >= max_lock_period) {
            return bigdecimal::from_u64(max_multiplier)
        };

        // slope = (max_multiplier - min_multiplier) / (max_lock_period - min_lock_period)
        // multiplier = slope * (lock_period - min_lock_period) + min_multiplier
        let numerator = (max_multiplier - min_multiplier) * (lock_period
            - min_lock_period);
        let denominator = (max_lock_period - min_lock_period);
        bigdecimal::add_by_u64(
            bigdecimal::from_ratio_u64(numerator, denominator),
            min_multiplier
        )
    }

    fun get_lock_staking_voting_power(
        module_store: &ModuleStore,
        weight_map: &simple_map::SimpleMap<string::String, BigDecimal>,
        addr: address
    ): u64 {
        let (_, curr_time) = get_block_info();

        // lock period multiplier adjusted amounts
        let delegate_amount_map = simple_map::new<Object<Metadata>, u64>();
        vector::for_each_ref(
            &simple_map::keys(weight_map),
            |denom| {
                simple_map::add(
                    &mut delegate_amount_map, coin::denom_to_metadata(*denom), 0
                );
            }
        );

        // get total delegate amounts
        let locked_delegations = lock_staking::get_locked_delegations(addr);
        vector::for_each_ref(
            &locked_delegations,
            |delegation| {
                let (metadata, _, amount, release_time) =
                    lock_staking::unpack_locked_delegation(delegation);

                let lock_period =
                    if (release_time > curr_time) {
                        release_time - curr_time
                    } else { 0 };
                let lock_time_weight =
                    get_lock_period_multiplier(module_store, lock_period);

                let amount_before =
                    simple_map::borrow_mut(&mut delegate_amount_map, &metadata);

                *amount_before =
                    *amount_before
                        + bigdecimal::mul_by_u64_truncate(lock_time_weight, amount);
            }
        );

        // get total voting power
        let total_voting_power = 0;
        vector::for_each_ref(
            &simple_map::keys(weight_map),
            |denom| {
                let metadata = coin::denom_to_metadata(*denom);
                let amount = *simple_map::borrow(&delegate_amount_map, &metadata);
                let weight = simple_map::borrow(weight_map, denom);
                let pair_multiplier =
                    table::borrow_with_default(
                        &module_store.pair_multipliers,
                        metadata,
                        &bigdecimal::one()
                    );
                let voting_power =
                    bigdecimal::mul_by_u64_truncate(
                        *pair_multiplier,
                        bigdecimal::mul_by_u64_truncate(*weight, amount)
                    );
                total_voting_power = total_voting_power + voting_power;
            }
        );

        return total_voting_power
    }

    //
    // views
    //

    #[view]
    public fun get_total_tally(cycle: u64): u64 acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        let cycle_key = table_key::encode_u64(cycle);
        assert!(
            table::contains(&module_store.proposals, cycle_key),
            error::not_found(ECYCLE_NOT_FOUND)
        );
        let proposal = table::borrow(&module_store.proposals, cycle_key);
        proposal.total_tally
    }

    #[view]
    public fun get_tally_infos(cycle: u64): vector<TallyResponse> acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        let cycle_key = table_key::encode_u64(cycle);
        assert!(
            table::contains(&module_store.proposals, cycle_key),
            error::not_found(ECYCLE_NOT_FOUND)
        );
        let proposal = table::borrow(&module_store.proposals, cycle_key);

        let tally_responses: vector<TallyResponse> = vector[];

        let (bridge_ids, _) = vip::get_whitelisted_bridge_ids();

        vector::for_each(
            bridge_ids,
            |bridge_id| {
                let tally =
                    table::borrow_with_default(
                        &proposal.tallies,
                        table_key::encode_u64(bridge_id),
                        &0
                    );
                vector::push_back(
                    &mut tally_responses,
                    TallyResponse { bridge_id, tally: *tally }
                )
            }
        );

        return tally_responses
    }

    #[view]
    public fun get_proposal(cycle: u64): ProposalResponse acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        let cycle_key = table_key::encode_u64(cycle);
        assert!(
            table::contains(&module_store.proposals, cycle_key),
            error::not_found(ECYCLE_NOT_FOUND)
        );
        let proposal = table::borrow(&module_store.proposals, cycle_key);

        ProposalResponse {
            total_tally: proposal.total_tally,
            voting_end_time: proposal.voting_end_time,
            executed: proposal.executed
        }
    }

    #[view]
    public fun get_voting_power(addr: address): u64 acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        let cosmos_voting_power =
            utils::get_customized_voting_power(
                addr,
                |metadata, voting_power| {
                    let weight =
                        table::borrow_with_default(
                            &module_store.pair_multipliers,
                            metadata,
                            &bigdecimal::one()
                        );
                    bigdecimal::mul_by_u64_truncate(*weight, voting_power)
                }
            );

        let weight_map = utils::get_weight_map();
        let lock_staking_voting_power =
            get_lock_staking_voting_power(module_store, &weight_map, addr);

        let vesting_voting_power =
            get_vesting_voting_power(module_store.core_vesting_creator, addr);
        // mul weight
        let init_weight = simple_map::borrow(&weight_map, &string::utf8(b"uinit"));
        vesting_voting_power = bigdecimal::mul_by_u64_truncate(
            *init_weight, vesting_voting_power
        );

        cosmos_voting_power + lock_staking_voting_power + vesting_voting_power
    }

    #[view]
    public fun get_weight_vote(cycle: u64, user: address): WeightVoteResponse acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        let cycle_key = table_key::encode_u64(cycle);
        assert!(
            table::contains(&module_store.proposals, cycle_key),
            error::not_found(ECYCLE_NOT_FOUND)
        );
        let proposal = table::borrow(&module_store.proposals, cycle_key);

        if (!table::contains(&proposal.votes, user)) {
            return WeightVoteResponse {
                max_voting_power: 0,
                voting_power: 0,
                weights: vector[]
            }
        };

        let WeightVote { max_voting_power, voting_power, weights } =
            table::borrow(&proposal.votes, user);

        WeightVoteResponse {
            max_voting_power: *max_voting_power,
            voting_power: *voting_power,
            weights: *weights
        }
    }

    #[view]
    public fun get_pair_multipliers(
        metadata: vector<Object<Metadata>>
    ): vector<BigDecimal> acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        vector::map_ref(
            &metadata,
            |metadata| {
                *table::borrow_with_default(
                    &module_store.pair_multipliers,
                    *metadata,
                    &bigdecimal::one()
                )
            }
        )
    }

    #[test_only]
    struct TestState has key {
        capability: AdminCapability
    }

    #[test_only]
    use initia_std::block;

    #[test_only]
    use initia_std::biguint;

    #[test_only]
    use initia_std::mock_mstaking;

    #[test_only]
    use vesting::vesting::{AdminCapability};

    #[test_only]
    use vip::tvl_manager;

    #[test_only]
    const DEFAULT_VIP_L2_CONTRACT_FOR_TEST: vector<u8> = (b"vip_l2_contract");

    #[test_only]
    fun skip_period(period: u64) {
        let (height, curr_time) = block::get_block_info();
        block::set_block_info(height + period / 2, curr_time + period);
    }

    #[test_only]
    const DECIMAL_FRACTIONAL: u64 = 1000000000000000000;

    #[test_only]
    fun is_within_tolerance(
        a: BigDecimal, b: BigDecimal, tolerance: BigDecimal
    ): bool {
        let b_min = bigdecimal::sub(b, tolerance);
        let b_max = bigdecimal::add(b, tolerance);
        if (bigdecimal::lt(a, b_min) || bigdecimal::gt(a, b_max)) {
            return false
        };
        true
    }

    #[test_only]
    public fun get_tally(cycle: u64, bridge_id: u64): u64 acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        let cycle_key = table_key::encode_u64(cycle);
        assert!(
            table::contains(&module_store.proposals, cycle_key),
            error::not_found(ECYCLE_NOT_FOUND)
        );
        let proposal = table::borrow(&module_store.proposals, cycle_key);
        *table::borrow_with_default(
            &proposal.tallies,
            table_key::encode_u64(bridge_id),
            &0
        )
    }

    #[test_only]
    fun init_test(chain: &signer, vip: &signer, vesting_creator: &signer) {
        let cycle_start_time = 100;
        let cycle_interval = 100;
        let voting_period = 80;
        let vm_type = 0; // move
        initialize(
            vip,
            cycle_start_time,
            cycle_interval,
            voting_period,
            signer::address_of(vesting_creator)
        );
        mock_mstaking::initialize(chain);
        lock_staking::init_module_for_test(vip);
        vesting::test_init(vesting_creator);
        let capability =
            vesting::create_vesting_store(
                vesting_creator, mock_mstaking::get_init_metadata()
            );
        vesting::disable_claim(&capability);
        move_to(vip, TestState { capability });
        block::set_block_info(100, 101);
        tvl_manager::init_module_for_test(vip);
        vip::init_module_for_test(vip);
        vip::register(
            vip,
            @0x2,
            1,
            @0x12,
            string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
            bigdecimal::zero(),
            bigdecimal::zero(),
            bigdecimal::zero(),
            vm_type
        );
        vip::register(
            vip,
            @0x2,
            2,
            @0x12,
            string::utf8(DEFAULT_VIP_L2_CONTRACT_FOR_TEST),
            bigdecimal::zero(),
            bigdecimal::zero(),
            bigdecimal::zero(),
            vm_type
        );

        let init_metadata = mock_mstaking::get_init_metadata();
        let lp_metadata = mock_mstaking::get_lp_metadata();

        coin::transfer(chain, @0x101, init_metadata, 200);
        coin::transfer(chain, @0x102, init_metadata, 200);

        coin::transfer(chain, @0x103, init_metadata, 200);
        coin::transfer(chain, @0x104, init_metadata, 200);
        coin::transfer(chain, @0x101, lp_metadata, 200);
        coin::transfer(chain, @0x102, lp_metadata, 200);
        coin::transfer(chain, @0x103, lp_metadata, 200);
        coin::transfer(chain, @0x104, lp_metadata, 200);
    }

    // test calculate voting power by comsos staking(mstaking), lock staking
    #[test(
        chain = @0x1, vip = @vip, vesting_creator = @initia_std, u1 = @0x101, u2 = @0x102
    )]
    fun test_get_voting_power(
        chain: &signer,
        vip: &signer,
        vesting_creator: &signer,
        u1: &signer,
        u2: &signer
    ) acquires ModuleStore {
        init_test(chain, vip, vesting_creator);
        let validator = mock_mstaking::get_validator1();
        let init_metadata = mock_mstaking::get_init_metadata();
        let lp_metadata = mock_mstaking::get_lp_metadata();

        // check the mstaking delegation makes the voting power
        mock_mstaking::delegate(u1, validator, init_metadata, 10);
        mock_mstaking::delegate(u2, validator, init_metadata, 30);

        assert!(get_voting_power(signer::address_of(u1)) == 10, 1);
        assert!(get_voting_power(signer::address_of(u2)) == 30, 1);

        mock_mstaking::delegate(u1, validator, init_metadata, 30);
        mock_mstaking::delegate(u2, validator, init_metadata, 10);
        assert!(get_voting_power(signer::address_of(u1)) == 40, 1);
        assert!(get_voting_power(signer::address_of(u2)) == 40, 1);

        mock_mstaking::undelegate(u1, validator, init_metadata, 10);
        mock_mstaking::undelegate(u2, validator, init_metadata, 10);
        assert!(get_voting_power(signer::address_of(u1)) == 30, 1);
        assert!(get_voting_power(signer::address_of(u2)) == 30, 1);

        // check the lock staking delegation makes the voting power
        lock_staking::mock_delegate(u1, lp_metadata, 30, 60 * 60 * 24 * 26, validator);
        skip_period(2);
        lock_staking::mock_delegate(u2, lp_metadata, 80, 60 * 60 * 24 * 26, validator);
        skip_period(2);

        assert!(get_voting_power(signer::address_of(u1)) == 61, 1);
        assert!(get_voting_power(signer::address_of(u2)) == 114, 1);

        lock_staking::mock_delegate(u1, lp_metadata, 90, 60 * 60 * 24 * 26, validator);
        skip_period(2);
        lock_staking::mock_delegate(u2, lp_metadata, 40, 60 * 60 * 24 * 26, validator);
        skip_period(2);

        assert!(get_voting_power(signer::address_of(u1)) == 156, 1);
        assert!(get_voting_power(signer::address_of(u2)) == 156, 1);

        mock_mstaking::slash(validator, mock_mstaking::get_slash_factor());
        assert!(get_voting_power(signer::address_of(u1)) == 140, 1);
        assert!(get_voting_power(signer::address_of(u2)) == 140, 1);

        // undelegate lock staking 108(120 * 0.9 ,by slash)
        skip_period(60 * 60 * 24 * 26);
        lock_staking::mock_undelegate(
            u1,
            lp_metadata,
            option::none(),
            60 * 60 * 24 * 26,
            validator
        );
        skip_period(2);
        lock_staking::mock_undelegate(
            u2,
            lp_metadata,
            option::none(),
            60 * 60 * 24 * 26,
            validator
        );
        skip_period(2);
        assert!(get_voting_power(signer::address_of(u1)) == 27, 1);
        assert!(get_voting_power(signer::address_of(u2)) == 27, 1);

    }

    #[test(
        chain = @0x1, vip = @vip, vesting_creator = @initia_std, u1 = @0x101, u2 = @0x102
    )]
    fun test_vote_with_dynamic_voting_power(
        chain: &signer,
        vip: &signer,
        vesting_creator: &signer,
        u1: &signer,
        u2: &signer
    ) acquires ModuleStore {
        init_test(chain, vip, vesting_creator);
        let cycle = 1;
        let validator = mock_mstaking::get_validator1();
        let init_metadata = mock_mstaking::get_init_metadata();
        let lp_metadata = mock_mstaking::get_lp_metadata();
        mock_mstaking::delegate(u1, validator, init_metadata, 5);
        lock_staking::mock_delegate(u1, lp_metadata, 5, 60 * 60 * 24 * 26, validator);
        skip_period(2);
        mock_mstaking::delegate(u2, validator, init_metadata, 10);
        lock_staking::mock_delegate(u2, lp_metadata, 10, 60 * 60 * 24 * 26, validator);
        skip_period(2);
        vote(
            u1,
            cycle,
            vector[1, 2],
            vector[bigdecimal::from_ratio_u64(1, 5), bigdecimal::from_ratio_u64(4, 5)] // 2, 8
        );

        vote(
            u2,
            cycle,
            vector[1, 2],
            vector[bigdecimal::from_ratio_u64(2, 5), bigdecimal::from_ratio_u64(3, 5)] // 8, 12
        );

        let proposal = get_proposal(1);
        assert!(proposal.total_tally == 30, 0);
        let vote1 = get_tally(1, 1);
        let vote2 = get_tally(1, 2);
        let total_tally = get_total_tally(1);
        assert!(vote1 == 10, 1);
        assert!(vote2 == 20, 2);
        assert!(total_tally == 30, 3);

        mock_mstaking::delegate(u1, validator, init_metadata, 5);
        mock_mstaking::undelegate(u2, validator, init_metadata, 5);

        vote(
            u1,
            cycle,
            vector[1, 2],
            vector[bigdecimal::from_ratio_u64(1, 2), bigdecimal::from_ratio_u64(1, 2)] // 7 / 7
        );

        proposal = get_proposal(1);
        assert!(proposal.total_tally == 34, 0);
        vote1 = get_tally(1, 1);
        vote2 = get_tally(1, 2);
        total_tally = get_total_tally(1);
        assert!(vote1 == 15, 4);
        assert!(vote2 == 19, 5);
        assert!(total_tally == 34, 6);

        vote(
            u2,
            cycle,
            vector[1, 2],
            vector[bigdecimal::from_ratio_u64(1, 3), bigdecimal::from_ratio_u64(1, 3)] // 4 / 4 -> truncate error?
        );

        proposal = get_proposal(1);
        assert!(proposal.total_tally == 22, 7);
        vote1 = get_tally(1, 1);
        vote2 = get_tally(1, 2);
        total_tally = get_total_tally(1);
        assert!(vote1 == 11, 8);
        assert!(vote2 == 11, 9);
        assert!(total_tally == 22, 10);
    }

    #[
        test(
            chain = @0x1,
            vip = @vip,
            vesting_creator = @initia_std,
            u1 = @0x101,
            u2 = @0x102,
            u3 = @0x103,
            u4 = @0x104
        )
    ]
    fun test_proposal_end_to_end(
        chain: &signer,
        vip: &signer,
        vesting_creator: &signer,
        u1: &signer,
        u2: &signer,
        u3: &signer,
        u4: &signer
    ) acquires ModuleStore {
        init_test(chain, vip, vesting_creator);
        let cycle = 1;
        let validator = mock_mstaking::get_validator1();
        let init_metadata = mock_mstaking::get_init_metadata();
        let lp_metadata = mock_mstaking::get_lp_metadata();
        mock_mstaking::delegate(u1, validator, init_metadata, 5);
        lock_staking::mock_delegate(u1, lp_metadata, 5, 60 * 60 * 24 * 26, validator);
        skip_period(2);
        mock_mstaking::delegate(u2, validator, init_metadata, 10);
        lock_staking::mock_delegate(u2, lp_metadata, 10, 60 * 60 * 24 * 26, validator);
        skip_period(2);
        mock_mstaking::delegate(u3, validator, init_metadata, 30);
        mock_mstaking::delegate(u4, validator, init_metadata, 40);
        vote(
            u1,
            cycle,
            vector[1, 2],
            vector[bigdecimal::from_ratio_u64(1, 5), bigdecimal::from_ratio_u64(4, 5)] // 2, 8
        );

        vote(
            u2,
            cycle,
            vector[1, 2],
            vector[bigdecimal::from_ratio_u64(2, 5), bigdecimal::from_ratio_u64(3, 5)] // 8, 12
        );

        vote(
            u3,
            cycle,
            vector[1, 2],
            vector[bigdecimal::from_ratio_u64(2, 5), bigdecimal::from_ratio_u64(2, 5)] // 12, 12
        );

        vote(
            u4,
            cycle,
            vector[1, 2],
            vector[bigdecimal::from_ratio_u64(3, 5), bigdecimal::from_ratio_u64(1, 5)] // 24, 8 // user can vote with
        );

        let proposal = get_proposal(1);
        assert!(proposal.total_tally == 86, 0);
        let vote1 = get_tally(1, 1);
        let vote2 = get_tally(1, 2);
        let total_tally = get_total_tally(1);
        assert!(vote1 == 46, 1);
        assert!(vote2 == 40, 2);
        assert!(total_tally == 86, 3);

        let weight_vote = get_weight_vote(1, signer::address_of(u1));
        assert!(weight_vote.voting_power == 10, 4);
        assert!(vector::length(&weight_vote.weights) == 2, 5);
        // update vote of u4
        vote(
            u4,
            cycle,
            vector[1, 2],
            vector[bigdecimal::from_ratio_u64(4, 5), bigdecimal::from_ratio_u64(1, 5)] // 32, 8 // user can vote with
        );

        vote1 = get_tally(1, 1);
        vote2 = get_tally(1, 2);
        total_tally = get_total_tally(1);
        assert!(vote1 == 54, 6);
        assert!(vote2 == 40, 7);
        assert!(total_tally == 94, 8);

        // update vote of u3
        vote(
            u3,
            cycle,
            vector[1, 2],
            vector[bigdecimal::zero(), bigdecimal::zero()] // 0, 0
        );

        vote1 = get_tally(1, 1);
        vote2 = get_tally(1, 2);
        total_tally = get_total_tally(1);
        assert!(vote1 == 42, 9);
        assert!(vote2 == 28, 10);
        assert!(total_tally == 70, 11);
        let weight_vote = get_weight_vote(1, signer::address_of(u1));
        assert!(weight_vote.voting_power == 10, 12);
        assert!(vector::length(&weight_vote.weights) == 2, 13);

        skip_period(300);
        execute_proposal();
    }

    #[test_only]
    const ONE_WEEK: u64 = 7 * 60 * 60 * 24;
    #[test_only]
    const ONE_MONTH: u64 = 30 * 60 * 60 * 24;
    #[test_only]
    const ONE_YEAR: u64 = 365 * 60 * 60 * 24;
    #[test_only]
    const TOLERANCE: u64 = 110; // denominator : DECIMAL_FRACTIONAL
    #[test(chain = @0x1, vip = @vip, vesting_creator = @initia_std)]
    fun test_lock_period_multiplier(
        chain: &signer, vip: &signer, vesting_creator: &signer
    ) acquires ModuleStore {
        init_test(chain, vip, vesting_creator);
        let min_lock_period = ONE_MONTH; // one month
        let max_lock_period = 4 * ONE_YEAR; // 4 year
        lock_staking::update_params(
            chain,
            option::some(min_lock_period),
            option::some(max_lock_period),
            option::none()
        );
        let module_store = borrow_global<ModuleStore>(@vip);
        let max_multiplier = module_store.max_lock_period_multiplier;
        let min_multiplier = module_store.min_lock_period_multiplier;
        // 1) lock period < ONE MONTH
        let lock_period = ONE_WEEK;
        assert!(
            get_lock_period_multiplier(module_store, lock_period)
                == bigdecimal::from_u64(min_multiplier),
            1
        );
        lock_period = min_lock_period;
        assert!(
            get_lock_period_multiplier(module_store, lock_period)
                == bigdecimal::from_u64(min_multiplier),
            2
        );
        // 2) lock period >= ONE MONTH && lock period =< 4 year
        lock_period = 4 * ONE_MONTH;
        // (3_000_000_000_000_000_000n)*(3n * 30n * 60n * 60n * 24n)/ (1430n * 60n * 60n * 24n) + 1_000_000_000_000_000_000n
        // = 1188811188811188811n
        assert!(
            get_lock_period_multiplier(module_store, lock_period)
                == bigdecimal::from_scaled(biguint::from_u64(1188811188811188811)),
            3
        );

        lock_period = 3 * ONE_YEAR;
        // (3_000_000_000_000_000_000n)*(1065n * 60n * 60n * 24n)/ (1430n * 60n * 60n * 24n) + 1_000_000_000_000_000_000n
        // = 3234265734265734265n
        assert!(
            get_lock_period_multiplier(module_store, lock_period)
                == bigdecimal::from_scaled(biguint::from_u128(3234265734265734265)),
            4
        );

        lock_period = max_lock_period;
        assert!(
            get_lock_period_multiplier(module_store, lock_period)
                == bigdecimal::from_u64(max_multiplier),
            5
        );
        // 3) lock period > 4 year
        lock_period = 5 * ONE_YEAR;
        assert!(
            get_lock_period_multiplier(module_store, lock_period)
                == bigdecimal::from_u64(max_multiplier),
            6
        );
    }
}
