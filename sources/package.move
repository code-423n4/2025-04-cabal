module staking_addr::package {

    use std::error;
    use std::signer;

    use initia_std::object;
    use initia_std::object::ExtendRef;

    friend staking_addr::pool_router;
    friend staking_addr::cabal;
    friend staking_addr::bribe;
    friend staking_addr::voting_reward;
    friend staking_addr::manager;

    const ERR_PACKAGE_UNAUTHORIZED: u64 = 0;
    const ERR_PACKAGE_INITIALIZED: u64 = 1;
    const ERR_PACKAGE_UNINITIALIZED: u64 = 2;
    const EMODULE_OPERATION: u64 = 3;

    struct ModuleStore has key {
        resource_account_extend_ref: ExtendRef,
        assets_store_extend_ref: ExtendRef,
        reward_store_extend_ref: ExtendRef,
        commission_fee_store_addr: address,
    }

    fun init_module(account: &signer) {
        assert!(signer::address_of(account) == @staking_addr, error::unauthenticated(EMODULE_OPERATION));

        let resource_account_constructor_ref = object::create_object(@staking_addr, false);
        let resource_account_extend_ref = object::generate_extend_ref(&resource_account_constructor_ref);
        let assets_constructor_ref = object::create_object(@staking_addr, false);
        let assets_store_extend_ref = object::generate_extend_ref(&assets_constructor_ref);
        let reward_constructor_ref = object::create_object(@staking_addr, false);
        let reward_store_extend_ref = object::generate_extend_ref(&reward_constructor_ref);

        move_to(account, ModuleStore {
            resource_account_extend_ref,
            assets_store_extend_ref,
            reward_store_extend_ref,
            commission_fee_store_addr: signer::address_of(account)
        });
    }

    public fun initialized(): bool {
        exists<ModuleStore>(@staking_addr)
    }

    public(friend) fun resource_account_signer(): signer acquires ModuleStore {
        assert!(initialized(), error::invalid_state(ERR_PACKAGE_UNINITIALIZED));

        let m_store = borrow_global<ModuleStore>(@staking_addr);
        object::generate_signer_for_extending(&m_store.resource_account_extend_ref)
    }

    public(friend) fun get_assets_store_signer(): signer acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        object::generate_signer_for_extending(&m_store.assets_store_extend_ref)
    }

    public(friend) fun get_reward_store_signer(): signer acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        object::generate_signer_for_extending(&m_store.reward_store_extend_ref)
    }

    #[view]
    public fun get_commission_fee_store_address(): address acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        m_store.commission_fee_store_addr
    }

    #[view]
    public fun resource_account_address(): address acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        object::address_from_extend_ref(&m_store.resource_account_extend_ref)
    }

    #[view]
    public fun get_assets_store_address(): address acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        object::address_from_extend_ref(&m_store.assets_store_extend_ref)
    }

    #[view]
    public fun get_reward_store_address(): address acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        object::address_from_extend_ref(&m_store.reward_store_extend_ref)
    }

    public entry fun set_commission_fee_store_addr(admin: &signer, commission_fee_store_addr: address) acquires ModuleStore {
        // Only the deployer address
        assert!(signer::address_of(admin) == @staking_addr, error::unauthenticated(EMODULE_OPERATION));
        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);
        m_store.commission_fee_store_addr = commission_fee_store_addr;
    }

    #[test_only]
    public fun init_module_for_test(staking_addr: &signer) {
        init_module(staking_addr)
    }
}