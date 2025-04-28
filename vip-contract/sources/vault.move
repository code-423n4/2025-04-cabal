module vip::vault {
    use std::error;
    use std::string;

    use initia_std::coin;
    use initia_std::fungible_asset::{FungibleAsset, Metadata};
    use initia_std::object::{Self, ExtendRef, Object};
    use initia_std::primary_fungible_store;

    use vip::utils;

    friend vip::vesting;

    //
    // Errors
    //

    const EINVALID_AMOUNT: u64 = 1;
    const EINVALID_REWARD_PER_STAGE: u64 = 2;

    //
    // Resources
    //

    struct ModuleStore has key {
        extend_ref: ExtendRef,
        reward_per_stage: u64,
        vault_store_addr: address
    }

    //
    // Implementations
    //

    fun init_module(vip: &signer) {
        let constructor_ref = object::create_object(@0x0, false);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let vault_store_addr = object::address_from_constructor_ref(&constructor_ref);

        move_to(
            vip,
            ModuleStore {
                extend_ref,
                reward_per_stage: 0, // set zero for safety
                vault_store_addr
            }
        );
    }

    //
    // Friend Functions
    //

    public(friend) fun withdraw(amount: u64): FungibleAsset acquires ModuleStore {
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        assert!(
            module_store.reward_per_stage > 0,
            error::invalid_state(EINVALID_REWARD_PER_STAGE)
        );
        let vault_signer =
            object::generate_signer_for_extending(&module_store.extend_ref);
        primary_fungible_store::withdraw(&vault_signer, reward_metadata(), amount)
    }

    //
    // Entry Functions
    //

    public entry fun deposit(funder: &signer, amount: u64) acquires ModuleStore {
        let vault_store_addr = get_vault_store_address();
        assert!(
            amount > 0,
            error::invalid_argument(EINVALID_AMOUNT)
        );
        primary_fungible_store::transfer(
            funder,
            reward_metadata(),
            vault_store_addr,
            amount
        );
    }

    public entry fun update_reward_per_stage(
        chain: &signer, reward_per_stage: u64
    ) acquires ModuleStore {
        utils::check_chain_permission(chain);

        let vault_store = borrow_global_mut<ModuleStore>(@vip);
        assert!(
            reward_per_stage > 0,
            error::invalid_argument(EINVALID_REWARD_PER_STAGE)
        );
        vault_store.reward_per_stage = reward_per_stage;
    }

    public fun reward_per_stage(): u64 acquires ModuleStore {
        let vault_store = borrow_global<ModuleStore>(@vip);
        vault_store.reward_per_stage
    }

    public fun reward_metadata(): Object<Metadata> {
        coin::metadata(@initia_std, string::utf8(b"uinit"))
    }

    //
    // View Functions
    //
    #[view]
    public fun get_vault_store_address(): address acquires ModuleStore {
        borrow_global<ModuleStore>(@vip).vault_store_addr
    }

    //
    // Tests
    //
    #[test_only]
    public fun init_module_for_test(chain: &signer) {
        init_module(chain);
    }

    #[test_only]
    public fun balance(): u64 acquires ModuleStore {
        let vault_store_addr = get_vault_store_address();
        primary_fungible_store::balance(vault_store_addr, reward_metadata())
    }

    #[test_only]
    use initia_std::option;

    #[test_only]
    use initia_std::signer;

    #[test_only]
    use initia_std::fungible_asset;

    #[test_only]
    fun initialize_coin(
        account: &signer, symbol: string::String
    ): (coin::BurnCapability, coin::FreezeCapability, coin::MintCapability) {
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

        (burn_cap, freeze_cap, mint_cap)
    }

    #[test(chain = @0x1, vip = @vip, funder = @0x2)]
    fun e2e(chain: &signer, vip: &signer, funder: &signer) acquires ModuleStore {
        primary_fungible_store::init_module_for_test();
        init_module(vip);
        let (_, _, mint_cap) = initialize_coin(chain, string::utf8(b"uinit"));
        coin::mint_to(
            &mint_cap,
            signer::address_of(funder),
            1000000
        );

        // udpate reward_per_stage
        update_reward_per_stage(vip, 1000);
        assert!(reward_per_stage() == 1000, 1);

        // deposit 1000
        deposit(funder, 1000);
        assert!(balance() == 1000, 2);

        // withdraw 500
        let withdrawn_reward = withdraw(500);
        assert!(fungible_asset::amount(&withdrawn_reward) == 500, 3);
        assert!(balance() == 500, 4);

        // deposit to funder
        primary_fungible_store::deposit(signer::address_of(funder), withdrawn_reward);
    }
}
