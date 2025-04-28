/*
IMPORTANT EXPLANATTION:

The function get_single_reward, get_unclaimed_voting rewards, etc rely on the function mock_voting_power_weight in snapshots.move.
This function uses a mock calculation, that always assumes a weight of 1 to sxINIT and .8 to all LP tokens.

Thus, if you are testing LP voting rewards, with only lp tokens, keep this in mind:

User A stakes LP (only staker)
Bribe of 50 BTC
user A's reward is 50 * (.8/1.8) BTC
*/


#[test_only]
module staking_addr::lp_voting_test {
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
    use initia_std::coin;
    use initia_std::debug;
    use initia_std::fungible_asset::{Self, Metadata};
    use initia_std::object::{Self, Object};
    use initia_std::oracle;
    use initia_std::primary_fungible_store;
    use initia_std::simple_map::{Self, SimpleMap};
    use initia_std::table; // Needed for snapshot checks

    // Local Package Imports (staking_addr)
    use staking_addr::bribe;
    use staking_addr::voting_reward; // Needed for snapshotting
    use staking_addr::snapshots; // Needed for snapshot checks
    use staking_addr::cabal;
    use staking_addr::cabal_token;
    use staking_addr::emergency;
    use staking_addr::manager;
    use staking_addr::package;
    use staking_addr::pool_router;
    use staking_addr::utils;

    // External Dependencies
    use vip::vip;
    use vip::lock_staking;
    use vip::weight_vote;

    // Test Setup Function
    public fun test_setup(c: &signer) {
        // Initialize dependent modules first
        emergency::init_module_for_test(c);
        manager::initialize_for_test(signer::address_of(c)); // Also initializes package.move
        bribe::init_module_for_test(c);
        cabal_token::init_module_for_test(c);
        pool_router::init_module_for_test(c);
        voting_reward::init_module_for_test(c); // Initialize voting_reward
        snapshots::init_module_for_test(c); // Initialize snapshots
        utils::increase_block(1, 2);

        // Initialize VIP mock
        let vip_signer = &account::create_signer_for_test(@vip);
        lock_staking::init_module_for_test(vip_signer);
        utils::increase_block(1, 2);

        // Initialize primary fungible store and mint initial INIT
        let initia_signer = &account::create_signer_for_test(@initia_std);
        primary_fungible_store::init_module_for_test();

        // Initialize INIT token
        let (init_mint_cap, _, _) = coin::initialize(
            initia_signer,
            option::none(),
            string::utf8(b"init token"),
            string::utf8(b"uinit"),
            6, // decimals
            string::utf8(b""),
            string::utf8(b"")
        );
        
        // Mint INIT to the deployer/test account
        coin::mint_to(&init_mint_cap, signer::address_of(c), 1_000_000_000_000_000); // 1 million INIT

        // Initialize Cabal module
        cabal::initialize(c, string::utf8(b"validator123"), signer::address_of(c));

        // *** Fix 1 & 2: Manually trigger delegate and stake for initial liquidity ***
        let init_metadata_setup = coin::metadata(@initia_std, string::utf8(b"uinit"));
        let pools_setup = pool_router::get_pool_address_for_stake_token(init_metadata_setup);
        assert!(vector::length(&pools_setup) == 1, 998);
        let init_pool_obj_addr_setup = pools_setup[0];
        let init_pool_obj_setup = object::address_to_object<pool_router::StakePool>(init_pool_obj_addr_setup);

        // Initialize LP tokens for testing
        let (usdc_mint_cap, _, _) = coin::initialize(
            initia_signer,
            option::none(),
            string::utf8(b"usdc token"),
            string::utf8(b"uusdc"),
            6, // decimals
            string::utf8(b""),
            string::utf8(b"")
        );
        
        // Create INIT-USDC LP token
        let (init_usdc_lp_mint_cap, _, _) = coin::initialize(
            initia_signer,
            option::none(),
            string::utf8(b"init-usdc lp token"),
            string::utf8(b"uinit_usdc_lp"),
            6, // decimals
            string::utf8(b""),
            string::utf8(b"")
        );
        
        // Mint LP tokens to test account
        coin::mint_to(&init_usdc_lp_mint_cap, signer::address_of(c), 1_000_000_000_000_000);
        
        // Configure LP token in Cabal
        let lp_metadata = coin::metadata(@initia_std, string::utf8(b"uinit_usdc_lp"));
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
        pool_router::add_pool(c, lp_metadata, string::utf8(b"initvaloper1test"));
        
        // Set oracle prices if needed for LP valuation
        let init_usd_pair_id = string::utf8(b"init/usd");
        let usdc_usd_pair_id = string::utf8(b"usdc/usd");
        
        oracle::set_price(
            &init_usd_pair_id,
            10_000000, // $10 per INIT
            1000001,
            6
        );
        
        oracle::set_price(
            &usdc_usd_pair_id,
            1_000000, // $1 per USDC
            1000001,
            6
        );

        utils::increase_block(1, 1);
    }

