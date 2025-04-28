module vip::tvl_manager {
    use std::error;
    use std::event;
    use std::vector;

    use initia_std::block;
    use initia_std::table;
    use initia_std::table_key;

    use vip::utils;
    friend vip::vip;

    const EINVALID_BRIDGE_ID: u64 = 1;

    const DEFAULT_SNAPSHOT_INTERVAL: u64 = 60 * 60 * 4; // 4 hours

    struct ModuleStore has key {
        last_snapshot_time: u64,
        last_snapshot_stage: u64,
        snapshot_interval: u64, // minimum snapshot interval
        // The average tvl each stage(vip stage) and bridge id
        summary: table::Table<vector<u8> /*stage + bridge id*/, TvlSummary>
    }

    struct TvlSummary has drop, store, copy {
        count: u64, // snapshot count
        tvl: u64
    }

    #[event]
    struct TVLSnapshotEvent has drop {
        stage: u64,
        bridge_id: u64,
        time: u64,
        tvl: u64
    }

    fun init_module(chain: &signer) {
        move_to(
            chain,
            ModuleStore {
                last_snapshot_time: 0,
                last_snapshot_stage: 0,
                snapshot_interval: DEFAULT_SNAPSHOT_INTERVAL,
                summary: table::new<vector<u8> /*stage + bridge id*/, TvlSummary>()
            }
        );
    }

    fun generate_key(stage: u64, bridge_id: u64): vector<u8> {
        let key = table_key::encode_u64(stage);
        vector::append(&mut key, table_key::encode_u64(bridge_id));
        key
    }

    public entry fun update_snapshot_interval(
        chain: &signer, new_snapshot_interval: u64
    ) acquires ModuleStore {
        utils::check_chain_permission(chain);
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        module_store.snapshot_interval = new_snapshot_interval;
    }

    public fun is_snapshot_addable(stage: u64): bool acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        let (_, curr_time) = block::get_block_info();
        // return true if either of the following two conditions is met
        // - the current stage is beyond the last snapshot stage
        // - past the snapshot interval since the last snapshot
        let is_addable_stage = stage > module_store.last_snapshot_stage;
        let is_addable_time =
            curr_time
                >= module_store.snapshot_interval + module_store.last_snapshot_time;
        is_addable_stage || is_addable_time
    }

    // add the snapshot of the tvl on the bridge at the stage
    public(friend) fun add_snapshot(
        stage: u64, bridge_ids: vector<u64>, tvls: vector<u64>
    ) acquires ModuleStore {
        let (_, curr_time) = block::get_block_info();
        if (!is_snapshot_addable(stage)) { return };

        let module_store = borrow_global_mut<ModuleStore>(@vip);
        module_store.last_snapshot_time = curr_time;
        module_store.last_snapshot_stage = stage;
        vector::enumerate_ref(
            &bridge_ids,
            |i, bridge_id| {
                let tvl = vector::borrow(&tvls, i);
                let summary_table_key = generate_key(stage, *bridge_id);
                let summary =
                    table::borrow_mut_with_default(
                        &mut module_store.summary,
                        summary_table_key,
                        TvlSummary { count: 0, tvl: 0 }
                    );
                // new average tvl = (snapshot_count * average_tvl + balance) / (snapshot_count + 1)
                let new_count = summary.count + 1;
                let new_average_tvl =
                    (((summary.count as u128) * (summary.tvl as u128) + (*tvl as u128))
                        / (new_count as u128));
                table::upsert(
                    &mut module_store.summary,
                    summary_table_key,
                    TvlSummary { count: new_count, tvl: (new_average_tvl as u64) }
                );
                event::emit(
                    TVLSnapshotEvent {
                        stage,
                        bridge_id: *bridge_id,
                        time: curr_time,
                        tvl: *tvl
                    }
                );
            }
        );
    }

    // get the average tvl of the bridge from accumulated snapshots of the stage
    #[view]
    public fun get_average_tvl(stage: u64, bridge_id: u64): u64 acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        let summary_table_key = generate_key(stage, bridge_id);
        assert!(
            table::contains(&module_store.summary, summary_table_key),
            error::not_found(EINVALID_BRIDGE_ID)
        );
        table::borrow(&module_store.summary, summary_table_key).tvl
    }

    #[test_only]
    const DEFAULT_EPOCH_FOR_TEST: u64 = 1;

    #[test_only]
    const DEFAULT_BRIDE_ID_FOR_TEST: u64 = 2;

    #[test_only]
    const DEFAULT_SKIP_FOR_TEST: u64 = 100;
    #[test_only]
    public fun init_module_for_test(chain: &signer) {
        init_module(chain)
    }

    #[test_only]
    fun skip_period(period: u64) {
        let (height, curr_time) = block::get_block_info();
        block::set_block_info(height, curr_time + period);
    }

    #[test(vip = @vip)]
    public fun add_snapshot_for_test(vip: &signer) acquires ModuleStore {
        init_module_for_test(vip);
        let balance = 1_000_000_000_000;
        add_snapshot(
            DEFAULT_EPOCH_FOR_TEST,
            vector[DEFAULT_BRIDE_ID_FOR_TEST],
            vector[balance]
        );

        let average_tvl =
            get_average_tvl(
                DEFAULT_EPOCH_FOR_TEST,
                DEFAULT_BRIDE_ID_FOR_TEST
            );
        assert!(average_tvl == balance, 0);
    }

    #[test(vip = @vip)]
    public fun add_multi_snapshot_for_test(vip: &signer) acquires ModuleStore {
        init_module_for_test(vip);
        let balance1 = 1_000_000_000_000;
        let balance2 = 2_000_000_000_000;
        let balance3 = 3_000_000_000_000;
        add_snapshot(
            DEFAULT_EPOCH_FOR_TEST,
            vector[DEFAULT_BRIDE_ID_FOR_TEST],
            vector[balance1]
        );
        skip_period(DEFAULT_SNAPSHOT_INTERVAL);
        add_snapshot(
            DEFAULT_EPOCH_FOR_TEST,
            vector[DEFAULT_BRIDE_ID_FOR_TEST],
            vector[balance2]
        );
        skip_period(DEFAULT_SNAPSHOT_INTERVAL);
        add_snapshot(
            DEFAULT_EPOCH_FOR_TEST,
            vector[DEFAULT_BRIDE_ID_FOR_TEST],
            vector[balance3]
        );
        let average_tvl =
            get_average_tvl(
                DEFAULT_EPOCH_FOR_TEST,
                DEFAULT_BRIDE_ID_FOR_TEST
            );
        assert!(average_tvl == 2_000_000_000_000, 0);
    }
}
