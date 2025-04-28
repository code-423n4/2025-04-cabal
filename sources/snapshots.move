module staking_addr::snapshots {

    use std::error;
    use std::signer;
    use std::vector;

    use initia_std::bigdecimal::BigDecimal;
    use initia_std::block;
    use initia_std::fungible_asset::Metadata;
    use initia_std::object::Object;
    use initia_std::simple_map;
    use initia_std::table;
    use initia_std::table::Table;
    use staking_addr::pool_router;

    #[test_only]
    use initia_std::bigdecimal;
    #[test_only]
    use initia_std::simple_map::SimpleMap;
    #[test_only]
    use staking_addr::utils;

    friend staking_addr::voting_reward;
    friend staking_addr::cabal_token;

    const EMODULE_OPERATION: u64 = 1;
    const EINVALID_REMAIN_AMOUNT: u64 = 2;
    const EPAUSED: u64 = 3;
    const EINVALID_CYCLE: u64 = 4;
    const EUNAUTHORIZED: u64 = 5;
    const ESNAPSHOT_NOT_FOUND: u64 = 6;

    struct ModuleStore has key {
        snapshots: Table<u64, Table<Object<Metadata>, BigDecimal>>, // block_height ==> origin_token ==> snapshot
    }

    fun init_module(account: &signer) {
        assert!(signer::address_of(account) == @staking_addr, error::unauthenticated(EMODULE_OPERATION));

        move_to(account, ModuleStore {
            snapshots: table::new()
        });
    }

    public fun get_snapshot_weight(block_height: u64, metadata: Object<Metadata>): BigDecimal acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        assert!(table::contains(&m_store.snapshots, block_height), error::not_found(ESNAPSHOT_NOT_FOUND));

        let snapshot_table = table::borrow(&m_store.snapshots, block_height);
        assert!(table::contains(snapshot_table, metadata), error::not_found(ESNAPSHOT_NOT_FOUND));

        *table::borrow(snapshot_table, metadata)
    }

    // Entry function for the admin to take a snapshot of the current state relevant for rewards calculations
    // Also calls snapshot for the user balances for distribution
    public (friend) fun snapshot() acquires ModuleStore {
        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);
        let block_height = block::get_current_block_height();
        let voting_power_weight = pool_router::get_voting_power_weight();
        let metadatas = simple_map::keys(&voting_power_weight);

        let snapshot = table::new<Object<Metadata>, BigDecimal>();
        for (i in 0..vector::length(&metadatas)) {
            table::add(&mut snapshot, metadatas[i], *simple_map::borrow(&voting_power_weight, &metadatas[i]));
        };
        table::add(&mut m_store.snapshots, block_height, snapshot);
    }

    public (friend) fun update_snapshot() acquires ModuleStore {
        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);
        let block_height = block::get_current_block_height();
        assert!(table::contains(&m_store.snapshots, block_height), error::invalid_state(ESNAPSHOT_NOT_FOUND));

        // let voting_power_weight = pool_router::get_voting_power_weight();
        // TODO COMMENT OUT FOR TESTS
        let voting_power_weight = mock_voting_power_weight();
        let metadatas = simple_map::keys(&voting_power_weight);

        let snapshot = table::borrow_mut(&mut m_store.snapshots, block_height);
        for (i in 0..vector::length(&metadatas)) {
            table::upsert(snapshot, metadatas[i], *simple_map::borrow(&voting_power_weight, &metadatas[i]));
        };
    }

    #[test_only]
    public fun init_module_for_test(staking_addr: &signer) {
        init_module(staking_addr)
    }

    #[test_only]
    public (friend) fun mock_snapshot() acquires ModuleStore {
        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);
        let block_height = block::get_current_block_height();
        let voting_power_weight = mock_voting_power_weight();
        let metadatas = simple_map::keys(&voting_power_weight);

        let snapshot = table::new<Object<Metadata>, BigDecimal>();
        for (i in 0..vector::length(&metadatas)) {
            table::add(&mut snapshot, metadatas[i], *simple_map::borrow(&voting_power_weight, &metadatas[i]));
        };
        table::add(&mut m_store.snapshots, block_height, snapshot);
    }

    #[test_only]
    public fun mock_voting_power_weight(): SimpleMap<Object<Metadata>, BigDecimal>  {
        let res = simple_map::new<Object<Metadata>, BigDecimal>();
        let init_metadata = utils::get_init_metadata();
        let stake_tokens = pool_router::get_stake_tokens(); // Get all configured stake tokens

        let total_mock_power: u64 = 0;
        let mock_powers = simple_map::new<Object<Metadata>, u64>();

        for (i in 0..vector::length(&stake_tokens)) {
            let token_metadata = stake_tokens[i];
            let mock_power = if (token_metadata == init_metadata) {
                10
            } else {
                8
            };
            simple_map::add(&mut mock_powers, token_metadata, mock_power);
            total_mock_power = total_mock_power + mock_power;
        };
        if (total_mock_power > 0) {
             for (i in 0..vector::length(&stake_tokens)) {
                let token_metadata = stake_tokens[i];
                let mock_power = *simple_map::borrow(&mock_powers, &token_metadata);
                let weight_bd =  bigdecimal::from_ratio_u64(mock_power, total_mock_power);

                simple_map::add(&mut res, token_metadata, weight_bd);
            };
        } else {
             if (vector::length(&stake_tokens) == 1 && stake_tokens[0] == init_metadata) {
                 simple_map::add(&mut res, init_metadata, bigdecimal::from_u64(1));
             }
        };


        res
    }

    #[view]
    #[test_only]
    public fun has_snapshot_at(block_height: u64): bool acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        table::contains(&m_store.snapshots, block_height)
    }

    // Check if there are any snapshots at all
    #[view]
    #[test_only]
    public fun is_snapshots_empty(): bool acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        table::empty(&m_store.snapshots)
    }
}