    // Basic test to verify setup works
    #[test(c = @staking_addr)]
    public fun test_lp_voting_setup(c: &signer) {
        test_setup(c);
        
        // Verify LP token is configured in Cabal
        let lp_metadata = coin::metadata(@initia_std, string::utf8(b"uinit_usdc_lp"));
        let pools = pool_router::get_pool_address_for_stake_token(lp_metadata);
        assert!(vector::length(&pools) == 1, 101);
    }

    // Test basic LP token deposit and staking
    #[test(c = @staking_addr, user_a = @0xAAA)]
    fun test_lp_stake(c: &signer, user_a: &signer) {
        test_setup(c);
        let stake_type_index = 1;
        let aaa_addr = signer::address_of(user_a);
        let lp_metadata = coin::metadata(@initia_std, string::utf8(b"uinit_usdc_lp"));
        let cabal_lp_metadata = cabal::get_cabal_token_metadata(stake_type_index);

        let lp_amount_to_mint = 100_000_000_000;
        primary_fungible_store::transfer(c, lp_metadata, aaa_addr, lp_amount_to_mint);
        assert!(primary_fungible_store::balance(aaa_addr, lp_metadata) == lp_amount_to_mint, 201);

        
        cabal::mock_stake(user_a, stake_type_index, lp_amount_to_mint);

        // Verify user A received cabalINITUSDC and LP balance is 0
        assert!(primary_fungible_store::balance(aaa_addr, lp_metadata) == 0, 202);
        assert!(primary_fungible_store::balance(aaa_addr, cabal_lp_metadata) == lp_amount_to_mint, 203);

        // Verify total supply of cabalINITUSDC increased
        let supply = option::get_with_default(&fungible_asset::supply(cabal_lp_metadata), 0);
        assert!(supply == (lp_amount_to_mint as u128), 204);
    }

    // Test snapshotting after LP staking
    #[test(c = @staking_addr, user_a = @0xAAA)]
    fun test_lp_stake_snapshot(c: &signer, user_a: &signer) {
        test_setup(c);
        let stake_type_index = 1;
        let aaa_addr = signer::address_of(user_a);
        let lp_metadata = coin::metadata(@initia_std, string::utf8(b"uinit_usdc_lp"));
        let cabal_lp_metadata = cabal::get_cabal_token_metadata(stake_type_index);

        // Stake LP tokens
        let lp_amount_to_stake = 200_000_000_000;
        primary_fungible_store::transfer(c, lp_metadata, aaa_addr, lp_amount_to_stake);
        
        cabal::mock_stake(user_a, stake_type_index, lp_amount_to_stake);
        assert!(primary_fungible_store::balance(aaa_addr, cabal_lp_metadata) == lp_amount_to_stake, 301);

        // Take a snapshot
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        assert!(snapshots::has_snapshot_at(snapshot_height), 302);

        // Verify snapshot supply and balance
        let snapshot_supply = cabal_token::get_snapshot_supply(cabal_lp_metadata, snapshot_height);
        assert!(snapshot_supply == (lp_amount_to_stake as u128), 303);
        let snapshot_balance_a = cabal_token::get_snapshot_balance(aaa_addr, cabal_lp_metadata, snapshot_height);
        assert!(snapshot_balance_a == lp_amount_to_stake, 304);

        let snapshot_weight = snapshots::get_snapshot_weight(snapshot_height, lp_metadata);
        assert!(bigdecimal::eq(snapshot_weight, bigdecimal::from_ratio_u128(8, 18)), 305);
        let init_metadata = utils::get_init_metadata();
        let init_snapshot_weight = snapshots::get_snapshot_weight(snapshot_height, init_metadata);
        assert!(bigdecimal::eq(init_snapshot_weight, bigdecimal::from_ratio_u64(5, 9)), 306);
    }

