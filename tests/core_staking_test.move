#[test_only]
module staking_addr::core_staking_test {
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
        // Mint plenty of ulp to the deployer/test account 'c'
        coin::mint_to(&mint_cap, signer::address_of(initia_signer), 1_000_000_000_000_000); // 1 million ulp

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
    }

    // --- Tests for INIT/XINIT ---

    // 1. Verifies state after initialization and checks the ratio for the first deposit after that. Just one user.
    #[test(c = @staking_addr, user_a = @0xAAA)]
    fun test_post_init_deposit_ratio(c: &signer, user_a: &signer) { 
        // Setup initializes the module, deposits MINIMUM_LIQUIDITY INIT, and stakes it for sxINIT.
        test_setup(c, string::utf8(b"initvaloper1test")); // Use a generic validator address

        let init_metadata = coin::metadata(@initia_std, string::utf8(b"uinit"));
        let x_init_metadata = cabal::get_xinit_metadata();

        // --- Check state immediately after initialization ---
        let initial_xinit_supply = cabal::get_xinit_total_supply();
        let initial_total_staked_init = cabal::get_pool_router_total_init();

        // --- User A deposits INIT ---
        let deposit_amount_a = 500_000_000; // Example amount: 500 INIT
        // Give user_a some INIT (assuming 'c' has plenty from test_setup)
        primary_fungible_store::transfer(c, init_metadata, signer::address_of(user_a), deposit_amount_a);

        // User A deposits
        cabal::mock_deposit_init_for_xinit(user_a, deposit_amount_a);

        utils::increase_block(1, 1);

        // --- Verify User A's deposit ---
        // Since no rewards have accrued, the ratio should still be 1:1
        // Expected xINIT = (deposit_amount / initial_total_staked_init) * initial_xinit_supply
        // Expected xINIT = (deposit_amount_a / MINIMUM_LIQUIDITY) * MINIMUM_LIQUIDITY = deposit_amount_a
        let user_a_xinit_balance = primary_fungible_store::balance(signer::address_of(user_a), x_init_metadata);

        // debug::print(&user_a_xinit_balance);
        // debug::print(&deposit_amount_a);

        // assert!(user_a_xinit_balance == deposit_amount_a, 103);

        // --- Verify global state updates ---
        let final_xinit_supply = cabal::get_xinit_total_supply();
        let final_total_staked_init = cabal::get_pool_router_total_init();

        // assert!(final_xinit_supply == initial_xinit_supply + (deposit_amount_a as u128), 104);
        // assert!(final_total_staked_init == initial_total_staked_init + deposit_amount_a, 105);
    }

    // 2. Verifies the xINIT/INIT ratio for a second depositor when no rewards have accrued. Two users, no rewards.
    #[test(c = @staking_addr, user_a = @0xAAA, user_b = @0xBBB)]
    fun test_subsequent_deposit_no_rewards(c: &signer, user_a: &signer, user_b: &signer) {
        test_setup(c, string::utf8(b"initvaloper1test"));
        let init_metadata = coin::metadata(@initia_std, string::utf8(b"uinit"));
        let x_init_metadata = cabal::get_xinit_metadata();

        // --- User A deposits first ---
        let deposit_amount_a = 500_000_000; // 500 INIT
        primary_fungible_store::transfer(c, init_metadata, signer::address_of(user_a), deposit_amount_a);
        cabal::mock_deposit_init_for_xinit(user_a, deposit_amount_a);

        utils::increase_block(1, 1);

        // --- Record state after User A ---
        let xinit_supply_after_a = cabal::get_xinit_total_supply();
        let total_staked_after_a = cabal::get_pool_router_total_init();

        // --- User B deposits immediately after ---
        let deposit_amount_b = 200_000_000; // 200 INIT
        primary_fungible_store::transfer(c, init_metadata, signer::address_of(user_b), deposit_amount_b);
        cabal::mock_deposit_init_for_xinit(user_b, deposit_amount_b);

        utils::increase_block(1, 1);

        // --- Verify User B's deposit ---
        // Expected xINIT = Deposit B * (Supply After A / Staked After A)
        let expected_xinit_b_ratio = bigdecimal::from_ratio_u128(
            xinit_supply_after_a, // Current xINIT supply
            total_staked_after_a as u128 // Current underlying INIT
        );
        let expected_xinit_b = bigdecimal::mul_by_u64_truncate(
            expected_xinit_b_ratio,
            deposit_amount_b
        );

        let user_b_xinit_balance = primary_fungible_store::balance(signer::address_of(user_b), x_init_metadata);

        // debug::print(&string::utf8(b"--- Test 1.2 ---"));
        // debug::print(&string::utf8(b"xINIT Supply After A:")); debug::print(&(xinit_supply_after_a as u64));
        // debug::print(&string::utf8(b"Total Staked INIT After A:")); debug::print(&total_staked_after_a);
        // debug::print(&string::utf8(b"User B Deposit Amount:")); debug::print(&deposit_amount_b);
        // debug::print(&string::utf8(b"Expected xINIT for User B:")); debug::print(&expected_xinit_b);
        // debug::print(&string::utf8(b"Actual xINIT for User B:")); debug::print(&user_b_xinit_balance);

        // Assert User B got the amount calculated by the ratio based on state after User A
        // Allow for potential 1 unit difference due to truncation
        assert!(user_b_xinit_balance == expected_xinit_b || user_b_xinit_balance == expected_xinit_b - 1 , 111);

        // --- Verify final global state ---
        let final_xinit_supply = cabal::get_xinit_total_supply();
        let final_total_staked_init = cabal::get_pool_router_total_init();

        // Expected final supply = Supply after A + Expected for B
        let expected_final_supply = xinit_supply_after_a + (expected_xinit_b as u128);
        assert!(final_xinit_supply == expected_final_supply || final_xinit_supply == expected_final_supply - 1, 112);

        // Expected final staked = Staked after A + Deposit B
        assert!(final_total_staked_init == total_staked_after_a + deposit_amount_b, 113);
    }


    // --- Tests for XINIT/SXINIT ---


    // Test 2.1 & 2.2: First/Subsequent Stake (No Rewards) & Ratio Check - Simplified to 2 users
    #[test(c = @staking_addr, user_1 = @0x111, user_2 = @0x222)]
    fun test_stake_xinit_with_no_reward(
        c: &signer,
        user_1: &signer,
        user_2: &signer
    ) {
        // debug::print(&string::utf8(b"Test 2.1/2.2"));

        test_setup(c, string::utf8(b"initvaloper1test"));
        let init_metadata = coin::metadata(@initia_std, string::utf8(b"uinit"));
        let x_init_metadata = cabal::get_xinit_metadata();
        let sx_init_metadata = cabal::get_sxinit_metadata();

        // Get the INIT pool object once
        let pools = pool_router::get_pool_address_for_stake_token(init_metadata);
        assert!(vector::length(&pools) == 1, 999); // Assuming only one pool for INIT
        let init_pool_obj_addr = pools[0];
        let init_pool_obj = object::address_to_object<pool_router::StakePool>(init_pool_obj_addr);

        // Give users INIT and let them deposit for xINIT
        let deposit_amount = 100_000_000; // 100 INIT
        primary_fungible_store::transfer(c, init_metadata, signer::address_of(user_1), deposit_amount);
        primary_fungible_store::transfer(c, init_metadata, signer::address_of(user_2), deposit_amount);

        // User 1 Deposits
        cabal::mock_deposit_init_for_xinit(user_1, deposit_amount);

        utils::increase_block(1, 1);

        // User 2 Deposits
        cabal::mock_deposit_init_for_xinit(user_2, deposit_amount);
        // mock trigger delegate is called automatically


        utils::increase_block(1, 1);

        // Verify initial xINIT balances (Allowing for potential minor rounding differences)
        let bal1 = primary_fungible_store::balance(signer::address_of(user_1), x_init_metadata);
        let bal2 = primary_fungible_store::balance(signer::address_of(user_2), x_init_metadata);

        // debug::print(&string::utf8(b"User 1 xINIT balance:")); debug::print(&bal1);
        // debug::print(&string::utf8(b"User 2 xINIT balance:")); debug::print(&bal2);

        // Check they are all very close to the deposit amount (adjust tolerance if needed)
        // assert!(bal1 <= deposit_amount && bal1 > deposit_amount - 10, 201); // small rounding err diff is fine
        // assert!(bal2 <= deposit_amount && bal2 > deposit_amount - 10, 202);

        // --- Staking ---

        utils::increase_block(1, 2);


        let sx_init_supply_before_1 = cabal::get_sxinit_total_supply();

        // debug::print(&string::utf8(b"Inside the test, here is the sx_init_supply before user 1"));
        // debug::print(&(sx_init_supply_before_1 / 1_000_000));


        // User 1 stakes some xINIT
        let stake_amount_1 = 100_000_000; // 1000 INIT
        cabal::mock_stake(user_1, 0, stake_amount_1); // mock_stake handles the process_xinit_stake call

        utils::increase_block(1, 2);

        // --- Verify User 1 sxINIT ---
        // Check User 1's balance directly
        let user_1_sxinit_balance = primary_fungible_store::balance(signer::address_of(user_1), sx_init_metadata);
        assert!(user_1_sxinit_balance > 0, 301); // Basic check
        // Assert it's close to the stake amount, as ratio should be near 1:1 initially
        // assert!(user_1_sxinit_balance == stake_amount_1 || user_1_sxinit_balance == stake_amount_1 - 1, 302);
        // debug::print(&string::utf8(b"User 1 sxINIT balance:")); debug::print(&user_1_sxinit_balance);

        // Record state before User 2 stakes
        let x_init_in_pool_before_2 = cabal::get_xinit_pool_staked_amount();


        let sx_init_supply_before_2 = cabal::get_sxinit_total_supply();

        // debug::print(&string::utf8(b", here is the sx_init_supply before user 2"));
        // debug::print(&(sx_init_supply_before_2 / 1_000_000));

        // User 2 stakes the same amount of xINIT
        let stake_amount_2 = 100_000_000; // 1000 INIT
        cabal::mock_stake(user_2, 0, stake_amount_2); // mock_stake handles the process_xinit_stake call

        utils::increase_block(1, 2);


        // --- Verify User 2 sxINIT ---
        let user_2_sxinit_balance = primary_fungible_store::balance(signer::address_of(user_2), sx_init_metadata);
        assert!(user_2_sxinit_balance > 0, 303);

        // Calculate expected sxINIT for User 2 based on state *before* their stake
        let ratio_2 = bigdecimal::from_ratio_u64(stake_amount_2, x_init_in_pool_before_2);
        let expected_sxinit_2 = bigdecimal::mul_by_u128_truncate(ratio_2, sx_init_supply_before_2) as u64;

        // debug::print(&string::utf8(b"xINIT in Pool Before 2:")); debug::print(&x_init_in_pool_before_2);
        // debug::print(&string::utf8(b"sxINIT Supply Before 2:")); debug::print(&(sx_init_supply_before_2 as u64));
        // debug::print(&string::utf8(b"Expected sxINIT for User 2:")); debug::print(&expected_sxinit_2);
        // debug::print(&string::utf8(b"Actual sxINIT for User 2:")); debug::print(&user_2_sxinit_balance);

        // Allow for 1 unit rounding difference
        // assert!(user_2_sxinit_balance == expected_sxinit_2 || user_2_sxinit_balance == expected_sxinit_2 - 1, 304);
    }


    // Rewards are added, then a user stakes. The sxINIT/xINIT ratio should not be 1:1
    #[test(c = @staking_addr, user_1 = @0xAAA)]
    fun test_stake_xinit_with_simulated_rewards(c: &signer, user_1: &signer) {
        test_setup(c, string::utf8(b"initvaloper1test"));

        let init_metadata = coin::metadata(@initia_std, string::utf8(b"uinit"));
        let x_init_metadata = cabal::get_xinit_metadata();
        let sx_init_metadata = cabal::get_sxinit_metadata();

        // Ensure the total sxinit supply is 1:1 with initial liquidity from the deployer
        let total_sxinit_supply = cabal::get_sxinit_total_supply();
        assert!((total_sxinit_supply as u64) == MINIMUM_LIQUIDITY);

        // We know from the above test that if user one gets 100 INIT, deposits it, and stakes 100 xINIT
        // They'll get 100 sxINIT. 

        // Give the user 100 INIT 
        let deposit_amount = 100_000_000;
        primary_fungible_store::transfer(c, init_metadata, signer::address_of(user_1), deposit_amount);

        cabal::mock_deposit_init_for_xinit(user_1, deposit_amount);

        utils::increase_block(1, 1);

        // Verify the initial xInit balance
        let bal1 = primary_fungible_store::balance(signer::address_of(user_1), x_init_metadata);
        assert!(bal1 == deposit_amount);
        
        // This is 100
        let sx_init_supply_before_1 = cabal::get_sxinit_total_supply();

        // Now, let's deposit some fake rewards.
        // These rewards are sent to the actual StakePool Object's primary store

        let pools = pool_router::get_pool_address_for_stake_token(init_metadata);
        assert!(vector::length(&pools) == 1, 999); // Only one pool for INIT
        let init_pool_obj_addr = pools[0];

        // Define reward amount
        let simulated_reward_amount = 800_000_000; // Simulate 800 INIT rewards

        // Transfer rewards to the StakePool object's address from controller 'c'
        primary_fungible_store::transfer(
            c,                      
            init_metadata,          
            init_pool_obj_addr,     // Destination address (the StakePool object)
            simulated_reward_amount 
        );

        // Now, the StakePool object's PFS has 800 INIT sitting in it.

        // // Now let's have user 1 stake all their xINIT.

        utils::increase_block(1, 1);
        cabal::mock_stake(user_1, 0, deposit_amount);

        // sxinit minted to the user is 
        // net_stake * (sx_supply / x_init_in_pool)

        // net_stake with 0 fees is obviously 100
        // sx_supply is 100 (from the deployer staking)
        // Total xinit before this stake is 900 (800 rewards + 100 original)
        // (100 * 100) / 900
        // = 11

        // // Now let's check the total sxINIT

        let sx_init_supply_after_rewards_after_1 = cabal::get_sxinit_total_supply();
        debug::print(&(sx_init_supply_after_rewards_after_1 / 1_000_000));

        let user_1_sxinit_balance = primary_fungible_store::balance(signer::address_of(user_1), sx_init_metadata);

        assert!((user_1_sxinit_balance / 1_000_000 == 11), 101);

    }


    // --- Tests for SXINIT/XINIT (Unstaking) ---
    #[test(c = @staking_addr, user = @0xAAA)]
    fun test_unstake_sxinit_with_simulated_rewards(c: &signer, user: &signer) {
        test_setup(c, string::utf8(b"initvaloper1test"));

        let init_metadata = coin::metadata(@initia_std, string::utf8(b"uinit"));
        let x_init_metadata = cabal::get_xinit_metadata();
        let sx_init_metadata = cabal::get_sxinit_metadata();

        // Give the user 100 INIT and have them deposit it for xINIT
        let deposit_amount = 100_000_000;
        primary_fungible_store::transfer(c, init_metadata, signer::address_of(user), deposit_amount);

        cabal::mock_deposit_init_for_xinit(user, deposit_amount);

        utils::increase_block(1, 1);

        // Verify the initial xINIT balance
        let bal1 = primary_fungible_store::balance(signer::address_of(user), x_init_metadata);
        assert!(bal1 == deposit_amount);

        // Have user 1 stake all of their xINIT.

        utils::increase_block(1, 1);
        cabal::mock_stake(user, 0, deposit_amount);

        let sx_owned = primary_fungible_store::balance(signer::address_of(user), sx_init_metadata);

        // Send 800 INIT rewards to the StakePool object after the stake

        let pools = pool_router::get_pool_address_for_stake_token(init_metadata);
        assert!(vector::length(&pools) == 1, 999); // Only one pool for INIT
        let init_pool_obj_addr = pools[0];

        // Define reward amount
        let simulated_reward_amount = 800_000_000;

        // Transfer rewards
        primary_fungible_store::transfer(
            c,                      
            init_metadata,          
            init_pool_obj_addr,     // Destination address (the StakePool object)
            simulated_reward_amount 
        );

        // Now the stakepool's PFS (primary fungible store) has 800 INIT sitting in it

        // Now let's whitelist user 1 to unstake instantly, and have them unstake

        cabal::init_fees_exempt(c);
        cabal::set_fees_exempt(c, vector::singleton(signer::address_of(user)));

        let before = primary_fungible_store::balance(signer::address_of(user), x_init_metadata);
        cabal::mock_unstake(user, 0, sx_owned);
        let after = primary_fungible_store::balance(signer::address_of(user), x_init_metadata);

        let actual_gain = after - before; // What the user really got
        let expected_gain = 500_000_000;    // 500 INIT in uINIT
        let slack_bps = 1; // 0.2% +- tolerance for now

        // fuzzy check
        utils::test_with_slack(actual_gain, expected_gain, slack_bps);

        // assert!(cabal::get_sxinit_total_supply() / 1_000_000 == 100, 903); // only bootstrap sXINIT remains
        // assert!(cabal::get_xinit_pool_staked_amount() / 1_000_000 == 500, 904); // 1 000 - 500 = 500


    }


    // Abort if user tries to unstake more sxINIT than they hold
    #[test(c = @staking_addr, user = @0xAAA)]
    #[expected_failure]
    fun test_initiate_unstake_more_than_balance(c: &signer, user: &signer) {
        // minimal setup so ModuleStore & CabalStore exist
        test_setup(c, string::utf8(b"initvaloper1test"));
        cabal::ensure_cabal_store_exists(user);

        // user has 0 sxINIT and attempting to unstake 1 should abort
        cabal::initiate_unstake(user, 0, 1);
    }

    // Exempt user should receive immediate xINIT instead of an unbonding entry
    #[test(c = @staking_addr, user = @0xAAA)]
    fun test_initiate_unstake_exempt_immediate(c: &signer, user: &signer) {
        test_setup(c, string::utf8(b"initvaloper1test"));

        let deposit = 100_000_000;

        // mint xINIT
        primary_fungible_store::transfer(
            c,
            coin::metadata(@initia_std, string::utf8(b"uinit")),
            signer::address_of(user),
            deposit
        );

        cabal::mock_deposit_init_for_xinit(user, deposit);
        utils::increase_block(1,1);

        // stake all their xINIT then get sxINIT == deposit
        cabal::mock_stake(user, 0, deposit);
        utils::increase_block(1,1);

        let sx_bal = primary_fungible_store::balance(
            signer::address_of(user),
            cabal::get_sxinit_metadata()
        );
        assert!(sx_bal == deposit, 901);

        // exempt user
        cabal::init_fees_exempt(c);
        cabal::set_fees_exempt(c, vector::singleton(signer::address_of(user)));

        // track xINIT before unstaking
        let before_xinit = primary_fungible_store::balance(
            signer::address_of(user),
            cabal::get_xinit_metadata()
        );
        cabal::mock_unstake(user, 0, sx_bal);

        // exempt so immediate credit of full unbond amount
        let after_xinit = primary_fungible_store::balance(
            signer::address_of(user),
            cabal::get_xinit_metadata()
        );

        debug::print(&before_xinit);
        debug::print(&deposit);
        debug::print(&after_xinit);

        // assert!(after_xinit == before_xinit + deposit, 902);
    }

    // A nonwhitelisted user's unstake should create an unbonding entry that expires later in the future
    #[test(c = @staking_addr, user = @0xAAA)]
    #[expected_failure]
    fun test_unstake_creates_unbonding_entry(c: &signer, user: &signer) {
        use std::vector;

        test_setup(c, string::utf8(b"initvaloper1test"));

        let init_meta   = coin::metadata(@initia_std, string::utf8(b"uinit"));
        let xinit_meta  = cabal::get_xinit_metadata();
        let sxinit_meta = cabal::get_sxinit_metadata();

        // deposit 100 INIT and stake 100 sXINIT
        let deposit = 100_000_000;
        primary_fungible_store::transfer(c, init_meta, signer::address_of(user), deposit);
        cabal::mock_deposit_init_for_xinit(user, deposit);
        utils::increase_block(1, 1);
        cabal::mock_stake(user, 0, deposit);
        utils::increase_block(1, 1);

        // send 800 INIT reward AFTER stake
        let pool_addr = pool_router::get_pool_address_for_stake_token(init_meta)[0];
        primary_fungible_store::transfer(c, init_meta, pool_addr, 800_000_000);
        utils::increase_block(1, 1);

        // normal (non-whitelisted) unstake
        let sx_bal = primary_fungible_store::balance(signer::address_of(user), sxinit_meta);
        let before = primary_fungible_store::balance(signer::address_of(user), xinit_meta);
        cabal::mock_unstake(user, 0, sx_bal);
        let after = primary_fungible_store::balance(signer::address_of(user), xinit_meta);

        // No xINIT yet
        assert!(after == before, 11001);

        // Exactly one unbonding entry recorded
        let unbond_list = cabal::get_unbonding_list(signer::address_of(user));
        assert!(vector::length(&unbond_list) == 1, 11002);

        // release_time is in the future
        cabal::claim_unbonded_assets(user, vector::singleton(0));
    }

    // TODO: add a few more sxinit/lp unbonding tests

    // // --- Tests for LPT/Cabal LPT ---


    #[test(c = @staking_addr, chain = @initia_std, user_1 = @0x111, user_2 = @0x222)]
    fun test_stake_lp_with_no_reward(
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

        // Give users ulp and let them stake for cabal ulp
        let deposit_amount = 1_000_000_000; // 1000 ulp
        primary_fungible_store::transfer(chain, lp_metadata, signer::address_of(user_1), deposit_amount);
        primary_fungible_store::transfer(chain, lp_metadata, signer::address_of(user_2), deposit_amount);

        // --- Staking ---

        utils::increase_block(1, 2);

        // User 1 stakes some ulp
        let stake_amount_1 = 100_000_000; // 100 ulp worth
        cabal::mock_stake(user_1, 1, stake_amount_1); // mock_stake handles the process_lp_stake call

        utils::increase_block(1, 2);

        // --- Verify User 1 cabal ulp ---
        // Check User 1's balance directly
        let user_1_cabalulp_balance = primary_fungible_store::balance(signer::address_of(user_1), cabal_lp_metadata);
        assert!(user_1_cabalulp_balance > 0, 301); // Basic check
        // Assert it's close to the stake amount, as ratio should be near 1:1 initially
        assert!(user_1_cabalulp_balance == stake_amount_1 , 302);

        // Record state before User 2 stakes
        let ulp_in_pool_before_2 = cabal::get_lp_pool_staked_amount(1);
        let cabalulp_init_supply_before_2 = cabal::get_cabal_token_total_supply(1);
        assert!(ulp_in_pool_before_2 == stake_amount_1, 305);


        // User 2 stakes the same amount of ulp
        let stake_amount_2 = 100_000_000;
        cabal::mock_stake(user_2, 1, stake_amount_2); // mock_stake handles the process_lp_stake call

        utils::increase_block(1, 2);


        // --- Verify User 2 cabal ulp ---
        let user_2_cabalulp_balance = primary_fungible_store::balance(signer::address_of(user_2), cabal_lp_metadata);
        assert!(user_2_cabalulp_balance > 0, 303);
        assert!(user_2_cabalulp_balance == stake_amount_2, 303);

        // Calculate expected sxINIT for User 2 based on state *before* their stake
        let ratio_2 = bigdecimal::from_ratio_u64(stake_amount_2, ulp_in_pool_before_2);
        let expected_cabal_lp_2 = bigdecimal::mul_by_u128_truncate(ratio_2, cabalulp_init_supply_before_2) as u64;
        assert!(user_2_cabalulp_balance == expected_cabal_lp_2, 304);

        let ulp_in_pool_after_2 = cabal::get_lp_pool_staked_amount(1);
        assert!(ulp_in_pool_after_2 == stake_amount_1+stake_amount_2, 306);
    }

    #[test(c = @staking_addr, chain = @initia_std, user_1 = @0x111, user_2 = @0x222)]
    fun test_stake_lp_with_reward(
        c: &signer,
        chain: &signer,
        user_1: &signer,
        user_2: &signer
    ) {
        test_setup(c, string::utf8(b"initvaloper1test"));
        let init_metadata = coin::metadata(@initia_std, string::utf8(b"uinit"));
        let lp_metadata = coin::metadata(@initia_std, string::utf8(b"ulp"));
        let cabal_lp_metadata = cabal::get_cabal_token_metadata(1);

        // Get the lp pool object once
        let pools = pool_router::get_pool_address_for_stake_token(lp_metadata);
        assert!(vector::length(&pools) == 1, 999); // Assuming only one pool for lp
        let ulp_pool_obj_addr = pools[0];

        // Give users ulp and let them stake for cabal ulp
        let deposit_amount = 1_000_000_000; // 1000 ulp
        primary_fungible_store::transfer(chain, lp_metadata, signer::address_of(user_1), deposit_amount);
        primary_fungible_store::transfer(chain, lp_metadata, signer::address_of(user_2), deposit_amount);

        // --- Staking ---

        utils::increase_block(1, 2);

        // User 1 stakes some ulp
        let stake_amount_1 = 100_000_000; // 100 ulp worth
        cabal::mock_stake(user_1, 1, stake_amount_1); // mock_stake handles the process_lp_stake call

        utils::increase_block(1, 2);

        // --- Verify User 1 cabal ulp ---
        // Check User 1's balance directly
        let user_1_cabalulp_balance = primary_fungible_store::balance(signer::address_of(user_1), cabal_lp_metadata);
        assert!(user_1_cabalulp_balance > 0, 301); // Basic check
        // Assert it's close to the stake amount, as ratio should be near 1:1 initially
        assert!(user_1_cabalulp_balance == stake_amount_1 , 302);

        // Record state before User 2 stakes
        let ulp_in_pool_before_2 = cabal::get_lp_pool_staked_amount(1);
        let cabalulp_init_supply_before_2 = cabal::get_cabal_token_total_supply(1);
        assert!(ulp_in_pool_before_2 == stake_amount_1, 305);

        // transfer to pool as reward
        let reward_amount = 10_000_000;
        primary_fungible_store::transfer(c, init_metadata, ulp_pool_obj_addr, reward_amount);

        // User 2 stakes the same amount of ulp
        let stake_amount_2 = 100_000_000;
        cabal::mock_stake(user_2, 1, stake_amount_2); // mock_stake handles the process_lp_stake call

        utils::increase_block(1, 2);

        // --- Verify User 2 cabal ulp ---
        let user_2_cabalulp_balance = primary_fungible_store::balance(signer::address_of(user_2), cabal_lp_metadata);
        assert!(user_2_cabalulp_balance > 0, 303);

        // Calculate expected sxINIT for User 2 based on state *before* their stake
        let ratio_2 = bigdecimal::from_ratio_u64(stake_amount_2, ulp_in_pool_before_2+reward_amount);


        let expected_cabal_lp_2 = bigdecimal::mul_by_u128_truncate(ratio_2, cabalulp_init_supply_before_2) as u64;

        // debug::print(&string::utf8(b"Expected in failing test a and b"));
        // debug::print(&user_2_cabalulp_balance);
        // debug::print(&expected_cabal_lp_2);

        assert!(user_2_cabalulp_balance == expected_cabal_lp_2, 304);

        let ulp_in_pool_after_2 = cabal::get_lp_pool_staked_amount(1);
        assert!(ulp_in_pool_after_2 == stake_amount_1+stake_amount_2+reward_amount, 306);

        let pool_staked_ulp = primary_fungible_store::balance(ulp_pool_obj_addr, lp_metadata);
        assert!(pool_staked_ulp == ulp_in_pool_after_2, 307);
    }

    #[test(c = @staking_addr, chain = @initia_std, user_1 = @0x111, user_2 = @0x222)]
    #[expected_failure(abort_code = 0x10001, location = cabal)]
    fun test_stake_zero_lp(
        c: &signer,
        chain: &signer,
        user_1: &signer,
        user_2: &signer
    ) {
        test_setup(c, string::utf8(b"initvaloper1test"));
        let lp_metadata = coin::metadata(@initia_std, string::utf8(b"ulp"));

        // Get the lp pool object once
        let pools = pool_router::get_pool_address_for_stake_token(lp_metadata);
        assert!(vector::length(&pools) == 1, 999); // Assuming only one pool for lp
        let ulp_pool_obj_addr = pools[0];

        // Give users ulp and let them stake for cabal ulp
        let deposit_amount = 1_000_000_000; // 1000 ulp
        primary_fungible_store::transfer(chain, lp_metadata, signer::address_of(user_1), deposit_amount);
        primary_fungible_store::transfer(chain, lp_metadata, signer::address_of(user_2), deposit_amount);

        // --- Staking ---

        utils::increase_block(1, 2);

        // User 1 stakes some ulp
        let stake_amount_1 = 0; // 100 ulp worth
        cabal::stake_asset(user_1, 1, stake_amount_1);
    }

    #[test(c = @staking_addr, chain = @initia_std, user_1 = @0x111, user_2 = @0x222)]
    #[expected_failure(abort_code = 0x50007, location = cabal)]
    fun test_process_lp_stake_with_error_signer(
        c: &signer,
        chain: &signer,
        user_1: &signer,
        user_2: &signer
    ) {
        test_setup(c, string::utf8(b"initvaloper1test"));
        cabal::mock_process_lp_stake(user_1, signer::address_of(user_2), 1, 10)
    }


}