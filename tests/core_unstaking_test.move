#[test_only]
module staking_addr::core_unstaking_test {
    use std::option;
    use std::signer;
    use std::string;
    use std::vector;

    use initia_std::account;
    use initia_std::bigdecimal; // Needed for calculations within tested functions
    use initia_std::block;
    use initia_std::coin;
    use initia_std::debug;
    use initia_std::fungible_asset::{Self, Metadata};
    use initia_std::object::{Self, Object};
    use initia_std::primary_fungible_store;

    // Import necessary modules from the staking_addr package
    use staking_addr::bribe; // Needed by test_setup
    use staking_addr::cabal;
    use staking_addr::cabal_token;
    use staking_addr::emergency; // Needed by test_setup
    use staking_addr::manager; // Needed by test_setup
    use staking_addr::package;
    use staking_addr::pool_router;
    use staking_addr::utils; // For test helpers if needed elsewhere

    // Import external dependencies needed by setup/tested functions
    use vip::lock_staking;
    use vip::weight_vote; // Needed by cabal functions called in tests

    const MINIMUM_LIQUIDITY: u64 = 100_000_000; // 100.00 INIT (Adjust if changed in cabal.move)

    // Initializes all necessary modules for Cabal core functionality tests
    fun test_setup(c: &signer, init_validator_address: string::String) { // Removed acquires ModuleStore, Added acquires StakePool
        // Initialize dependent modules first
        emergency::init_module_for_test(c);
        manager::initialize_for_test(signer::address_of(c)); // Also initializes package.move
        bribe::init_module_for_test(c); 
        cabal_token::init_module_for_test(c); 
        pool_router::init_module_for_test(c); 
        // voting_reward::init_module_for_test(c); // Initialize voting_reward module - Not strictly needed for core tests?
        utils::increase_block(1, 2); // Advance time slightly using helper from cabal

        // Initialize VIP mock/dependency if needed by pool_router/cabal
        let vip_signer = &account::create_signer_for_test(@vip);
        lock_staking::init_module_for_test(vip_signer);

        utils::increase_block(1, 2); // Advance time slightly using helper from cabal

        // Initialize primary fungible store and mint initial INIT
        let initia_signer = &account::create_signer_for_test(@initia_std);
        let initia_addr = @initia_std;
        primary_fungible_store::init_module_for_test();

        let (mint_cap, _, _) = coin::initialize(
            initia_signer,
            option::none(),
            string::utf8(b"init token"),
            string::utf8(b"uinit"),
            6, // decimals
            string::utf8(b""),
            string::utf8(b"")
        );
        // Mint plenty of INIT to the deployer/test account 'c'
        coin::mint_to(&mint_cap, signer::address_of(c), 1_000_000_000_000_000); // 1 million INIT

        // Initialize the main cabal module
        // Also initializes emergency.move
        cabal::initialize(c, init_validator_address, signer::address_of(c)); // Use 'c' as commission addr for simplicity

        // *** Fix 1 & 2: Manually trigger delegate and stake for initial liquidity ***
        let init_metadata_setup = coin::metadata(@initia_std, string::utf8(b"uinit"));
        let pools_setup = pool_router::get_pool_address_for_stake_token(init_metadata_setup);
        assert!(vector::length(&pools_setup) == 1, 998);
        let init_pool_obj_addr_setup = pools_setup[0];
        let init_pool_obj_setup = object::address_to_object<pool_router::StakePool>(init_pool_obj_addr_setup);

        // Manually trigger delegate for the initial minimum liquidity deposit
        //pool_router::mock_delegate_init(borrow_global<pool_router::StakePool>(init_pool_obj_addr_setup), MINIMUM_LIQUIDITY);
        // TODO: we call this one for sure

        utils::increase_block(1, 1); // Advance block after setup delegation

        // setup lp pool
        let (mint_cap, _, _) = coin::initialize(
            initia_signer,
            option::none(),
            string::utf8(b"lp token"),
            string::utf8(b"ulp"),
            6, // decimals
            string::utf8(b""),
            string::utf8(b"")
        );
        // Mint plenty of ulp to the deployer/test account 'c' and user1 user2
        coin::mint_to(&mint_cap, signer::address_of(initia_signer), 1_000_000_000_000_000); // 1 million ulp
        coin::mint_to(&mint_cap, @0x111, 1_000_000_000); // 1k ulp
        coin::mint_to(&mint_cap, @0x222, 1_000_000_000); // 1k ulp

        let lp_metadata_setup = coin::metadata(@initia_std, string::utf8(b"ulp"));
        cabal::config_stake_token(
            c,
            60*60*24*21,
            lp_metadata_setup,
            lp_metadata_setup,
            string::utf8(b"cabal stake ulp coin"),
            string::utf8(b"cabalULP"),
            string::utf8(b""),
            string::utf8(b"")
        );
        pool_router::add_pool(c, lp_metadata_setup, string::utf8(b"ulpvaloper1test"));

        utils::increase_block(1, 2);

        // User 1 stakes some ulp
        let stake_amount_1 = 100_000_000; // 100 ulp worth
        cabal::mock_stake(&account::create_signer_for_test(@0x111), 1, stake_amount_1); // mock_stake handles the process_lp_stake call

        // User 2 stakes the same amount of ulp
        let stake_amount_2 = 100_000_000;
        cabal::mock_stake(&account::create_signer_for_test(@0x222), 1, stake_amount_2); // mock_stake handles the process_lp_stake call

        utils::increase_block(1, 2);
    }