    // Test reward distribution with mixed staking (sxINIT and cabalINITUSDC) and claim LP reward
    #[test(c = @staking_addr, user_a = @0xAAA, user_b = @0xBBB, bribee = @0xCCC)]
    fun test_mixed_stake_reward_distribution_and_claim(c: &signer, user_a: &signer, user_b: &signer, bribee: &signer) {
        test_setup(c);
        let stake_type_index = 1;
        let aaa_addr = signer::address_of(user_a);
        let bbb_addr = signer::address_of(user_b);

        // --- Setup User A: Stake sxINIT ---
        let init_metadata = utils::get_init_metadata();
        let xinit_metadata = cabal::get_xinit_metadata();
        let sxinit_metadata = cabal::get_sxinit_metadata();
        let init_amount_a = 500_000_000_000; 
        primary_fungible_store::transfer(c, init_metadata, aaa_addr, init_amount_a);
        cabal::mock_deposit_init_for_xinit(user_a, init_amount_a);
        let xinit_balance_a = primary_fungible_store::balance(aaa_addr, xinit_metadata);
        assert!(xinit_balance_a == init_amount_a, 401);
        cabal::mock_stake(user_a, 0, xinit_balance_a); // Stake xINIT for sxINIT
        let sxinit_balance_a = primary_fungible_store::balance(aaa_addr, sxinit_metadata);
        assert!(sxinit_balance_a == init_amount_a, 402);
        utils::increase_block(1, 1);

        // --- Setup User B: Stake cabalINITUSDC ---
        let lp_metadata = coin::metadata(@initia_std, string::utf8(b"uinit_usdc_lp"));
        let cabal_lp_metadata = cabal::get_cabal_token_metadata(stake_type_index);
        let lp_amount_b = 500_000_000_000;
        primary_fungible_store::transfer(c, lp_metadata, bbb_addr, lp_amount_b);
        cabal::mock_stake(user_b, stake_type_index, lp_amount_b);
        let cabal_lp_balance_b = primary_fungible_store::balance(bbb_addr, cabal_lp_metadata);
        assert!(cabal_lp_balance_b == lp_amount_b, 403);
        utils::increase_block(1, 1);

        // --- Deposit Bribe ---
        // Mint bribe token (e.g., BTC) to bribee
        let (_, _, btc_mint) = utils::initialize_coin_for_testing(&account::create_signer_for_test(@initia_std), string::utf8(b"btc"));
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let bribe_amount = 100_000000; // 1 BTC
        coin::mint_to(&btc_mint, signer::address_of(bribee), bribe_amount);
        // Set oracle price for BTC
        let btc_usd_pair_id = string::utf8(b"btc/usd");
        oracle::set_price(&btc_usd_pair_id, 100_00000000, 1000002, 8);
        // Allow BTC as bribe token
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);

        let cycle = 1;
        let bridge_id = 101;
        bribe::mock_deposit_bribe(bribee, btc_metadata, bribe_amount, cycle, bridge_id);

