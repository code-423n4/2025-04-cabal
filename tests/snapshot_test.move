#[test_only]
module staking_addr::snapshot_test {
    // Standard Library Imports
    use std::error;
    use std::option;
    use std::signer;
    use std::string::{Self, String};
    use std::vector;

    // Initia Standard Library Imports
    use initia_std::account;
    use initia_std::bigdecimal::{Self, BigDecimal};
    use initia_std::block;
    use initia_std::coin::{Self, MintCapability};
    use initia_std::debug; // Useful for printing during tests
    use initia_std::event;
    use initia_std::fungible_asset::{Self, Metadata};
    use initia_std::math64;
    use initia_std::object::{Self, Object};
    use initia_std::oracle;
    use initia_std::primary_fungible_store::{Self, balance}; // Import balance function
    use initia_std::simple_map::{Self, SimpleMap};
    use initia_std::table::{Self, Table};

    // Local Package Imports (staking_addr)
    use staking_addr::bribe;
    use staking_addr::cabal;
    use staking_addr::cabal_token;
    use staking_addr::emergency;
    use staking_addr::manager;
    use staking_addr::package;
    use staking_addr::pool_router;
    use staking_addr::utils;
    use staking_addr::voting_reward; // Module containing snapshot logic
    use staking_addr::snapshots; // Module containing snapshot storage and getters

    // External Dependencies (if needed by voting_reward functions or setup)
    use vip::lock_staking;
    use vip::weight_vote;
    use vip::vip; // Likely needed if interacting with VIP cycles/rewards

    const MINIMUM_LIQUIDITY: u64 = 100_000_000; // Example, adjust if needed

    fun test_setup(c: &signer) {
        // Initialize dependent modules first
        emergency::init_module_for_test(c);
        manager::initialize_for_test(signer::address_of(c)); // Also initializes package.move
        bribe::init_module_for_test(c);
        cabal_token::init_module_for_test(c);
        pool_router::init_module_for_test(c);
        voting_reward::init_module_for_test(c); // Initialize the module under test
        snapshots::init_module_for_test(c); // Initialize snapshot storage
        utils::increase_block(1, 2);

        // Initialize VIP mock/dependency if needed
        let vip_signer = &account::create_signer_for_test(@vip);
        lock_staking::init_module_for_test(vip_signer);
        utils::increase_block(1, 2);

        // Initialize primary fungible store and mint initial INIT
        let initia_signer = &account::create_signer_for_test(@initia_std);
        primary_fungible_store::init_module_for_test();

        let (init_mint_cap, _, init_metadata) = coin::initialize(
            initia_signer,
            option::none(),
            string::utf8(b"init token"),
            string::utf8(b"uinit"),
            6, // decimals
            string::utf8(b""),
            string::utf8(b"")
        );
        // Mint plenty of INIT to the deployer/test account 'c'
        coin::mint_to(&init_mint_cap, signer::address_of(c), 1_000_000_000_000_000); // 1 million INIT

        // Initialize the main cabal module
        cabal::initialize(c, string::utf8(b"initvaloper1test"), signer::address_of(c)); // Use 'c' as commission addr

        // Manually trigger delegate for the initial minimum liquidity deposit if needed by tests
        // pool_router::mock_trigger_delegate_init(...);
        utils::increase_block(1, 1);

        // --- Setup Users and Initial Staking ---
        let user_a_signer = &account::create_signer_for_test(@0xAAA);
        let user_a_addr = signer::address_of(user_a_signer);
        let user_b_signer = &account::create_signer_for_test(@0xBBB);
        let user_b_addr = signer::address_of(user_b_signer);

        // Mint INIT to users
        let init_amount_user = 500_000_000_000; // 500k INIT
        coin::mint_to(&init_mint_cap, user_a_addr, init_amount_user);
        coin::mint_to(&init_mint_cap, user_b_addr, init_amount_user);

        // User A deposits INIT for xINIT and stakes for sxINIT
        cabal::mock_deposit_init_for_xinit(user_a_signer, init_amount_user);
        let xinit_metadata = cabal::get_xinit_metadata();
        let xinit_balance_a = primary_fungible_store::balance(user_a_addr, xinit_metadata);
        cabal::mock_stake(user_a_signer, 0, xinit_balance_a); // 0 for xINIT -> sxINIT

        // --- Setup LP Token ---
        // Initialize USDC token
        let (usdc_mint_cap, _, _) = coin::initialize(
            initia_signer,
            option::none(),
            string::utf8(b"usdc token"),
            string::utf8(b"uusdc"),
            6, // decimals
            string::utf8(b""),
            string::utf8(b"")
        );
        let usdc_metadata = coin::metadata(@initia_std, string::utf8(b"uusdc"));

        // Create INIT-USDC LP token
        let (init_usdc_lp_mint_cap, _, _)= coin::initialize(
            initia_signer,
            option::none(),
            string::utf8(b"init-usdc lp token"),
            string::utf8(b"uinit_usdc_lp"),
            6, // decimals
            string::utf8(b""),
            string::utf8(b"")
        );
        let lp_metadata = coin::metadata(@initia_std, string::utf8(b"uinit_usdc_lp"));

        // Mint LP tokens to test account 'c' and user B
        coin::mint_to(&init_usdc_lp_mint_cap, signer::address_of(c), 1_000_000_000_000_000);
        coin::mint_to(&init_usdc_lp_mint_cap, user_b_addr, 500_000_000_000); // Give User B some LP

        // Configure LP token in Cabal
        cabal::config_stake_token(
            c,
            60*60*24*21, // 21 day unbonding period
            lp_metadata,
            lp_metadata,
            string::utf8(b"cabal init-usdc lp coin"),
            string::utf8(b"cabalINITUSDC"),
            string::utf8(b""),
            string::utf8(b"")
        );

        // Add LP pool to router
        pool_router::add_pool(c, lp_metadata, string::utf8(b"lpvaloper1test"));

        // Set oracle prices
        let init_usd_pair_id = string::utf8(b"init/usd");
        let usdc_usd_pair_id = string::utf8(b"usdc/usd");
        oracle::set_price(&init_usd_pair_id, 10_000000, 1000001, 6); // $10 per INIT
        oracle::set_price(&usdc_usd_pair_id, 1_000000, 1000001, 6); // $1 per USDC

        // --- Setup Bribe Token (e.g., BTC) ---
        let (_, _, btc_mint) = utils::initialize_coin_for_testing(initia_signer, string::utf8(b"btc"));
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let btc_usd_pair_id = string::utf8(b"btc/usd");
        oracle::set_price(&btc_usd_pair_id, 50000_000000, 1000002, 8); // $50k per BTC
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);
        // Mint some BTC to a potential briber (e.g., user C)
        let user_c_signer = &account::create_signer_for_test(@0xCCC);
        coin::mint_to(&btc_mint, signer::address_of(user_c_signer), 10_00000000); // 10 BTC

