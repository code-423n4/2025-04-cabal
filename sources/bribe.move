module staking_addr::bribe {

    use std::error;
    use std::option;
    use std::signer;
    use std::string;
    use std::string::String;
    use std::vector;

    use initia_std::bigdecimal;
    use initia_std::bigdecimal::BigDecimal;
    use initia_std::coin;
    use initia_std::dex;
    use initia_std::event;
    use initia_std::fungible_asset;
    use initia_std::fungible_asset::Metadata;
    use initia_std::math64;
    use initia_std::object;
    use initia_std::object::Object;
    use initia_std::primary_fungible_store;
    use initia_std::simple_map;
    use initia_std::simple_map::SimpleMap;
    use initia_std::table;
    use initia_std::table::Table;
    use staking_addr::utils;

    use staking_addr::emergency;
    use staking_addr::package;
    //
    // Errors
    //

    const EINVALID_TOKEN: u64 = 1;
    const EINVALID_COIN_AMOUNT: u64 = 2;
    const EINVALID_BRIDGE: u64 = 3;
    const EINVALID_BPS: u64 = 4;
    const EMODULE_OPERATION: u64 = 5;

    //
    //  Constants
    //

    const BPS_BASE: u64 = 10000;
    const USD_DECIMALS: u64 = 6;

    struct ModuleStore has key {
        deposit_voting_reward_fee_bps: u64,
        voting_reward_token_metadata: vector<Object<Metadata>>,
        bribe: Table<u64, Table<u64, Table<Object<Metadata>, u64>>> // cycle ==> bridge_id ==> metadata
    }

    struct SupportTokenResponse has drop {
        name: String,
        symbol: String,
        metadata: Object<Metadata>,
        denom: String,
        decimals: u8,
        icon_uri: String
    }
    

    // Events
    #[event]
    struct DepositRewardEvent has drop, store {
        cycle: u64,
        bridge_id: u64,
        coin_metadata: address,
        commission_fee: u64,
        reward_amount: u64,
    }

    // Response
    struct ClaimedVotingRewardResponse has drop {
        metadata: Object<Metadata>,
        amount: u64,
    }

    struct BridgeRewardResponse has copy, drop {
        bridge_id: u64,
        amount: u64,
        weight: BigDecimal,
    }

    struct RewardResponse has copy, drop {
        metadata: Object<Metadata>,
        amount: u64,
    }

    fun init_module(account: &signer) {
        assert!(signer::address_of(account) == @staking_addr, error::unauthenticated(EMODULE_OPERATION));
        move_to(account, ModuleStore {
            deposit_voting_reward_fee_bps: 0,
            voting_reward_token_metadata: vector::empty(),
            bribe: table::new(),
        });
    }

    // View the current bribe deposit fee in basis points
    #[view]
    public fun deposit_voting_reward_fee_bps(): u64 acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        m_store.deposit_voting_reward_fee_bps
    }

    // View function to get the list of allowed bribe token metadatas
    #[view]
    public fun get_voting_reward_metadatas(): vector<Object<Metadata>> acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        m_store.voting_reward_token_metadata
    }

    #[view]
    public fun is_voting_reward_token(metadata: Object<Metadata>): bool acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        vector::contains(&m_store.voting_reward_token_metadata, &metadata)
    }

    // View function to get detailed information about allowed bribe tokens
    #[view]
    public fun get_voting_reward_tokens(): vector<SupportTokenResponse> acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        let res = vector::empty<SupportTokenResponse>();

        for (i in 0..vector::length(&m_store.voting_reward_token_metadata)) {
            vector::push_back(&mut res, SupportTokenResponse {
                name: fungible_asset::name(m_store.voting_reward_token_metadata[i]),
                symbol: fungible_asset::symbol(m_store.voting_reward_token_metadata[i]),
                metadata: m_store.voting_reward_token_metadata[i],
                denom: coin::metadata_to_denom(m_store.voting_reward_token_metadata[i]),
                decimals: fungible_asset::decimals(m_store.voting_reward_token_metadata[i]),
                icon_uri: fungible_asset::icon_uri(m_store.voting_reward_token_metadata[i]),
            });
        };

        res
    }

    // View function to calculate the relative weight of bribes per Minitia for a given cycle, based on INIT value
    // This is what is ultimately passed to the final weight function in Cabal.move to vote!
    #[view]
    public fun calculate_bribe_weights_for_cycle(cycle: u64): vector<BridgeRewardResponse> acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        let res: vector<BridgeRewardResponse> = vector::empty();
        if (!table::contains(&m_store.bribe, cycle)) {
            return res;
        };

        let cycle_bribe = table::borrow(&m_store.bribe, cycle); // Table mapping bridge_id -> bribe_table
        let iter = table::iter(
                cycle_bribe,
                option::none(),
                option::none(),
                1,
            );

        let total_amount: u64 = 0; // Total INIT value
        loop { // First loop: Calculate total INIT value and store per-bridge values
            if (!table::prepare<u64, Table<Object<Metadata>, u64>>(iter)) { break };
            let (bridge_id, bribe_table) = table::next<u64, Table<Object<Metadata>, u64>>(iter);
            let amount = calculate_bribe_value_in_usd(bribe_table);
            total_amount = total_amount + amount;
            vector::push_back(&mut res, BridgeRewardResponse {bridge_id, amount, weight: bigdecimal::zero()})
        };

        for (i in 0..vector::length(&res)) { // Second loop: Calculate the weight for each Minitia
            let record = vector::borrow_mut(&mut res, i);
            record.weight = bigdecimal::from_ratio_u64(record.amount, total_amount);
        };

        res
    }

    // View function to aggregate total bribe amounts per token type for a given cycle
    #[view]
    public fun get_total_bribes_by_token_for_cycle(cycle: u64): SimpleMap<Object<Metadata>, u64> acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        let res = simple_map::new<Object<Metadata>, u64>(); // Initialize a map for Metadata -> total amount
        if (!table::contains(&m_store.bribe, cycle)) {
            return res;
        };

        let cycle_bribe = table::borrow(&m_store.bribe, cycle); // Get the table for cycle (bridge_id -> bribe_table)
        let iter = table::iter(
            cycle_bribe,
            option::none(),
            option::none(),
            1,
        );

        loop { // Iterate through each bridge_id
            if (!table::prepare<u64, Table<Object<Metadata>, u64>>(iter)) { break };
            let (_, bribe_table) = table::next<u64, Table<Object<Metadata>, u64>>(iter);

            let bribe_iter = table::iter( // Create a nested iterator for the current bribe_table (metadata -> amount)
                bribe_table,
                option::none(),
                option::none(),
                1,
            );

            loop { // Inner loop: Iterate through each token bribed with this bridge.
                if (!table::prepare<Object<Metadata>, u64>(bribe_iter)) { break };
                let (coin_metadata, amount) = table::next<Object<Metadata>, u64>(bribe_iter);
                if (!simple_map::contains_key(&res, &coin_metadata)) {
                    simple_map::add(&mut res, coin_metadata, *amount);
                } else {
                    let value = simple_map::borrow_mut(&mut res, &coin_metadata);
                    *value = *value + *amount;
                };
            };
        };

        res // Return the map with aggregated totals per token type
    }

    public fun unpack_bridge_reward_response(res: BridgeRewardResponse): (u64, u64, BigDecimal) {
        (
            res.bridge_id,
            res.amount,
            res.weight,
        )
    }

    #[test_only]
    public fun get_bridge_reward_response_amount(res: &BridgeRewardResponse): u64 {
        res.amount
    }

    #[test_only]
    public fun get_bridge_reward_response_weight(res: &BridgeRewardResponse): BigDecimal {
        res.weight
    }

    #[test_only]
    public fun get_bridge_reward_response_bridge_id(res: &BridgeRewardResponse): u64 {
        res.bridge_id
    }

    // Entry function for the admin to set the bribe deposit fee
    public entry fun set_deposit_voting_reward_fee_bps(admin: &signer, new_bps: u64) acquires ModuleStore {
        assert!( signer::address_of(admin) == @staking_addr, error::unauthenticated(EMODULE_OPERATION));
        assert!(new_bps <= BPS_BASE, error::invalid_argument(EINVALID_BPS));

        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);
        m_store.deposit_voting_reward_fee_bps = new_bps;
    }

    // Entry function for the admin to configure the list of allowed bribe tokens
    public entry fun set_allowed_bribe_tokens(admin: &signer, voting_reward_tokens_metadata: vector<Object<Metadata>>) acquires ModuleStore {
        assert!( signer::address_of(admin) == @staking_addr, error::unauthenticated(EMODULE_OPERATION));
        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);
        m_store.voting_reward_token_metadata = voting_reward_tokens_metadata;
    }

    // The main entry function for anyone (ideally Minitias!) to deposit bribe rewards for a specific cycle and bridge
    #[test_only]
    public entry fun mock_deposit_bribe(account: &signer, coin_metadata: Object<Metadata>, reward_amount: u64, cycle: u64, bridge_id: u64) acquires ModuleStore {
        emergency::assert_no_paused();
        assert!(reward_amount > 0, error::invalid_argument(EINVALID_COIN_AMOUNT)); // Ensure deposit amount is positive
        let m_store = borrow_global_mut<ModuleStore>(@staking_addr); // Get mutable access to Modulestore
        assert!(vector::contains(&m_store.voting_reward_token_metadata, &coin_metadata), error::invalid_argument(EINVALID_TOKEN)); // Ensure the token is allowed for bribing

        // transfer the full bribe to the pool
        primary_fungible_store::transfer(
            account,
            coin_metadata,
            package::get_reward_store_address(),
            reward_amount
        );

        // Calculate the commission fee based on the configured bps
        let fee_ratio = bigdecimal::from_ratio_u64(m_store.deposit_voting_reward_fee_bps, BPS_BASE);
        let fee_amount = bigdecimal::mul_by_u64_truncate(fee_ratio, reward_amount);
        let rewards_remaining = reward_amount - fee_amount;

        // Transfer the calculated fee amount from the reward holding address to the commission fee address
        primary_fungible_store::transfer(&package::get_reward_store_signer(), coin_metadata, package::get_commission_fee_store_address(), fee_amount);

        // Store the net bribe amount in the nested table
        if (!table::contains(&m_store.bribe, cycle)) { // If no table exists for this cycle yet, create one
            table::add(&mut m_store.bribe, cycle, table::new<u64, Table<Object<Metadata>, u64>>())
        };

        let cycle_bribe = table::borrow_mut(&mut m_store.bribe, cycle); // Get a mutable reference to the table for this cycle (bridge_id -> bribe_table)
        if (!table::contains(cycle_bribe, bridge_id)) { // If no table for this bridge_id within this cycle, create it
            table::add(cycle_bribe, bridge_id, table::new<Object<Metadata>, u64>());
        };
        let bridge_bribe = table::borrow_mut(cycle_bribe, bridge_id); // Get a mutable reference to the table for this bridge (metadata -> amount)
        let bribe_amount = table::borrow_mut_with_default(bridge_bribe, coin_metadata, 0); // Get a mutable reference to the amount, defaulting to 0
        *bribe_amount = *bribe_amount + rewards_remaining; // Add the net reward amount to the stored amount for this token, bridge, cycle.

        // emit events
        event::emit(
            DepositRewardEvent {
                cycle,
                bridge_id,
                coin_metadata: object::object_address(&coin_metadata),
                commission_fee: fee_amount,
                reward_amount: rewards_remaining,
            }
        );
    }

    // The main entry function for anyone (ideally Minitias!) to deposit bribe rewards for a specific cycle and bridge
    public entry fun deposit_bribe(account: &signer, coin_metadata: Object<Metadata>, reward_amount: u64, cycle: u64, bridge_id: u64) acquires ModuleStore {
        emergency::assert_no_paused();
        assert!(reward_amount > 0, error::invalid_argument(EINVALID_COIN_AMOUNT)); // Ensure deposit amount is positive
        let m_store = borrow_global_mut<ModuleStore>(@staking_addr); // Get mutable access to Modulestore
        assert!(vip::vip::is_registered(bridge_id), error::invalid_argument(EINVALID_BRIDGE)); // Check if the bridge_id is valid
        assert!(vector::contains(&m_store.voting_reward_token_metadata, &coin_metadata), error::invalid_argument(EINVALID_TOKEN)); // Ensure the token is allowed for bribing

        // transfer the full bribe to the pool
        primary_fungible_store::transfer(
            account,
            coin_metadata,
            package::get_reward_store_address(),
            reward_amount
        );

        // Calculate the commission fee based on the configured bps
        let fee_ratio = bigdecimal::from_ratio_u64(m_store.deposit_voting_reward_fee_bps, BPS_BASE);
        let fee_amount = bigdecimal::mul_by_u64_truncate(fee_ratio, reward_amount);
        let rewards_remaining = reward_amount - fee_amount;

        // Transfer the calculated fee amount from the reward holding address to the commission fee address
        primary_fungible_store::transfer(&package::get_reward_store_signer(), coin_metadata, package::get_commission_fee_store_address(), fee_amount);

        // Store the net bribe amount in the nested table
        if (!table::contains(&m_store.bribe, cycle)) { // If no table exists for this cycle yet, create one
            table::add(&mut m_store.bribe, cycle, table::new<u64, Table<Object<Metadata>, u64>>())
        };

        let cycle_bribe = table::borrow_mut(&mut m_store.bribe, cycle); // Get a mutable reference to the table for this cycle (bridge_id -> bribe_table)
        if (!table::contains(cycle_bribe, bridge_id)) { // If no table for this bridge_id within this cycle, create it
            table::add(cycle_bribe, bridge_id, table::new<Object<Metadata>, u64>());
        };
        let bridge_bribe = table::borrow_mut(cycle_bribe, bridge_id); // Get a mutable reference to the table for this bridge (metadata -> amount)
        let bribe_amount = table::borrow_mut_with_default(bridge_bribe, coin_metadata, 0); // Get a mutable reference to the amount, defaulting to 0
        *bribe_amount = *bribe_amount + rewards_remaining; // Add the net reward amount to the stored amount for this token, bridge, cycle.

        // emit events
        event::emit(
            DepositRewardEvent {
                cycle,
                bridge_id,
                coin_metadata: object::object_address(&coin_metadata),
                commission_fee: fee_amount,
                reward_amount: rewards_remaining,
            }
        );
    }

    // Internal helper function to calculate the total value in INIT of all bribes in a specific bridge's table
    fun calculate_bribe_value_in_usd(bribe_table: &Table<Object<Metadata>, u64>): u64 {
        let iter = table::iter(
            bribe_table,
            option::none(),
            option::none(),
            1,
        );
        let res: BigDecimal = bigdecimal::zero();

        loop {
            if (!table::prepare<Object<Metadata>, u64>(iter)) { break };
            let (coin_metadata, amount) = table::next<Object<Metadata>, u64>(iter);
            let value = utils::get_token_value_in_usd(coin_metadata, *amount);
            res = bigdecimal::add(res, bigdecimal::mul_by_u64(value, math64::pow(10, USD_DECIMALS)));
        };

        bigdecimal::truncate_u64(res)
    }

    // Internal helper function to get the price of a token relative to INIT using the Initia DEX
    fun get_token_price_in_init(coin_metadata: Object<Metadata>): BigDecimal {
        let init_metadata = coin::metadata(@initia_std, string::utf8(b"uinit"));
        if (coin_metadata == init_metadata) {
            return bigdecimal::one();
        };
        let pairs = dex::get_pairs(
            object::object_address(&init_metadata),
            object::object_address(&coin_metadata),
            option::none(),
            1
        );
        if (vector::is_empty(&pairs)) {
            pairs = dex::get_pairs(
                object::object_address(&coin_metadata),
                object::object_address(&init_metadata),
                option::none(),
                1
            );
        };
        if (vector::is_empty(&pairs)) {
            return bigdecimal::zero();
        };
        let (_, _, config, _, _) = dex::unpack_pair_response(vector::borrow(&pairs, 0));
        dex::get_spot_price(object::address_to_object<dex::Config>(config), coin_metadata)
    }

    #[test_only]
    public fun init_module_for_test(staking_addr: &signer) {
        init_module(staking_addr);
    }

}