    // // --- Tests for LPT/Cabal LPT ---


    #[test(c = @staking_addr, chain = @initia_std, user_1 = @0x111, user_2 = @0x222)]
    fun test_unstake_lp(
        c: &signer,
        chain: &signer,
        user_1: &signer,
        user_2: &signer
    ) {
        test_setup(c, string::utf8(b"initvaloper1test"));
        let lp_metadata = coin::metadata(@initia_std, string::utf8(b"ulp"));
        let cabal_lp_metadata = cabal::get_cabal_token_metadata(1);

        // Get the lp pool object once
        let pools = pool_router::get_pool_address_for_stake_token(lp_metadata);
        assert!(vector::length(&pools) == 1, 999); // Assuming only one pool for lp

        let stake_amount_1 = 100_000_000;
        let stake_amount_2 = 100_000_000;

        // --- Verify User 1 cabal ulp ---
        // Check User 1's balance directly
        let user_1_cabalulp_balance = primary_fungible_store::balance(signer::address_of(user_1), cabal_lp_metadata);
        assert!(user_1_cabalulp_balance > 0, 301); // Basic check
        assert!(user_1_cabalulp_balance == stake_amount_1 , 302);

        // --- Verify User 2 cabal ulp ---
        let user_2_cabalulp_balance = primary_fungible_store::balance(signer::address_of(user_2), cabal_lp_metadata);
        assert!(user_2_cabalulp_balance > 0, 303);
        assert!(user_2_cabalulp_balance == stake_amount_2, 304);

        let ulp_in_pool_init = cabal::get_lp_pool_staked_amount(1);
        assert!(ulp_in_pool_init == stake_amount_1+stake_amount_2, 305);


        // User 1 unstake with no reward
        let unstake_amount_1 = 10_000_000;
        cabal::mock_unstake(user_1, 1, unstake_amount_1);

        // --- Verify User 1 cabal ulp ---
        // Check User 1's balance directly
        let user_1_cabalulp_after_unstake_balance = primary_fungible_store::balance(signer::address_of(user_1), cabal_lp_metadata);
        assert!(user_1_cabalulp_after_unstake_balance == user_1_cabalulp_balance-unstake_amount_1 , 306);

        let user1_unbonding_list = cabal::get_unbonding_list(signer::address_of(user_1));
        assert!(vector::length(&user1_unbonding_list) == 1, 307);
        let (user1_unstake_meta, user1_unstake_amount, _ ) = cabal::unpack_unbonding_entry_response(vector::remove(&mut user1_unbonding_list, 0));
        assert!(user1_unstake_meta == lp_metadata, 308);
        assert!(user1_unstake_amount == unstake_amount_1, 309);
        let unstaked_pending_amount = cabal::get_lp_pool_unstaked_pending_amount(1);
        assert!(unstaked_pending_amount == unstake_amount_1, 310);

    }

}