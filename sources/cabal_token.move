module staking_addr::cabal_token {
    use std::error;
    use std::option;
    use std::option::Option;
    use std::signer;
    use std::string;
    use std::string::String;
    use std::vector;
    use initia_std::block;
    use initia_std::coin;
    use initia_std::dispatchable_fungible_asset;
    use initia_std::event;
    use initia_std::function_info;
    use initia_std::fungible_asset;
    use initia_std::fungible_asset::{FungibleAsset, TransferRef, MintRef, BurnRef, Metadata};
    use initia_std::object;
    use initia_std::object::Object;
    use initia_std::primary_fungible_store;
    use initia_std::table;
    use initia_std::table::Table;
    use initia_std::table_key;
    use staking_addr::snapshots;

    use staking_addr::manager;

    #[test_only]
    use staking_addr::utils;

    friend staking_addr::voting_reward;

    friend staking_addr::cabal;

    const EMODULE_OPERATION: u64 = 1;
    const EMANAGING_REFS_NOT_FOUND: u64 = 2;
    const EBALANCE_NOT_ENOUGH: u64 = 3;
    const ELENGTH_NOT_EQUAL: u64 = 4;
    const EUNSUPPORT_TOKEN: u64 = 5;
    const EUNAUTHORIZED: u64 = 6;

    struct ModuleStore has key {
        token_metadatas: vector<Object<Metadata>>,
        snapshot_block: Option<u64>,
        prv_snapshot_block: Option<u64>,
    }

    struct HolderStore has key {
        holder_balance_map: Table<address, CabalBalance>,
        supply_snapshots: Table<u64, u128>,  // block_height  ==> supply
    }

    struct CabalBalance has store {
        balance: u64,
        start_block: u64,
        snapshot: Table<vector<u8>, u64>
    }

    struct ManagingRefs has key {
        mint_ref: MintRef,
        burn_ref: BurnRef,
        transfer_ref: TransferRef
    }

    struct MintCapability has drop, store {
        metadata: Object<Metadata>
    }

    struct BurnCapability has drop, store {
        metadata: Object<Metadata>
    }

    struct FreezeCapability has drop, store {
        metadata: Object<Metadata>
    }

    #[event]
    struct CoinCreatedEvent has drop, store {
        metadata_addr: address
    }

    fun init_module(account: &signer) {
        assert!(signer::address_of(account) == @staking_addr, error::unauthenticated(EMODULE_OPERATION));
        move_to(account, ModuleStore {
            token_metadatas: vector::empty(),
            snapshot_block: option::none(),
            prv_snapshot_block: option::none(),
        });
    }

    public entry fun update_l2_data(account: &signer, metadata: Object<Metadata>, block_height: u64, l2_address: address, addresses: vector<address>, amounts: vector<u64>) acquires HolderStore {
        // Only the manager should be able to call this
        assert!(manager::is_authorized(account), error::permission_denied(EUNAUTHORIZED));

        assert!(vector::length(&addresses) == vector::length(&amounts), error::invalid_argument(ELENGTH_NOT_EQUAL));
        let metadata_addr = object::object_address(&metadata);
        let key = table_key::encode_u64(block_height);
        let holder_store = borrow_global_mut<HolderStore>(metadata_addr);

        // init l2 snapshot
        let l2_cabal_balance = table::borrow_mut(&mut holder_store.holder_balance_map, l2_address);
        let l2_snapshot_balance = get_snapshot_balance_internal(l2_cabal_balance, block_height);
        let l2_snapshot_value = *table::borrow_with_default(&l2_cabal_balance.snapshot, key, &l2_snapshot_balance);

        for (i in 0..vector::length(&addresses)) {
            // init user snapshot
            let user_cabal_balance = table::borrow_mut(&mut holder_store.holder_balance_map, addresses[i]);
            let user_snapshot_balance = get_snapshot_balance_internal(user_cabal_balance, block_height);
            let user_snapshot_value = table::borrow_mut_with_default(&mut user_cabal_balance.snapshot, key, user_snapshot_balance);

            // update snapshot
            assert!(l2_snapshot_value >= amounts[i], error::invalid_argument(EBALANCE_NOT_ENOUGH));
            l2_snapshot_value = l2_snapshot_value - amounts[i];
            *user_snapshot_value = *user_snapshot_value + amounts[i];
        };

        l2_cabal_balance = table::borrow_mut(&mut holder_store.holder_balance_map, l2_address);
        table::upsert(&mut l2_cabal_balance.snapshot, key, l2_snapshot_value);
    }

    public fun initialize(
        account: &signer, // Signer used to create the named object (e.g., asset store signer)
        module_owner: &signer, // Signer of the address where this module is published (@staking_addr)
        maximum_supply: Option<u128>,
        name: String,
        symbol: String,
        decimals: u8,
        icon_uri: String,
        project_uri: String
    ): (MintCapability, BurnCapability, FreezeCapability) acquires ModuleStore {
        assert!(signer::address_of(module_owner) == @staking_addr, error::unauthenticated(EMODULE_OPERATION));

        let constructor_ref = &object::create_named_object(account, *string::bytes(&symbol));

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            constructor_ref,
            maximum_supply,
            name,
            symbol,
            decimals,
            icon_uri,
            project_uri
        );

        let withdraw = function_info::new_function_info(
            module_owner, // Use the actual module owner signer
            string::utf8(b"cabal_token"),
            string::utf8(b"withdraw")
        );
        let deposit = function_info::new_function_info(
            module_owner, // Use the actual module owner signer
            string::utf8(b"cabal_token"),
            string::utf8(b"deposit")
        );

        dispatchable_fungible_asset::register_dispatch_functions(
            constructor_ref,
            option::some(withdraw),
            option::some(deposit),
            option::none()
        );

        let mint_ref = fungible_asset::generate_mint_ref(constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(constructor_ref);

        let object_signer = object::generate_signer(constructor_ref);

        move_to(
            &object_signer,
            ManagingRefs { mint_ref, burn_ref, transfer_ref }
        );

        move_to(
            &object_signer,
            HolderStore { holder_balance_map: table::new(), supply_snapshots: table::new() }
        );

        let metadata_addr = object::address_from_constructor_ref(constructor_ref);
        event::emit(CoinCreatedEvent { metadata_addr });

        let metadata = object::object_from_constructor_ref<Metadata>(constructor_ref);

        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);
        vector::push_back(&mut m_store.token_metadatas, metadata);

        (
            MintCapability { metadata },
            BurnCapability { metadata },
            FreezeCapability { metadata }
        )
    }

    public fun mint_to(
        mint_cap: &MintCapability, recipient: address, amount: u64
    ) acquires ManagingRefs, HolderStore, ModuleStore {
        let metadata = mint_cap.metadata;
        let metadata_addr = object::object_address(&metadata);
        assert!(exists<ManagingRefs>(metadata_addr), error::not_found(EMANAGING_REFS_NOT_FOUND));

        let cabal_balance = get_mut_cabal_balance(recipient, mint_cap.metadata);
        cabal_balance.balance = cabal_balance.balance + amount;

        let refs = borrow_global<ManagingRefs>(metadata_addr);
        primary_fungible_store::mint(&refs.mint_ref, recipient, amount);

        // if concurrent, update the snapshot.
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        let holder_store = borrow_global_mut<HolderStore>(metadata_addr);
        let current_block_height = block::get_current_block_height();
        if (option::is_some(&m_store.snapshot_block) && current_block_height == *option::borrow(&m_store.snapshot_block)) {
            table::upsert(
                &mut holder_store.supply_snapshots,
                current_block_height,
                option::get_with_default(&coin::supply(metadata), 0));

            snapshots::update_snapshot();
        }
    }

    public fun burn(burn_cap: &BurnCapability, fa: FungibleAsset) acquires ManagingRefs {
        let metadata = burn_cap.metadata;
        let metadata_addr = object::object_address(&metadata);

        assert!(exists<ManagingRefs>(metadata_addr), EMANAGING_REFS_NOT_FOUND);
        let refs = borrow_global<ManagingRefs>(metadata_addr);

        fungible_asset::burn(&refs.burn_ref, fa)
    }

    public fun deposit<T: key>(
        store: Object<T>, fa: FungibleAsset, transfer_ref: &TransferRef
    ) acquires HolderStore, ModuleStore {
        let metadata = fungible_asset::metadata_from_asset(&fa);
        let cabal_balance = get_mut_cabal_balance(object::owner(store), metadata);

        cabal_balance.balance = cabal_balance.balance + fungible_asset::amount(&fa);

        fungible_asset::deposit_with_ref(transfer_ref, store, fa)
    }

    public fun withdraw<T: key>(
        store: Object<T>, amount: u64, transfer_ref: &TransferRef
    ): FungibleAsset acquires HolderStore, ModuleStore {
        let metadata= fungible_asset::transfer_ref_metadata(transfer_ref);
        let cabal_balance = get_mut_cabal_balance(object::owner(store), metadata);

        assert!(cabal_balance.balance >= amount, error::invalid_argument(EBALANCE_NOT_ENOUGH));
        cabal_balance.balance = cabal_balance.balance - amount;

        fungible_asset::withdraw_with_ref(transfer_ref, store, amount)
    }

    public fun get_snapshot_balance(addr: address, metadata: Object<Metadata>, block_height: u64): u64 acquires HolderStore {
        let metadata_addr = object::object_address(&metadata);
        assert!(exists<HolderStore>(metadata_addr), error::invalid_argument(EUNSUPPORT_TOKEN));
        let holder_store = borrow_global<HolderStore>(metadata_addr);
        if (!table::contains(&holder_store.holder_balance_map, addr)) {
            return 0;
        };
        let cabal_balance = table::borrow(&holder_store.holder_balance_map, addr);
        get_snapshot_balance_internal(cabal_balance, block_height)
    }

    public fun get_snapshot_supply(metadata: Object<Metadata>, block_height: u64): u128 acquires HolderStore {
        let metadata_addr = object::object_address(&metadata);
        assert!(exists<HolderStore>(metadata_addr), error::invalid_argument(EUNSUPPORT_TOKEN));
        let holder_store = borrow_global<HolderStore>(metadata_addr);
        *table::borrow_with_default(&holder_store.supply_snapshots, block_height, &0)
    }

    public fun metadata(creator_addr: address, symbol: String): Object<Metadata> {
        coin::metadata(creator_addr, symbol)
    }

    inline fun get_mut_cabal_balance(owner: address, metadata: Object<Metadata>): &mut CabalBalance acquires ModuleStore, HolderStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        let metadata_addr = object::object_address(&metadata);
        let holder_store = borrow_global_mut<HolderStore>(metadata_addr);

        if (!table::contains(&holder_store.holder_balance_map, owner)) {
            table::add(
                &mut holder_store.holder_balance_map,
                owner,
                CabalBalance{ balance: 0, start_block: block::get_current_block_height(), snapshot: table::new() }
            )
        };
        let cabal_balance = table::borrow_mut(&mut holder_store.holder_balance_map, owner);

        if (option::is_some(&m_store.snapshot_block)) {
            check_snapshot(cabal_balance, *option::borrow(&m_store.snapshot_block), m_store.prv_snapshot_block)
        };
        cabal_balance
    }

    fun check_snapshot(c_balance: &mut CabalBalance, current_snapshot_block: u64, prev_snapshot_block: Option<u64>) {
        // If there is concurrency, ignore the current snapshot height and use the previous snapshot height.
        let current_block_height = block::get_current_block_height();
        let snapshot_block = current_snapshot_block;
        if (current_block_height == current_snapshot_block) {
            if (option::is_none(&prev_snapshot_block)) {
                return
            };
            snapshot_block = option::extract(&mut prev_snapshot_block);
        };

        if (snapshot_block < c_balance.start_block) {
            return
        };

        let key = table_key::encode_u64(snapshot_block);
        if (current_block_height > snapshot_block && !table::contains(&c_balance.snapshot, key)) {
            table::add(&mut c_balance.snapshot, key, c_balance.balance);
        };
    }

    fun get_snapshot_balance_internal(cabal_balance: &CabalBalance, block_height: u64): u64 {
        if (cabal_balance.start_block > block_height) {
            return 0;
        };

        if (table::empty(&cabal_balance.snapshot)) {
            return cabal_balance.balance;
        };

        let key = table_key::encode_u64(block_height);

        let iter = table::iter(
            &cabal_balance.snapshot, 
            option::some(key), 
            option::none(), 
            2
        );

        if (!table::prepare<vector<u8>, u64>(iter)) {
            return cabal_balance.balance;
        };

        let (_, balance) = table::next(iter);
        *balance
    }

    public (friend) fun snapshot() acquires ModuleStore, HolderStore {
        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);
        let current_block_height = block::get_current_block_height();
        m_store.prv_snapshot_block = m_store.snapshot_block;
        m_store.snapshot_block = option::some(current_block_height);

        for (i in 0..vector::length(&m_store.token_metadatas)) {
            let metadata_addr = object::object_address(&m_store.token_metadatas[i]);
            let holder_store = borrow_global_mut<HolderStore>(metadata_addr);
            table::upsert(
                &mut holder_store.supply_snapshots,
                current_block_height,
                option::get_with_default(&coin::supply(m_store.token_metadatas[i]), 0));
        }
    }

    #[test_only]
    public fun init_module_for_test(staking_addr: &signer) {
        init_module(staking_addr)
    }

    #[test(c = @staking_addr)]
    fun test_snapshot(c: &signer) acquires ManagingRefs, HolderStore, ModuleStore {
        init_module_for_test(c);
        let (mint_cap, _burn_cap, _freeze_cap) = initialize(
                c, // account (object creator)
                c, // module_owner (@staking_addr)
                option::none(),
                string::utf8(b"init token"),
                string::utf8(b"uinit"),
                6,
                string::utf8(b""),
                string::utf8(b"")
            );

        let block_height = block::get_current_block_height();
        mint_to(&mint_cap, signer::address_of(c), 100000000000000);
        let balance = get_snapshot_balance(signer::address_of(c), mint_cap.metadata, block_height);
        assert!(balance==100000000000000, 1);
        utils::increase_block(1, 2);

        snapshot();
        let snapshot_height = block::get_current_block_height();
        utils::increase_block(1, 2);

        mint_to(&mint_cap, signer::address_of(c), 100000000000000);
        balance = get_snapshot_balance(signer::address_of(c), mint_cap.metadata, snapshot_height);
        assert!(balance==100000000000000, 2);

        mint_to(&mint_cap, @0x111, 100000000000000);
        balance = get_snapshot_balance(@0x111, mint_cap.metadata, snapshot_height);
        assert!(balance==0, 3);
    }

    #[test(c = @staking_addr, user1 = @0xAAA, user2 = @0xBBB)]
    fun test_snapshot_lazy_write_and_fallback(
        c: &signer,
        user1: &signer,
        user2: &signer,
    ) acquires ManagingRefs, HolderStore, ModuleStore {
        init_module_for_test(c); // Initialize cabal_token module store

        // Initialize a test token (e.g., mock sxINIT)
        let (mint_cap, burn_cap, _freeze_cap) = initialize(
                c, // account (object creator)
                c, // module_owner (@staking_addr)
                option::none(),
                string::utf8(b"Mock sxINIT"),
                string::utf8(b"msxINIT"),
                6,
                string::utf8(b""),
                string::utf8(b"")
            );
        let token_meta = mint_cap.metadata;

        // Mint initial balances
        mint_to(&mint_cap, signer::address_of(user1), 1000);
        mint_to(&mint_cap, signer::address_of(user2), 500);

        // --- Take Snapshot ---
        snapshot();
        let snapshot_height = block::get_current_block_height();
        utils::increase_block(1, 10); // Advance block time

        // --- User 1 interacts AFTER snapshot ---
        mint_to(&mint_cap, signer::address_of(user1), 200); // User1 balance becomes 1200

        // --- User 2 does NOT interact ---

        utils::increase_block(1, 10); // Advance block time further

        // --- Verify Snapshot Balances ---

        // User 1: Should have triggered lazy write, balance at snapshot was 1000
        let balance1_snapshot = get_snapshot_balance(signer::address_of(user1), token_meta, snapshot_height);
        assert!(balance1_snapshot == 1000, 1);

        // User 2: Should use fallback read, balance at snapshot was 500 (same as current)
        let balance2_snapshot = get_snapshot_balance(signer::address_of(user2), token_meta, snapshot_height);
        assert!(balance2_snapshot == 500, 2);

        // Verify current balances are different
        let balance1_current = primary_fungible_store::balance(signer::address_of(user1), token_meta);
        assert!(balance1_current == 1200, 3);
        let balance2_current = primary_fungible_store::balance(signer::address_of(user2), token_meta);
        assert!(balance2_current == 500, 4); // User 2 current balance unchanged
    }

}