        utils::increase_block(1, 1); // Final block advance after setup
    }

    #[test(c = @staking_addr)]
    fun test_snapshot_setup_verification(c: &signer) {
        test_setup(c);
        // Add assertions to verify initial state after setup
        let aaa_addr = @0xAAA;
        let sxinit_metadata = cabal::get_sxinit_metadata();
        assert!(primary_fungible_store::balance(aaa_addr, sxinit_metadata) > 0, 101);

        let lp_metadata = coin::metadata(@initia_std, string::utf8(b"uinit_usdc_lp"));
        let cabal_lp_metadata = cabal::get_cabal_token_metadata(1); // Assuming index 1 for this LP
        assert!(option::is_some(&fungible_asset::supply(cabal_lp_metadata)), 102); // Check cabal LP token exists
    }

    // Bribing -> snapshot
    #[test(c = @staking_addr, user_c = @0xCCC)]
    fun test_bribe_then_snapshot(c: &signer, user_c: &signer) {
        test_setup(c);
        let aaa_addr = @0xAAA;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let sxinit_metadata = cabal::get_sxinit_metadata();
        let initial_sxinit_balance_a = primary_fungible_store::balance(aaa_addr, sxinit_metadata);

        // Bribe
        let cycle = 1;
        let bridge_id = 1;
        let bribe_amount = 1_00000000; // 1 BTC
        bribe::mock_deposit_bribe(user_c, btc_metadata, bribe_amount, cycle, bridge_id);
        utils::increase_block(1, 1);

        // Snapshot
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);

        // Verify snapshot data
        assert!(snapshots::has_snapshot_at(snapshot_height), 201);
        let snapshot_balance_a = cabal_token::get_snapshot_balance(aaa_addr, sxinit_metadata, snapshot_height);
        assert!(snapshot_balance_a == initial_sxinit_balance_a, 202);

        // Finalize cycle to check rewards later (optional for snapshot test itself)
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);
        let reward_a = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        assert!(reward_a > 0, 203); // User A should have received the bribe reward
    }

    // snapshot while init deposit
    #[test(c = @staking_addr, user_b = @0xBBB)]
    fun test_snapshot_during_init_deposit(c: &signer, user_b: &signer) {
        test_setup(c);
        let bbb_addr = signer::address_of(user_b);
        let xinit_metadata = cabal::get_xinit_metadata();
        let sxinit_metadata = cabal::get_sxinit_metadata();
        let init_metadata = utils::get_init_metadata();
        let initial_xinit_balance_b = primary_fungible_store::balance(bbb_addr, xinit_metadata);
        let initial_xinit_supply = cabal::get_xinit_total_supply();

        let deposit_amount = 100_000_000_000;

        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        cabal::mock_deposit_init_for_xinit(user_b, deposit_amount);
        utils::increase_block(1,1);

        assert!(snapshots::has_snapshot_at(snapshot_height), 301);
        let snapshot_xinit_balance_b = cabal_token::get_snapshot_balance(bbb_addr, sxinit_metadata, snapshot_height);
        let snapshot_xinit_supply = cabal_token::get_snapshot_supply(sxinit_metadata, snapshot_height);

        assert!(snapshot_xinit_balance_b == initial_xinit_balance_b, 302);
        assert!(snapshot_xinit_supply == initial_xinit_supply, 303);

        // Verify actual state *after* deposit
        let final_xinit_balance_b = primary_fungible_store::balance(bbb_addr, xinit_metadata);
        assert!(final_xinit_balance_b > initial_xinit_balance_b, 304);
    }

    // Snapshot during staking (xINIT -> sxINIT)
    #[test(c = @staking_addr, user_b = @0xBBB)]
    fun test_snapshot_during_stake(c: &signer, user_b: &signer) {
        test_setup(c);
        let bbb_addr = signer::address_of(user_b);
        let xinit_metadata = cabal::get_xinit_metadata();
        let sxinit_metadata = cabal::get_sxinit_metadata();

        // Ensure User B has xINIT to stake
        let deposit_amount = 200_000_000_000; // 200k INIT
        cabal::mock_deposit_init_for_xinit(user_b, deposit_amount);
        let xinit_to_stake = primary_fungible_store::balance(bbb_addr, xinit_metadata);
        assert!(xinit_to_stake > 0, 401);

        let initial_sxinit_balance_b = primary_fungible_store::balance(bbb_addr, sxinit_metadata);
        let initial_sxinit_supply = cabal::get_sxinit_total_supply();

        // Perform stake and snapshot in the same logical step
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c); // snapshot takes everything into account within the same block
        cabal::mock_stake(user_b, 0, xinit_to_stake); // Stake xINIT
        utils::increase_block(1, 1);

        assert!(snapshots::has_snapshot_at(snapshot_height), 402);
        let snapshot_sxinit_balance_b = cabal_token::get_snapshot_balance(bbb_addr, sxinit_metadata, snapshot_height);
        let snapshot_sxinit_supply = cabal_token::get_snapshot_supply(sxinit_metadata, snapshot_height);

        utils::test_with_slack(snapshot_sxinit_balance_b, initial_sxinit_balance_b + xinit_to_stake, 1);
        utils::test_with_slack(snapshot_sxinit_supply as u64, (initial_sxinit_supply as u64) + xinit_to_stake, 1);
        let final_sxinit_balance_b = primary_fungible_store::balance(bbb_addr, sxinit_metadata);
        assert!(final_sxinit_balance_b > initial_sxinit_balance_b, 405);
    }

    // Multiple snapshots with changing balances
    #[test(c =@staking_addr, user_a = @0xAAA, user_b = @0xBBB)]
    fun test_multiple_snapshots_changing_balances(c: &signer, user_a: &signer, user_b: &signer) {
        test_setup(c);
        let aaa_addr = signer::address_of(user_a);
        let bbb_addr = signer::address_of(user_b);
        let sxinit_metadata = cabal::get_sxinit_metadata();
        let xinit_metadata = cabal::get_xinit_metadata();
        let init_metadata = utils::get_init_metadata();

        // --- Snapshot 1: Initial state from setup ---
        let balance_a_s1 = primary_fungible_store::balance(aaa_addr, sxinit_metadata);
        let balance_b_s1 = primary_fungible_store::balance(bbb_addr, sxinit_metadata); // Should be 0 initially
        let supply_s1 = cabal::get_sxinit_total_supply();
        utils::increase_block(1, 1);
        let height_s1 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        assert!(snapshots::has_snapshot_at(height_s1), 501);
        assert!(cabal_token::get_snapshot_balance(aaa_addr, sxinit_metadata, height_s1) == balance_a_s1, 502);
        assert!(cabal_token::get_snapshot_balance(bbb_addr, sxinit_metadata, height_s1) == balance_b_s1, 503);
        assert!(cabal_token::get_snapshot_supply(sxinit_metadata, height_s1) == supply_s1, 504);

        // --- User B stakes ---
        utils::increase_block(1, 1);
        let deposit_b = 300_000_000_000; 
        cabal::mock_deposit_init_for_xinit(user_b, deposit_b);
        let xinit_balance_b = primary_fungible_store::balance(bbb_addr, xinit_metadata);
        cabal::mock_stake(user_b, 0, xinit_balance_b);

        // --- Snapshot 2: After User B stakes ---
        let balance_a_s2 = primary_fungible_store::balance(aaa_addr, sxinit_metadata); // same
        let balance_b_s2 = primary_fungible_store::balance(bbb_addr, sxinit_metadata); // + 300k
        let supply_s2 = cabal::get_sxinit_total_supply(); // + 300k
        utils::increase_block(1, 1);
        let height_s2 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        assert!(snapshots::has_snapshot_at(height_s2), 505);
        assert!(cabal_token::get_snapshot_balance(aaa_addr, sxinit_metadata, height_s2) == balance_a_s2, 506);
        assert!(cabal_token::get_snapshot_balance(bbb_addr, sxinit_metadata, height_s2) == balance_b_s2, 507);
        assert!(cabal_token::get_snapshot_supply(sxinit_metadata, height_s2) == supply_s2, 508);
        assert!(balance_b_s2 > balance_b_s1, 509);
        assert!(supply_s2 > supply_s1, 510);
        utils::test_with_slack(balance_b_s2, balance_b_s1 + deposit_b, 1);
        utils::test_with_slack(supply_s2 as u64, (supply_s1 as u64)+ deposit_b, 1);

        // a unstakes half
        cabal::init_fees_exempt(c);
        cabal::set_fees_exempt(c, vector[aaa_addr]); // Whitelist user A
        utils::increase_block(1, 1);
        let unstake_a = balance_a_s2 / 2;
        cabal::mock_unstake(user_a, 0, unstake_a);

        let balance_a_s3 = primary_fungible_store::balance(aaa_addr, sxinit_metadata); // Decreased
        let balance_b_s3 = primary_fungible_store::balance(bbb_addr, sxinit_metadata); // Unchanged
        let supply_s3 = cabal::get_sxinit_total_supply(); // Decreased
        utils::increase_block(1, 1);
        let height_s3 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        assert!(snapshots::has_snapshot_at(height_s3), 511);
        utils::increase_block(1, 1);

        // debug::print(&string::utf8(b"actual block"));
        // debug::print(&height_s3);
        assert!(cabal_token::get_snapshot_balance(aaa_addr, sxinit_metadata, height_s3) == balance_a_s3, 512);
        assert!(cabal_token::get_snapshot_balance(bbb_addr, sxinit_metadata, height_s3) == balance_b_s3, 513);
        assert!(cabal_token::get_snapshot_supply(sxinit_metadata, height_s3) == supply_s3, 514);
        assert!(balance_a_s3 < balance_a_s2, 515);
        assert!(supply_s3 < supply_s2, 516);
        utils::test_with_slack(balance_a_s2, balance_a_s3 + unstake_a, 1);
        utils::test_with_slack(supply_s2 as u64, (supply_s3 as u64)+ unstake_a, 1);

        // Verify previous snapshots remain unchanged
        // debug::print(&string::utf8(b"balance_a_s1"));
        // debug::print(&balance_a_s1);
        // debug::print(&string::utf8(b"snapshot balance_a_s1"));
        // debug::print(&cabal_token::get_snapshot_balance(aaa_addr, sxinit_metadata, height_s1));
        assert!(cabal_token::get_snapshot_balance(aaa_addr, sxinit_metadata, height_s1) == balance_a_s1, 517);
        assert!(cabal_token::get_snapshot_supply(sxinit_metadata, height_s2) == supply_s2, 518);
    }

    // Test querying snapshots at intermediate block heights
    #[test(c = @staking_addr, user_a = @0xAAA, user_b = @0xBBB)]
    fun test_snapshot_query_intermediate_blocks(c: &signer, user_a: &signer, user_b: &signer) {
        test_setup(c);
        let aaa_addr = signer::address_of(user_a);
        let bbb_addr = signer::address_of(user_b);
        let sxinit_metadata = cabal::get_sxinit_metadata();
        let xinit_metadata = cabal::get_xinit_metadata();
        
        // --- First Snapshot ---
        let balance_a_s1 = primary_fungible_store::balance(aaa_addr, sxinit_metadata);
        let balance_b_s1 = primary_fungible_store::balance(bbb_addr, sxinit_metadata); // Should be 0 initially
        let supply_s1 = cabal::get_sxinit_total_supply();
        utils::increase_block(1, 1);
        let height_s1 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(5, 5); // Increase by 5 blocks
        
        // --- User B stakes between snapshots ---
        let intermediate_height = block::get_current_block_height();
        utils::increase_block(1, 1);
        let deposit_b = 300_000_000_000; 
        cabal::mock_deposit_init_for_xinit(user_b, deposit_b);
        let xinit_balance_b = primary_fungible_store::balance(bbb_addr, xinit_metadata);
        cabal::mock_stake(user_b, 0, xinit_balance_b);
        utils::increase_block(5, 5); // Increase by 5 more blocks
        
        // --- Second Snapshot (after B's stake) ---
        let balance_a_s2 = primary_fungible_store::balance(aaa_addr, sxinit_metadata); // Same
        let balance_b_s2 = primary_fungible_store::balance(bbb_addr, sxinit_metadata); // Now has staked xINIT
        let supply_s2 = cabal::get_sxinit_total_supply(); // Increased
        let height_s2 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        
        // Verify snapshots are recorded correctly
        assert!(snapshots::has_snapshot_at(height_s1), 601);
        assert!(snapshots::has_snapshot_at(height_s2), 602);
        assert!(!snapshots::has_snapshot_at(intermediate_height), 603); // No snapshot at intermediate height
        
        // Verify snapshot 1 values
        assert!(cabal_token::get_snapshot_balance(aaa_addr, sxinit_metadata, height_s1) == balance_a_s1, 604);
        assert!(cabal_token::get_snapshot_balance(bbb_addr, sxinit_metadata, height_s1) == balance_b_s1, 605);
        assert!(cabal_token::get_snapshot_supply(sxinit_metadata, height_s1) == supply_s1, 606);
        
        // Verify snapshot 2 values
        assert!(cabal_token::get_snapshot_balance(aaa_addr, sxinit_metadata, height_s2) == balance_a_s2, 607);
        assert!(cabal_token::get_snapshot_balance(bbb_addr, sxinit_metadata, height_s2) == balance_b_s2, 608);
        assert!(cabal_token::get_snapshot_supply(sxinit_metadata, height_s2) == supply_s2, 609);
        
        let intermediate_balance_a = cabal_token::get_snapshot_balance(aaa_addr, sxinit_metadata, intermediate_height);
        let intermediate_balance_b = cabal_token::get_snapshot_balance(bbb_addr, sxinit_metadata, intermediate_height);
        
        // debug::print(&intermediate_balance_b);
        // debug::print(&balance_b_s1);
        
        assert!(intermediate_balance_a == balance_a_s1, 610);
        assert!(intermediate_balance_b == balance_b_s1, 611);
        
        // Also test block height that's before the first snapshot
        let early_height = height_s1 - 2; 
        let early_balance_a = cabal_token::get_snapshot_balance(aaa_addr, sxinit_metadata, early_height);
        assert!(early_balance_a == balance_a_s2, 613); // Should return current balance
        let future_height = height_s2 + 10;
        let future_balance_a = cabal_token::get_snapshot_balance(aaa_addr, sxinit_metadata, future_height);
        assert!(future_balance_a == balance_a_s2, 615);
    }
}