        // --- Take Snapshot & Verify Weights ---
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1,1);
        assert!(snapshots::has_snapshot_at(snapshot_height), 404);

        // Verify weights from snapshot using the *original* metadata
        let weight_init = snapshots::get_snapshot_weight(snapshot_height, init_metadata);
        let weight_lp = snapshots::get_snapshot_weight(snapshot_height, lp_metadata);
        assert!(bigdecimal::eq(weight_init, bigdecimal::from_ratio_u64(5, 9)), 405);// See test above for explanation on numbers
        assert!(bigdecimal::eq(weight_lp, bigdecimal::from_ratio_u64(4, 9)), 406);

        // --- Finalize Cycle ---
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // --- Verify Reward Distribution ---
        // weight of user a is 5/9
        // weight of user b is 4/9

        let expected_share_a = bribe_amount * 5 / 9;
        let expected_share_b = bribe_amount * 4 / 9;

        let reward_a = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        let reward_b = voting_reward::get_single_reward(bbb_addr, btc_metadata);

        // Use a tolerance check due to potential integer division differences
        utils::test_with_slack(reward_a, expected_share_a, 1); 
        utils::test_with_slack(reward_b, expected_share_b, 1); 
        utils::test_with_slack(reward_a + reward_b, bribe_amount, 1);

        // --- Verify Claiming LP Reward ---
        let initial_btc_balance_b = primary_fungible_store::balance(bbb_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_b, btc_metadata); // User B claims their BTC reward
        let final_btc_balance_b = primary_fungible_store::balance(bbb_addr, btc_metadata);

        // Check if the claimed amount matches the calculated reward for B
        let claimed_amount_b = final_btc_balance_b - initial_btc_balance_b;
        utils::test_with_slack(claimed_amount_b, reward_b, 0); // Should be exact match after calculation

        // Verify remaining claimable for B is zero
        let remaining_reward_b = voting_reward::get_unclaimed_voting_reward(bbb_addr, btc_metadata);
        assert!(remaining_reward_b == 0, 407);
    }

    // Test a single user with mixed stake types (sxINIT and cabalINITUSDC)
    #[test(c = @staking_addr, user_a = @0xAAA, bribee = @0xCCC)]
    fun test_single_user_mixed_stake_rewards(c: &signer, user_a: &signer, bribee: &signer) {
        test_setup(c);
        let user_a_addr = signer::address_of(user_a);

        // --- Setup User A: Stake sxINIT ---
        let init_metadata = utils::get_init_metadata();
        let xinit_metadata = cabal::get_xinit_metadata();
        let sxinit_metadata = cabal::get_sxinit_metadata();
        let init_amount = 300_000_000_000; 
        primary_fungible_store::transfer(c, init_metadata, user_a_addr, init_amount);
        cabal::mock_deposit_init_for_xinit(user_a, init_amount);
        let xinit_balance = primary_fungible_store::balance(user_a_addr, xinit_metadata);
        cabal::mock_stake(user_a, 0, xinit_balance); // Stake xINIT for sxINIT
        utils::increase_block(1, 1);

        // --- Setup User A: Also stake cabalINITUSDC ---
        let stake_type_index = 1;
        let lp_metadata = coin::metadata(@initia_std, string::utf8(b"uinit_usdc_lp"));
        let cabal_lp_metadata = cabal::get_cabal_token_metadata(stake_type_index);
        let lp_amount = 200_000_000_000;
        primary_fungible_store::transfer(c, lp_metadata, user_a_addr, lp_amount);
        cabal::mock_stake(user_a, stake_type_index, lp_amount);
        utils::increase_block(1, 1);

        // --- Deposit Bribe ---
        let (_, _, btc_mint) = utils::initialize_coin_for_testing(&account::create_signer_for_test(@initia_std), string::utf8(b"btc"));
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let bribe_amount = 50_000000; // 0.5 BTC
        coin::mint_to(&btc_mint, signer::address_of(bribee), bribe_amount);
        let btc_usd_pair_id = string::utf8(b"btc/usd");
        oracle::set_price(&btc_usd_pair_id, 100_00000000, 1000002, 8);
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);

        let cycle = 1;
        let bridge_id = 101;
        bribe::mock_deposit_bribe(bribee, btc_metadata, bribe_amount, cycle, bridge_id);

        // --- Take Snapshot & Finalize ---
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // --- Verify Reward Calculation ---
        let reward = voting_reward::get_single_reward(user_a_addr, btc_metadata);
        utils::test_with_slack(reward, bribe_amount, 1);

        // --- Verify Claim Works Correctly ---
        let initial_btc_balance = primary_fungible_store::balance(user_a_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        let final_btc_balance = primary_fungible_store::balance(user_a_addr, btc_metadata);
        
        utils::test_with_slack(final_btc_balance - initial_btc_balance, bribe_amount, 1);
        assert!(voting_reward::get_unclaimed_voting_reward(user_a_addr, btc_metadata) == 0, 503);
    }

    // Test multiple LP types with different users
    #[test(c = @staking_addr, user_a = @0xAAA, user_b = @0xBBB, bribee = @0xCCC)]
    fun test_multiple_lp_types_rewards(c: &signer, user_a: &signer, user_b: &signer, bribee: &signer) {
        test_setup(c);
        let user_a_addr = signer::address_of(user_a);
        let user_b_addr = signer::address_of(user_b);
        let initia_signer = &account::create_signer_for_test(@initia_std);
        
        // --- Setup INIT-ETH LP token ---
        let (eth_mint_cap, _, _) = coin::initialize(
            initia_signer,
            option::none(),
            string::utf8(b"eth token"),
            string::utf8(b"ueth"),
            18, // decimals
            string::utf8(b""),
            string::utf8(b"")
        );
        
        let (init_eth_lp_mint_cap, _, _) = coin::initialize(
            initia_signer,
            option::none(),
            string::utf8(b"init-eth lp token"),
            string::utf8(b"uinit_eth_lp"),
            6, // decimals
            string::utf8(b""),
            string::utf8(b"")
        );
        
        // Set ETH oracle price
        let eth_usd_pair_id = string::utf8(b"eth/usd");
        oracle::set_price(
            &eth_usd_pair_id,
            3000_000000, // $3000 per ETH
            1000003,
            6
        );
        
        // Configure INIT-ETH LP token in Cabal
        let eth_lp_metadata = coin::metadata(@initia_std, string::utf8(b"uinit_eth_lp"));
        cabal::config_stake_token(
            c,
            60*60*24*21, // 21 day unbonding period
            eth_lp_metadata,
            eth_lp_metadata,
            string::utf8(b"cabal init-eth lp coin"),
            string::utf8(b"cabalINITETH"),
            string::utf8(b""),
            string::utf8(b"")
        );
        
        // Add ETH LP pool to router
        pool_router::add_pool(c, eth_lp_metadata, string::utf8(b"initvaloper2test"));
        
        // --- Setup User A: Stake cabalINITUSDC ---
        let usdc_stake_type_index = 1;
        let usdc_lp_metadata = coin::metadata(@initia_std, string::utf8(b"uinit_usdc_lp"));
        let cabal_usdc_lp_metadata = cabal::get_cabal_token_metadata(usdc_stake_type_index);
        let usdc_lp_amount = 200_000_000_000;
        primary_fungible_store::transfer(c, usdc_lp_metadata, user_a_addr, usdc_lp_amount);
        cabal::mock_stake(user_a, usdc_stake_type_index, usdc_lp_amount);
        utils::increase_block(1, 1);

        // --- Setup User B: Stake cabalINITETH ---
        let eth_stake_type_index = 2; // Assuming this is the third token type (0=sxINIT, 1=cabalINITUSDC, 2=cabalINITETH)
        let cabal_eth_lp_metadata = cabal::get_cabal_token_metadata(eth_stake_type_index);
        let eth_lp_amount = 100_000_000_000;
        coin::mint_to(&init_eth_lp_mint_cap, user_b_addr, eth_lp_amount);
        cabal::mock_stake(user_b, eth_stake_type_index, eth_lp_amount);
        utils::increase_block(1, 1);

        // --- Deposit Bribe ---
        let (_, _, btc_mint) = utils::initialize_coin_for_testing(initia_signer, string::utf8(b"btc"));
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let bribe_amount = 100_000000; // 1 BTC
        coin::mint_to(&btc_mint, signer::address_of(bribee), bribe_amount);
        let btc_usd_pair_id = string::utf8(b"btc/usd");
        oracle::set_price(&btc_usd_pair_id, 100_00000000, 1000002, 8);
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);

        let cycle = 1;
        let bridge_id = 101;
        bribe::mock_deposit_bribe(bribee, btc_metadata, bribe_amount, cycle, bridge_id);

        // --- Take Snapshot & Finalize ---
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // --- Verify Reward Calculation ---
        // Based on the LP values (USDC=$1, ETH=$3000), the INIT portion weights will be different
        // INIT-USDC should have less weight than INIT-ETH because ETH is more valuable
        // Exact calculation depends on Cabal's weight algorithm in snapshots module
        let reward_a = voting_reward::get_single_reward(user_a_addr, btc_metadata);
        let reward_b = voting_reward::get_single_reward(user_b_addr, btc_metadata);
        
        // Verify rewards are non-zero and sum to bribe_amount
        assert!(reward_a > 0 && reward_b > 0, 601);
        // debug::print(&reward_a);
        // debug::print(&reward_b);
        // debug::print(&(bribe_amount * 1600 / 2600));
        utils::test_with_slack((reward_a + reward_b), bribe_amount * 1600 / 2600, 1);
        
        // --- Verify Claims Work Correctly ---
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        voting_reward::claim_voting_reward(user_b, btc_metadata);
        
        assert!(voting_reward::get_unclaimed_voting_reward(user_a_addr, btc_metadata) == 0, 602);
        assert!(voting_reward::get_unclaimed_voting_reward(user_b_addr, btc_metadata) == 0, 603);
    }

    // Test rewards distribution with only LP stakers (no sxINIT)
    #[test(c = @staking_addr, user_a = @0xAAA, user_b = @0xBBB, bribee = @0xCCC)]
    fun test_only_lp_stakers_rewards(c: &signer, user_a: &signer, user_b: &signer, bribee: &signer) {
        test_setup(c);
        let user_a_addr = signer::address_of(user_a);
        let user_b_addr = signer::address_of(user_b);
        
        // --- Setup User A & B: Stake cabalINITUSDC ---
        let stake_type_index = 1;
        let lp_metadata = coin::metadata(@initia_std, string::utf8(b"uinit_usdc_lp"));
        let cabal_lp_metadata = cabal::get_cabal_token_metadata(stake_type_index);
        
        // User A stakes 300M LP tokens
        let lp_amount_a = 300_000_000_000;
        primary_fungible_store::transfer(c, lp_metadata, user_a_addr, lp_amount_a);
        cabal::mock_stake(user_a, stake_type_index, lp_amount_a);
        
        // User B stakes 100M LP tokens
        let lp_amount_b = 100_000_000_000;
        primary_fungible_store::transfer(c, lp_metadata, user_b_addr, lp_amount_b);
        cabal::mock_stake(user_b, stake_type_index, lp_amount_b);
        
        utils::increase_block(1, 1);

        // --- Deposit Bribe ---
        let (_, _, btc_mint) = utils::initialize_coin_for_testing(&account::create_signer_for_test(@initia_std), string::utf8(b"btc"));
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let bribe_amount = 80_000000;
        coin::mint_to(&btc_mint, signer::address_of(bribee), bribe_amount);
        let btc_usd_pair_id = string::utf8(b"btc/usd");
        oracle::set_price(&btc_usd_pair_id, 100_00000000, 1000002, 8);
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);

        let cycle = 1;
        let bridge_id = 101;
        bribe::mock_deposit_bribe(bribee, btc_metadata, bribe_amount, cycle, bridge_id);

        // --- Take Snapshot & Finalize ---
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // --- Verify Reward Calculation ---
        // User A has 3/4 of total LP tokens, User B has 1/4
        let lp_bribe_amount = bribe_amount * 800 / 1800;
        let expected_reward_a = lp_bribe_amount * 3 / 4; // 75% of rewards
        let expected_reward_b = lp_bribe_amount * 1 / 4; // 25% of rewards

        // debug::print(&bribe_amount);
        // debug::print(&lp_bribe_amount);
        // debug::print(&expected_reward_a);
        // debug::print(&expected_reward_b);
        // debug::print(&(expected_reward_a + expected_reward_b));
        
        let reward_a = voting_reward::get_single_reward(user_a_addr, btc_metadata);
        let reward_b = voting_reward::get_single_reward(user_b_addr, btc_metadata);
        
        utils::test_with_slack(reward_a, expected_reward_a, 1);
        utils::test_with_slack(reward_b, expected_reward_b, 1);
        utils::test_with_slack(reward_a + reward_b, lp_bribe_amount, 1);
        
        // --- Verify Claims Work Correctly ---
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        voting_reward::claim_voting_reward(user_b, btc_metadata);
        
        assert!(voting_reward::get_unclaimed_voting_reward(user_a_addr, btc_metadata) == 0, 701);
        assert!(voting_reward::get_unclaimed_voting_reward(user_b_addr, btc_metadata) == 0, 702);
    }

    // Test LP stake changes across cycles
    #[test(c = @staking_addr, user_a = @0xAAA, user_b = @0xBBB, bribee = @0xCCC)]
    fun test_lp_stake_changes_across_cycles(c: &signer, user_a: &signer, user_b: &signer, bribee: &signer) {
        test_setup(c);
        let user_a_addr = signer::address_of(user_a);
        let user_b_addr = signer::address_of(user_b);
        cabal::register(user_a);
        cabal::register(user_b);
        
        // --- Setup: Initialize bribe token ---
        let (_, _, btc_mint) = utils::initialize_coin_for_testing(&account::create_signer_for_test(@initia_std), string::utf8(b"btc"));
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        
        // Set BTC price
        let btc_usd_pair_id = string::utf8(b"btc/usd");
        oracle::set_price(&btc_usd_pair_id, 100_00000000, 1000002, 8);
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);

        // --- Cycle 1: Only User A has stake ---
        let stake_type_index = 1;
        let lp_metadata = coin::metadata(@initia_std, string::utf8(b"uinit_usdc_lp"));
        let cabal_lp_metadata = cabal::get_cabal_token_metadata(stake_type_index);
        
        // User A stakes 200M LP tokens
        let lp_amount_a = 200_000_000_000;
        primary_fungible_store::transfer(c, lp_metadata, user_a_addr, lp_amount_a);
        cabal::mock_stake(user_a, stake_type_index, lp_amount_a);
        utils::increase_block(1, 1);
        
        // Deposit Bribe for Cycle 1
        let bribe_amount_1 = 50_000000; 
        coin::mint_to(&btc_mint, signer::address_of(bribee), bribe_amount_1);
        bribe::mock_deposit_bribe(bribee, btc_metadata, bribe_amount_1, 1, 101);
        
        // Take Snapshot & Finalize Cycle 1
        utils::increase_block(1, 1);
        let snapshot_height_1 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, 1, snapshot_height_1);
        utils::increase_block(1,1);
        utils::test_with_slack(voting_reward::get_unclaimed_voting_reward(user_a_addr, btc_metadata), 50_000000 * 800 / 1800, 1);
        
        // --- Cycle 2: User B joins with stake ---
        // User B stakes 300M LP tokens
        let lp_amount_b = 300_000_000_000;
        primary_fungible_store::transfer(c, lp_metadata, user_b_addr, lp_amount_b);
        cabal::mock_stake(user_b, stake_type_index, lp_amount_b);
        utils::increase_block(1, 1);
        
        // Deposit Bribe for Cycle 2
        let bribe_amount_2 = 60_000000;
        coin::mint_to(&btc_mint, signer::address_of(bribee), bribe_amount_2);
        bribe::mock_deposit_bribe(bribee, btc_metadata, bribe_amount_2, 2, 101);
        
        // Take Snapshot & Finalize Cycle 2
        utils::increase_block(1, 1);
        let snapshot_height_2 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, 2, snapshot_height_2);
        
        // --- Verify Cycle 1 Rewards ---
        // User A should get 100% of Cycle 1 rewards
        let cycle1_reward_a = voting_reward::get_single_reward(user_a_addr, btc_metadata);
        let cycle1_reward_b = voting_reward::get_single_reward(user_b_addr, btc_metadata);
        
        // Claim cycle 1 rewards
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        
        // --- Verify Cycle 2 Rewards ---
        // User A has 2/5 of total stake, User B has 3/5
        let expected_total_reward_a = (bribe_amount_1 + (bribe_amount_2 * 200 / 500))  * 800 / 1800;
        let expected_total_reward_b = bribe_amount_2 * 2400 / 9000;
        
        let total_reward_a = voting_reward::get_single_reward(user_a_addr, btc_metadata);
        let total_reward_b = voting_reward::get_single_reward(user_b_addr, btc_metadata);
        
        let claimed_a = cabal::get_claimed_voting_reward_amount(user_a_addr, btc_metadata);
        let unclaimed_a = voting_reward::get_unclaimed_voting_reward(user_a_addr, btc_metadata);

        utils::test_with_slack(claimed_a + unclaimed_a, expected_total_reward_a, 1);
        utils::test_with_slack(total_reward_b, expected_total_reward_b, 1);
        // Verify User B can claim their rewards from Cycle 2
        let initial_btc_balance_b = primary_fungible_store::balance(user_b_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_b, btc_metadata);
        let final_btc_balance_b = primary_fungible_store::balance(user_b_addr, btc_metadata);

        utils::test_with_slack(final_btc_balance_b - initial_btc_balance_b, expected_total_reward_b, 1);
    }
  
    // Test LP withdrawal and its effect on rewards across cycles
    #[test(c = @staking_addr, user_a = @0xAAA, bribee = @0xCCC)]
    fun test_lp_withdraw_stake_rewards(c: &signer, user_a: &signer, bribee: &signer) {
        test_setup(c);
        let user_a_addr = signer::address_of(user_a);
        
        // --- Setup: Initialize bribe token ---
        let (_, _, btc_mint) = utils::initialize_coin_for_testing(&account::create_signer_for_test(@initia_std), string::utf8(b"btc"));
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        
        // Set BTC price
        let btc_usd_pair_id = string::utf8(b"btc/usd");
        oracle::set_price(&btc_usd_pair_id, 100_00000000, 1000002, 8);
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);

        // --- Cycle 1: User A stakes LP tokens ---
        let stake_type_index = 1;
        let lp_metadata = coin::metadata(@initia_std, string::utf8(b"uinit_usdc_lp"));
        let cabal_lp_metadata = cabal::get_cabal_token_metadata(stake_type_index);
        
        // User A stakes 500M LP tokens
        let lp_amount_a = 500_000_000_000;
        primary_fungible_store::transfer(c, lp_metadata, user_a_addr, lp_amount_a);
        cabal::mock_stake(user_a, stake_type_index, lp_amount_a);
        utils::increase_block(1, 1);
        
        // Deposit Bribe for Cycle 1
        let bribe_amount_1 = 40_000000;
        coin::mint_to(&btc_mint, signer::address_of(bribee), bribe_amount_1);
        bribe::mock_deposit_bribe(bribee, btc_metadata, bribe_amount_1, 1, 101);
        
        // Take Snapshot & Finalize Cycle 1
        utils::increase_block(1, 1);
        let snapshot_height_1 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, 1, snapshot_height_1);
        
        // --- User A withdraws half their stake ---
        let withdraw_amount = 250_000_000_000; // Withdraw half of their stake
        cabal::mock_unstake(user_a, stake_type_index, withdraw_amount);
        utils::increase_block(1, 1);

        assert!(primary_fungible_store::balance(user_a_addr, cabal_lp_metadata) == lp_amount_a - withdraw_amount,1001);
        
        // --- Cycle 2: User A has reduced stake ---
        // Deposit Bribe for Cycle 2
        let bribe_amount_2 = 60_000000;
        coin::mint_to(&btc_mint, signer::address_of(bribee), bribe_amount_2);
        bribe::mock_deposit_bribe(bribee, btc_metadata, bribe_amount_2, 2, 101);
        
        // Take Snapshot & Finalize Cycle 2
        utils::increase_block(1, 1);
        let snapshot_height_2 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, 2, snapshot_height_2);
        
        // --- Verify Total Rewards ---
        // In Cycle 1, User A had full stake and gets 100% of bribe_amount_1
        // In Cycle 2, User A has reduced stake but still gets 100% of bribe_amount_2 (as they're the only staker)
        let expected_total_reward_a = (bribe_amount_1 + bribe_amount_2) * 800 / 1800;
        let total_reward_a = voting_reward::get_single_reward(user_a_addr, btc_metadata);
        
        utils::test_with_slack(total_reward_a, expected_total_reward_a, 1);
        
        // Verify User A can claim their rewards from both cycles
        let initial_btc_balance_a = primary_fungible_store::balance(user_a_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        let final_btc_balance_a = primary_fungible_store::balance(user_a_addr, btc_metadata);
        
        utils::test_with_slack(final_btc_balance_a - initial_btc_balance_a, expected_total_reward_a, 1);
        assert!(voting_reward::get_unclaimed_voting_reward(user_a_addr, btc_metadata) == 0, 801);
    }

    // Test LP withdrawal and its effect on rewards across cycles
    #[test(c = @staking_addr, user_a = @0xAAA, user_b = @0xBBB, bribee = @0xCCC)]
    fun test_lp_withdraw_multiple_users(c: &signer, user_a: &signer, user_b: &signer, bribee: &signer) {
        test_setup(c);
        cabal::register(user_a);
        cabal::register(user_b);
        cabal::init_fees_exempt(c);
        cabal::set_fees_exempt(c, vector[@0xAAA]);
        let user_a_addr = signer::address_of(user_a);
        let user_b_addr = signer::address_of(user_b);
        
        // --- Setup: Initialize bribe token ---
        let (_, _, btc_mint) = utils::initialize_coin_for_testing(&account::create_signer_for_test(@initia_std), string::utf8(b"btc"));
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        
        // Set BTC price
        let btc_usd_pair_id = string::utf8(b"btc/usd");
        oracle::set_price(&btc_usd_pair_id, 100_00000000, 1000002, 8);
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);

        // --- Cycle 1: User A stakes LP tokens ---
        let stake_type_index = 1;
        let lp_metadata = coin::metadata(@initia_std, string::utf8(b"uinit_usdc_lp"));
        let cabal_lp_metadata = cabal::get_cabal_token_metadata(stake_type_index);
        
        // User A and User B stake 500M LP tokens
        let lp_amount = 500_000_000_000;
        primary_fungible_store::transfer(c, lp_metadata, user_a_addr, lp_amount);
        primary_fungible_store::transfer(c, lp_metadata, user_b_addr, lp_amount);
        cabal::mock_stake(user_a, stake_type_index, lp_amount);
        cabal::mock_stake(user_b, stake_type_index, lp_amount);
        utils::increase_block(1, 1);
        
        // Deposit Bribe for Cycle 1
        let bribe_amount_1 = 40_000000;
        coin::mint_to(&btc_mint, signer::address_of(bribee), bribe_amount_1);
        bribe::mock_deposit_bribe(bribee, btc_metadata, bribe_amount_1, 1, 101);
        
        // Take Snapshot & Finalize Cycle 1
        utils::increase_block(1, 1);
        let snapshot_height_1 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, 1, snapshot_height_1);

        utils::test_with_slack(bribe_amount_1 * 800 / 3600, voting_reward::get_single_reward(user_a_addr, btc_metadata), 1);
        
        // --- User A withdraws half their stake ---
        let withdraw_amount = 250_000_000_000; // Withdraw half of their stake
        cabal::mock_unstake(user_a, stake_type_index, withdraw_amount);
        utils::increase_block(1, 1);
        // Now User A: 250k, User B: 500k
        
        // --- Cycle 2: User A has reduced stake ---
        // Deposit Bribe for Cycle 2
        let bribe_amount_2 = 60_000000;
        coin::mint_to(&btc_mint, signer::address_of(bribee), bribe_amount_2);
        bribe::mock_deposit_bribe(bribee, btc_metadata, bribe_amount_2, 2, 101);
        
        // Take Snapshot & Finalize Cycle 2
        utils::increase_block(1, 1);
        let snapshot_height_2 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, 2, snapshot_height_2);
        
        // --- Verify Total Rewards ---
        // In Cycle 1, User A and User B have an equal stake, they get 50% each
        // In Cycle 2, User A has stake 33.33%, User B has 66.66%
        let expected_total_reward = (bribe_amount_1 + bribe_amount_2) * 800 / 1800;
        let expected_total_reward_a = (bribe_amount_1 * 800 / 3600) + (bribe_amount_2 * 800 / 5400);
        let total_reward_a = voting_reward::get_single_reward(user_a_addr, btc_metadata);
        let total_reward_b = voting_reward::get_single_reward(user_b_addr, btc_metadata);

        // debug::print(&(bribe_amount_1 * 800 / 3600));
        // debug::print(&(bribe_amount_2 * 800 / 1800 /3));
        // debug::print(&string::utf8(b"expected a"));
        // debug::print(&expected_total_reward_a);
        // debug::print(&string::utf8(b"total a"));
        // debug::print(&total_reward_a);
        utils::test_with_slack(total_reward_a, expected_total_reward_a, 1);
        // debug::print(&string::utf8(b"total b"));
        // debug::print(&total_reward_b);
        utils::test_with_slack(expected_total_reward - total_reward_a, total_reward_b, 1);
        
        // Verify User A can claim their rewards from both cycles
        let initial_btc_balance_a = primary_fungible_store::balance(user_a_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        let final_btc_balance_a = primary_fungible_store::balance(user_a_addr, btc_metadata);
        
        utils::test_with_slack(final_btc_balance_a - initial_btc_balance_a, expected_total_reward_a, 1);
        assert!(voting_reward::get_unclaimed_voting_reward(user_a_addr, btc_metadata) == 0, 801);

        //User B still needs to be able to claim their full reward
        assert!(voting_reward::get_unclaimed_voting_reward(user_b_addr, btc_metadata) == total_reward_b, 802);

        //User B claiming
        let initial_btc_balance_b = primary_fungible_store::balance(user_b_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_b, btc_metadata);
        let final_btc_balance_b = primary_fungible_store::balance(user_b_addr, btc_metadata);
        utils::test_with_slack(final_btc_balance_b - initial_btc_balance_b, expected_total_reward - total_reward_a, 1);
        assert!(voting_reward::get_unclaimed_voting_reward(user_b_addr, btc_metadata) == 0, 801);
    }

}
