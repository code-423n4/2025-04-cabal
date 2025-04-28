#[test_only]
module staking_addr::voting_test {
    // Standard Library Imports
    use std::error;
    use std::option;
    use std::signer;
    use std::string::{Self, String};
    use std::vector;

    // Initia Standard Library Imports
    use initia_std::account;
    use initia_std::bigdecimal::{Self, BigDecimal};
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
    use initia_std::block;
    use staking_addr::snapshots; // For advancing time/epochs

    // Local Package Imports (staking_addr)
    use staking_addr::bribe;
    use staking_addr::cabal;
    use staking_addr::cabal_token;
    use staking_addr::emergency;
    use staking_addr::manager;
    use staking_addr::package;
    use staking_addr::pool_router;
    use staking_addr::utils;
    use staking_addr::voting_reward; // The module under test

    // External Dependencies (if needed by voting_reward functions or setup)
    use vip::lock_staking;
    use vip::weight_vote;
    use vip::vip; // Likely needed if interacting with VIP cycles/rewards

    const MINIMUM_LIQUIDITY: u64 = 100_000_000 * 3;

    // Test Setup Function
    fun test_setup(c: &signer, init_validator_address: string::String) {
        // Initialize dependent modules first\
        // Most of this is just taken from core_staking_test.move
        emergency::init_module_for_test(c);
        manager::initialize_for_test(signer::address_of(c)); // Also initializes package.move
        bribe::init_module_for_test(c);
        cabal_token::init_module_for_test(c);
        pool_router::init_module_for_test(c);
        voting_reward::init_module_for_test(c); // Initialize the module under test
        snapshots::init_module_for_test(c); // Initialize the module under test
        utils::increase_block(1, 2);

        assert!(bribe::deposit_voting_reward_fee_bps() == 0, 1);

        // mint tokens
        let (_, _, btc_mint) = utils::initialize_coin_for_testing(&account::create_signer_for_test(@initia_std), string::utf8(b"btc"));
        let (_, _, eth_mint) = utils::initialize_coin_for_testing(&account::create_signer_for_test(@initia_std), string::utf8(b"eth"));

        coin::mint_to(&btc_mint, @0xAAA, 100_000000);
        coin::mint_to(&eth_mint, @0xAAA, 10000_000000);

        coin::mint_to(&btc_mint, @0xBBB, 100_000000);
        coin::mint_to(&eth_mint, @0xBBB, 10000_000000);

        coin::mint_to(&btc_mint, @0xCCC, 100_000000);
        coin::mint_to(&eth_mint, @0xCCC, 10000_000000);

        // set oracle
        let btc_usd_pair_id = string::utf8(b"btc/usd");
        let eth_usd_pair_id = string::utf8(b"eth/usd");

        let btc_price = 100_00000000_u256;
        let eth_price = 10_000000000000000000_u256;

        let btc_updated_at = 1000002;
        let eth_updated_at = 1000001;

        let btc_decimals = 8;
        let eth_decimals = 18;

        oracle::set_price(
            &btc_usd_pair_id,
            btc_price,
            btc_updated_at,
            btc_decimals
        );
        oracle::set_price(
            &eth_usd_pair_id,
            eth_price,
            eth_updated_at,
            eth_decimals
        );
        // Initialize VIP mock/dependency if needed
        let vip_signer = &account::create_signer_for_test(@vip);
        lock_staking::init_module_for_test(vip_signer);

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
        assert!(vector::length(&pools_setup) == 1, 2);
        let init_pool_obj_addr_setup = pools_setup[0];
        let init_pool_obj_setup = object::address_to_object<pool_router::StakePool>(init_pool_obj_addr_setup);

        // Manually trigger delegate for the initial minimum liquidity deposit
        // pool_router::mock_trigger_delegate_init(init_pool_obj_setup, MINIMUM_LIQUIDITY);
        utils::increase_block(1, 1);

        //Now that everything here is set up, we mint init to user a and have him do INIT-xINIT-sxINIT
        // --- Setup @0xAAA for bribe rewards ---
        // 1. Get signer for @0xAAA
        let aaa_signer = &account::create_signer_for_test(@0xAAA);
        let aaa_addr = signer::address_of(aaa_signer);

        // 2. Mint INIT to @0xAAA (needs primary fungible store)
        let init_amount_to_mint = 1_000_000_000_000; // 1 million INIT
        coin::mint_to(&mint_cap, aaa_addr, init_amount_to_mint);
        assert!(primary_fungible_store::balance(aaa_addr, init_metadata_setup) == init_amount_to_mint, 3);

        // 3. @0xAAA deposits INIT for xINIT
        let init_to_deposit = 500_000_000_000; // 500k INIT
        cabal::mock_deposit_init_for_xinit(aaa_signer, init_to_deposit);

        // 4. @0xAAA stakes xINIT for sxINIT using mock_stake
        let xinit_metadata = cabal::get_xinit_metadata();
        let sxinit_metadata = cabal::get_sxinit_metadata();
        let xinit_balance_aaa = primary_fungible_store::balance(aaa_addr, xinit_metadata);
        assert!(xinit_balance_aaa == init_to_deposit, 4);

        // debug::print(&option::extract(&mut fungible_asset::supply(sxinit_metadata)));
        assert!(primary_fungible_store::balance(aaa_addr, sxinit_metadata) == 0, 5);
        cabal::mock_stake(aaa_signer, 0, xinit_balance_aaa); // 0 for xINIT

        // check that stuff worked
        assert!(primary_fungible_store::balance(aaa_addr, sxinit_metadata) == xinit_balance_aaa, 6);
    }

    fun test_setup_no_stake(c: &signer, init_validator_address: string::String) {
        // Initialize dependent modules first\
        // Most of this is just taken from core_staking_test.move
        emergency::init_module_for_test(c);
        manager::initialize_for_test(signer::address_of(c)); // Also initializes package.move
        bribe::init_module_for_test(c);
        cabal_token::init_module_for_test(c);
        pool_router::init_module_for_test(c);
        voting_reward::init_module_for_test(c); // Initialize the module under test
        snapshots::init_module_for_test(c); // Initialize the module under test
        utils::increase_block(1, 2);

        assert!(bribe::deposit_voting_reward_fee_bps() == 0, 1);

        // mint tokens
        let (_, _, btc_mint) = utils::initialize_coin_for_testing(&account::create_signer_for_test(@initia_std), string::utf8(b"btc"));
        let (_, _, eth_mint) = utils::initialize_coin_for_testing(&account::create_signer_for_test(@initia_std), string::utf8(b"eth"));

        coin::mint_to(&btc_mint, @0xAAA, 100_000000);
        coin::mint_to(&eth_mint, @0xAAA, 10000_000000);

        coin::mint_to(&btc_mint, @0xBBB, 100_000000);
        coin::mint_to(&eth_mint, @0xBBB, 10000_000000);

        coin::mint_to(&btc_mint, @0xCCC, 100_000000);
        coin::mint_to(&eth_mint, @0xCCC, 10000_000000);

        // set oracle
        let btc_usd_pair_id = string::utf8(b"btc/usd");
        let eth_usd_pair_id = string::utf8(b"eth/usd");

        let btc_price = 100_00000000_u256;
        let eth_price = 10_000000000000000000_u256;

        let btc_updated_at = 1000002;
        let eth_updated_at = 1000001;

        let btc_decimals = 8;
        let eth_decimals = 18;

        oracle::set_price(
            &btc_usd_pair_id,
            btc_price,
            btc_updated_at,
            btc_decimals
        );
        oracle::set_price(
            &eth_usd_pair_id,
            eth_price,
            eth_updated_at,
            eth_decimals
        );
        // Initialize VIP mock/dependency if needed
        let vip_signer = &account::create_signer_for_test(@vip);
        lock_staking::init_module_for_test(vip_signer);

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
        assert!(vector::length(&pools_setup) == 1, 2);
        let init_pool_obj_addr_setup = pools_setup[0];
        let init_pool_obj_setup = object::address_to_object<pool_router::StakePool>(init_pool_obj_addr_setup);

        // Manually trigger delegate for the initial minimum liquidity deposit
        // pool_router::mock_trigger_delegate_init(init_pool_obj_setup, MINIMUM_LIQUIDITY);
        utils::increase_block(1, 1);
    }

    #[test(c = @staking_addr)]
    fun test_setup_verification(c: &signer) {
        test_setup(c, string::utf8(b"validator123"));
        // Add more specific checks if needed, e.g., check initial manager state, etc.
        // The existing setup already has several assertions.
        assert!(manager::is_authorized(c), 1001); // Verify deployer is manager
        assert!(bribe::deposit_voting_reward_fee_bps() == 0, 1002); // Verify initial fee
        // Check if xINIT and sxINIT metadata exist
        let _ = cabal::get_xinit_metadata();
        let _ = cabal::get_sxinit_metadata();
        // Check if user AAA has sxINIT after setup
        let aaa_addr = @0xAAA;
        let sxinit_metadata = cabal::get_sxinit_metadata();
        assert!(primary_fungible_store::balance(aaa_addr, sxinit_metadata) > 0, 1003);
    }

    // check that in the beginning, the values are all initialized correctly
    #[test(c = @staking_addr)]
    fun test_initial_state(c: &signer) {
        test_setup(c, string::utf8(b"validator123"));

        let aaa_addr = @0xAAA;
        let bbb_addr = @0xBBB;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));

        // Check initial reward states are zero/empty
        assert!(bigdecimal::eq(voting_reward::get_total_reward_in_usd(aaa_addr), bigdecimal::zero()), 2001);
        assert!(simple_map::length(&voting_reward::get_total_reward(aaa_addr)) == 0, 2002);
        assert!(voting_reward::get_single_reward(aaa_addr, btc_metadata) == 0, 2003);

        assert!(bigdecimal::eq(voting_reward::get_total_reward_in_usd(bbb_addr), bigdecimal::zero()), 2004);
        assert!(simple_map::length(&voting_reward::get_total_reward(bbb_addr)) == 0, 2005);
        assert!(voting_reward::get_single_reward(bbb_addr, btc_metadata) == 0, 2006);

         // Check internal state using getters
        assert!(voting_reward::get_finalized_cycles_count() == 0, 2007);
        assert!(snapshots::is_snapshots_empty(), 2008);
    }

    // only authorized wallet can create snapshots
    #[test(c = @staking_addr, non_manager = @0xDDD)]
    #[expected_failure(location= staking_addr::voting_reward, abort_code = 0x50005)] //error::permission_denied: 0x50000, EUNAUTHORIZED: 0x5
    fun test_snapshot_unauthorized(c: &signer, non_manager: &signer) {
        test_setup(c, string::utf8(b"validator123"));
        // Attempt snapshot with a non-manager account
        voting_reward::snapshot(non_manager); // Should fail
    }

    // simple snapshot test
    #[test(c = @staking_addr)]
    fun test_snapshot_success(c: &signer) {
        test_setup(c, string::utf8(b"validator123"));
        let aaa_addr = @0xAAA;
        let sxinit_metadata = cabal::get_sxinit_metadata();
        let initial_sxinit_supply = option::get_with_default(&coin::supply(sxinit_metadata), 0);
        let initial_aaa_sxinit_balance = primary_fungible_store::balance(aaa_addr, sxinit_metadata);
        assert!(initial_sxinit_supply > 0, 3001);
        assert!(initial_aaa_sxinit_balance > 0, 3002);

        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c); // Use mock as we don't have VIP setup fully

        // Verify snapshot table entry
         assert!(snapshots::has_snapshot_at(snapshot_height), 3003);


        let weight = snapshots::get_snapshot_weight(snapshot_height, utils::get_init_metadata());
        let supply = cabal_token::get_snapshot_supply(sxinit_metadata, snapshot_height);
        assert!(supply == initial_sxinit_supply, 3004);
        assert!(bigdecimal::eq(weight, bigdecimal::from_u64(1)), 3005);

        // Verify cabal_token snapshot was called (check user balance snapshot)
        let snapshot_balance = cabal_token::get_snapshot_balance(aaa_addr, sxinit_metadata, snapshot_height);
        assert!(snapshot_balance == initial_aaa_sxinit_balance, 3006);
    }

    // snapshot before stake, with block difference
    #[test(c = @staking_addr, user_d = @0xDDD)]
    fun test_snapshot_timing_before_stake(c: &signer, user_d: &signer) {
        // Basic setup without the automatic AAA staking
        emergency::init_module_for_test(c);
        manager::initialize_for_test(signer::address_of(c));
        bribe::init_module_for_test(c);
        cabal_token::init_module_for_test(c);
        pool_router::init_module_for_test(c);
        voting_reward::init_module_for_test(c);
        snapshots::init_module_for_test(c);
        utils::increase_block(1, 2);

        let vip_signer = &account::create_signer_for_test(@vip);
        lock_staking::init_module_for_test(vip_signer);
        let initia_signer = &account::create_signer_for_test(@initia_std);
        let (mint_cap, _, _) = coin::initialize(
            initia_signer,
            option::none(),
            string::utf8(b"init token"),
            string::utf8(b"uinit"),
            6, // decimals
            string::utf8(b""),
            string::utf8(b"")
        );
        coin::mint_to(&mint_cap, signer::address_of(c), 1_000_000_000_000_000);
        cabal::initialize(c, string::utf8(b"validator123"), signer::address_of(c));
        // Mint INIT to user D

        let init_amount_to_mint = 1_000_000_000_000;
        coin::mint_to(&mint_cap, @0xDDD, init_amount_to_mint);

        // Snapshot *before* user D stakes
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);

        // User D deposits and stakes
        let init_to_deposit = 500_000_000_000;
        cabal::mock_deposit_init_for_xinit(user_d, init_to_deposit);
        let xinit_metadata = cabal::get_xinit_metadata();
        let xinit_balance_d = primary_fungible_store::balance(@0xDDD, xinit_metadata);
        cabal::mock_stake(user_d, 0, xinit_balance_d); // Stake xINIT

        // After snapshot and staking, verify using getters
        let sxinit_metadata = cabal::get_sxinit_metadata();

        let supply = cabal_token::get_snapshot_supply(sxinit_metadata, snapshot_height);
        assert!(supply == 100_000_000, 4001); // Supply should be cabal::MINIMUM_LIQUIDITY
        
        // User D's snapshot balance should be 0
        let snapshot_balance_d = cabal_token::get_snapshot_balance(@0xDDD, sxinit_metadata, snapshot_height);
        // debug::print(&snapshot_balance_d);
        assert!(snapshot_balance_d == 0, 4002); // cabal::MINIMUM_LIQUIDITY 
    }

    // snapshot and stake in same block, but snapshot before, should ignore the stake 
    #[test(c = @staking_addr, user_d = @0xDDD)]
    fun test_snapshot_same_block_before_stake(c: &signer, user_d: &signer) {
        // Basic setup without the automatic AAA staking
        emergency::init_module_for_test(c);
        manager::initialize_for_test(signer::address_of(c));
        bribe::init_module_for_test(c);
        cabal_token::init_module_for_test(c);
        pool_router::init_module_for_test(c);
        voting_reward::init_module_for_test(c);
        snapshots::init_module_for_test(c);
        utils::increase_block(1, 2);

        let vip_signer = &account::create_signer_for_test(@vip);
        lock_staking::init_module_for_test(vip_signer);
        let initia_signer = &account::create_signer_for_test(@initia_std);
        let (mint_cap, _, _) = coin::initialize(
            initia_signer,
            option::none(),
            string::utf8(b"init token"),
            string::utf8(b"uinit"),
            6, // decimals
            string::utf8(b""),
            string::utf8(b"")
        );
        coin::mint_to(&mint_cap, signer::address_of(c), 1_000_000_000_000_000);
        cabal::initialize(c, string::utf8(b"validator123"), signer::address_of(c));
        // Mint INIT to user D

        let init_amount_to_mint = 1_000_000_000_000;
        coin::mint_to(&mint_cap, @0xDDD, init_amount_to_mint);

        // Snapshot *before* user D stakes
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);

        // User D deposits and stakes
        let init_to_deposit = 500_000_000_000;
        cabal::mock_deposit_init_for_xinit(user_d, init_to_deposit);
        let xinit_metadata = cabal::get_xinit_metadata();
        let xinit_balance_d = primary_fungible_store::balance(@0xDDD, xinit_metadata);
        cabal::mock_stake(user_d, 0, xinit_balance_d); // Stake xINIT
        let sxinit_metadata = cabal::get_sxinit_metadata();
        let sxinit_balance_d = primary_fungible_store::balance(@0xDDD, sxinit_metadata);

        // After snapshot and staking, verify using getters
        let sxinit_metadata = cabal::get_sxinit_metadata();
        let supply = cabal_token::get_snapshot_supply(sxinit_metadata, snapshot_height);
        assert!(supply == ((100_000_000 + sxinit_balance_d) as u128), 5001); // Supply should be cabal::MINIMUM_LIQUIDITY
        
        let snapshot_balance_d = cabal_token::get_snapshot_balance(@0xDDD, sxinit_metadata, snapshot_height);
        //debug::print(&snapshot_balance_d);
        assert!(snapshot_balance_d == sxinit_balance_d, 5002);
        //TODO: what is going on here now? Are we creating a consistent snapshot, but with the sync point after a block? This would explain line 350
    }
    
    //Simple bribing then snapshot to see the reward distribution
    public fun test_bribe_and_reward_flow(c: &signer, user_b: &signer) {
        // Setup the test environment with test validator address
        test_setup(c, string::utf8(b"validator123"));
        
        // Get signer for user A (who will receive rewards)
        let user_a = &account::create_signer_for_test(@0xAAA);
        
        // Get BTC metadata and set it as an allowed bribe token
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);
        
        // Define cycle and bridge ID
        let cycle = 1;
        let bridge_id = 101;
        let bribe_amount = 50_000000; // 50 BTC
        
        // Check initial BTC balance of user A
        let initial_balance_a = primary_fungible_store::balance(@0xAAA, btc_metadata);
        
        // User B deposits a BTC bribe for the specified cycle and bridge
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount, cycle, bridge_id);
        
        // Verify the bribe was recorded correctly
        let bribes = bribe::get_total_bribes_by_token_for_cycle(cycle);
        assert!(simple_map::contains_key(&bribes, &btc_metadata), 6001);
        let recorded_amount = *simple_map::borrow(&bribes, &btc_metadata);
        assert!(recorded_amount == bribe_amount, 6002);
        
        // Calculate weights to ensure the bridge has weight
        let weights = bribe::calculate_bribe_weights_for_cycle(cycle);
        assert!(vector::length(&weights) == 1, 6003);
        assert!(bribe::get_bridge_reward_response_bridge_id(&weights[0]) == bridge_id, 6004);
        
        // Snapshot the current state for reward calculation
        utils::increase_block(1, 1);
        voting_reward::mock_snapshot(c);
        
        // Finalize the reward cycle
        let current_height = block::get_current_block_height();
        voting_reward::finalize_reward_cycle(c, cycle, current_height);
        
        // Check that user A has pending rewards
        let pending_reward = voting_reward::get_single_reward(@0xAAA, btc_metadata);
        //debug::print(&pending_reward);
        assert!(pending_reward > 0, 6005);
        
        // User A claims their rewards
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        
        // Verify user A's balance increased by approximately the pending reward amount
        // Since user A is the only staker, they should receive almost the full bribe amount
        let final_balance_a = primary_fungible_store::balance(@0xAAA, btc_metadata);
        assert!(final_balance_a > initial_balance_a, 6006);
        
        // The received amount should be close to the pending reward we checked earlier
        let received_amount = final_balance_a - initial_balance_a;
        //debug::print(&received_amount);
        assert!(received_amount >= pending_reward * 99 / 100, 6007); // Allow for small rounding differences
        utils::test_with_slack(received_amount, bribe_amount, 1);
    }

    // snapshot and stake in same block, but snapshot after, should inlcude stake
    #[test(c = @staking_addr, user_d = @0xDDD)]
    fun test_snapshot_same_block_after_stake(c: &signer, user_d: &signer) {
        // Basic setup without the automatic AAA staking
        emergency::init_module_for_test(c);
        manager::initialize_for_test(signer::address_of(c));
        bribe::init_module_for_test(c);
        cabal_token::init_module_for_test(c);
        pool_router::init_module_for_test(c);
        voting_reward::init_module_for_test(c);
        snapshots::init_module_for_test(c);
        utils::increase_block(1, 2);

        let vip_signer = &account::create_signer_for_test(@vip);
        lock_staking::init_module_for_test(vip_signer);
        let initia_signer = &account::create_signer_for_test(@initia_std);
        let (mint_cap, _, _) = coin::initialize(
            initia_signer,
            option::none(),
            string::utf8(b"init token"),
            string::utf8(b"uinit"),
            6, // decimals
            string::utf8(b""),
            string::utf8(b"")
        );
        coin::mint_to(&mint_cap, signer::address_of(c), 1_000_000_000_000_000);
        cabal::initialize(c, string::utf8(b"validator123"), signer::address_of(c));
        // Mint INIT to user D

        let init_amount_to_mint = 1_000_000_000_000;
        coin::mint_to(&mint_cap, @0xDDD, init_amount_to_mint);

        utils::increase_block(1, 1);

        // User D deposits and stakes
        let init_to_deposit = 500_000_000_000;
        cabal::mock_deposit_init_for_xinit(user_d, init_to_deposit);
        let xinit_metadata = cabal::get_xinit_metadata();
        let xinit_balance_d = primary_fungible_store::balance(@0xDDD, xinit_metadata);
        cabal::mock_stake(user_d, 0, xinit_balance_d); // Stake xINIT
        let sxinit_metadata = cabal::get_sxinit_metadata();
        let sxinit_balance_d = primary_fungible_store::balance(@0xDDD, sxinit_metadata);

        // Snapshot *before* user D stakes
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);

        // After snapshot and staking, verify using getters
        let sxinit_metadata = cabal::get_sxinit_metadata();
        let supply = cabal_token::get_snapshot_supply(sxinit_metadata, snapshot_height);
        assert!(supply == ((100_000_000 + sxinit_balance_d) as u128), 7001);
        
        let snapshot_balance_d = cabal_token::get_snapshot_balance(@0xDDD, sxinit_metadata, snapshot_height);
        //debug::print(&snapshot_balance_d);
        assert!(snapshot_balance_d == sxinit_balance_d, 7002);
    }

     // III. Finalizing Cycles (`finalize_reward_cycle`)
    #[test(c = @staking_addr, non_manager = @0xDDD)]
    #[expected_failure(location= staking_addr::voting_reward, abort_code=0x50005)]// error::permission_denied: 0x50000, EUNAUTHORIZED: 0x5
    fun test_finalize_unauthorized(c: &signer, non_manager: &signer) {
        test_setup(c, string::utf8(b"validator123"));
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        let cycle = 1;
        // Attempt finalize with non-manager
        voting_reward::finalize_reward_cycle(non_manager, cycle, snapshot_height); // Should fail
    }

    // testing that finalizing a cycle while emergency paused fails
    #[test(c = @staking_addr)]
    #[expected_failure(location = staking_addr::emergency, abort_code = 0x30002)]//error::invalid_state: 0x30000, EPAUSED: 0x2
    fun test_finalize_paused(c: &signer) {
        test_setup(c, string::utf8(b"validator123"));
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        let cycle = 1;

        // Pause the system
        emergency::set_pause(c, true);
        assert!(emergency::paused(), 8001);

        // Attempt finalize while paused - should fail
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);
    }

     // Test snapshot -> pause -> unpause -> finalize
    #[test(c = @staking_addr)]
    fun test_finalize_unpaused(c: &signer) {
        test_setup(c, string::utf8(b"validator123"));
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        let cycle = 1;

        emergency::set_pause(c, true);
        assert!(emergency::paused(), 9001);
        emergency::set_pause(c, false);
        assert!(!emergency::paused(), 9002);

        // Finalize should now succeed
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);
        assert!(snapshots::has_snapshot_at(snapshot_height), 9003);
    }

    // should not be able to finalize twice
    #[test(c = @staking_addr)]
    #[expected_failure(location = staking_addr::voting_reward, abort_code = 0x10004)]//error::invalid_argument: 0x10000 EINVALID_CYCLE: 0x4
    fun test_finalize_cycle_twice(c: &signer) {
        test_setup(c, string::utf8(b"validator123"));
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        let cycle = 1;

        // Finalize cycle 1 successfully
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);
        assert!(snapshots::has_snapshot_at(snapshot_height), 1101);

        // Attempt to finalize cycle 1 again - should fail
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);
    }

    //finalize multiple cycles
    #[test(c = @staking_addr)]
    fun test_finalize_success(c: &signer) {
        test_setup(c, string::utf8(b"validator123"));
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        let cycle = 1;

        // Finalize cycle 1
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // Verify cycle_snapshot_map update
        assert!(snapshots::has_snapshot_at(snapshot_height), 1201);

        // Finalize another cycle
        utils::increase_block(1, 1);
        let snapshot_height_2 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        let cycle_2 = 2;
        voting_reward::finalize_reward_cycle(c, cycle_2, snapshot_height_2);

        assert!(snapshots::has_snapshot_at(snapshot_height_2), 1202);
    }

     // IV. Bribing & Reward Calculation (Single User, Single Bribe Token)
    // test reward cycle, where there have been no bribes
    #[test(c = @staking_addr)]
    fun test_reward_no_bribes(c: &signer) {
        test_setup(c, string::utf8(b"validator123")); // User AAA is staked
        let aaa_addr = @0xAAA;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let cycle = 1;

        // Snapshot and finalize without any bribes
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1); // Ensure finalize is in a later block
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // Verify zero rewards
        assert!(voting_reward::get_single_reward(aaa_addr, btc_metadata) == 0, 1301);
        assert!(simple_map::length(&voting_reward::get_total_reward(aaa_addr)) == 0, 1302);
        assert!(bigdecimal::eq(voting_reward::get_total_reward_in_usd(aaa_addr), bigdecimal::zero()), 1303);
    }

     // reward_cycle where noone stakes
    #[test(c = @staking_addr, user_b = @0xBBB, user_d = @0xDDD)]
    fun test_reward_no_stake(c: &signer, user_b: &signer, user_d: &signer) {
        // Basic setup without automatic AAA staking
        // Basic setup without the automatic AAA staking
        emergency::init_module_for_test(c);
        manager::initialize_for_test(signer::address_of(c));
        bribe::init_module_for_test(c);
        cabal_token::init_module_for_test(c);
        pool_router::init_module_for_test(c);
        voting_reward::init_module_for_test(c);
        snapshots::init_module_for_test(c);
        utils::increase_block(1, 2);

        let vip_signer = &account::create_signer_for_test(@vip);
        lock_staking::init_module_for_test(vip_signer);
        let initia_signer = &account::create_signer_for_test(@initia_std);
        let (mint_cap, _, _) = coin::initialize(
            initia_signer,
            option::none(),
            string::utf8(b"init token"),
            string::utf8(b"uinit"),
            6, // decimals
            string::utf8(b""),
            string::utf8(b"")
        );
        coin::mint_to(&mint_cap, signer::address_of(c), 1_000_000_000_000_000);
        cabal::initialize(c, string::utf8(b"validator123"), signer::address_of(c));
        // Mint bribe token
        let (_, _, btc_mint) = utils::initialize_coin_for_testing(&account::create_signer_for_test(@initia_std), string::utf8(b"btc"));
        coin::mint_to(&btc_mint, @0xBBB, 100_000000); // Mint BTC to User B (bribee)
        coin::mint_to(&btc_mint, @0xDDD, 100_000000); // Mint BTC to User D (potential claimant, but won't stake)


        let btc_usd_pair_id = string::utf8(b"btc/usd");
        let eth_usd_pair_id = string::utf8(b"eth/usd");

        let btc_price = 100_00000000_u256;
        let eth_price = 10_000000000000000000_u256;

        let btc_updated_at = 1000002;
        let eth_updated_at = 1000001;

        let btc_decimals = 8;
        let eth_decimals = 18;

        oracle::set_price(
            &btc_usd_pair_id,
            btc_price,
            btc_updated_at,
            btc_decimals
        );
        oracle::set_price(
            &eth_usd_pair_id,
            eth_price,
            eth_updated_at,
            eth_decimals
        );

        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);

        let cycle = 1;
        let bridge_id = 101;
        let bribe_amount = 50_000000; // 50 BTC

        // User B deposits bribe
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount, cycle, bridge_id);

        // Snapshot and finalize (User D has no stake)
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // Verify all users get zero rewards
        let aaa_addr = @0xAAA;
        let bbb_addr = @0xBBB;
        let ccc_addr = @0xCCC;
        let ddd_addr = @0xDDD;

        assert!(voting_reward::get_single_reward(aaa_addr, btc_metadata) == 0, 1401);
        assert!(bigdecimal::eq(voting_reward::get_total_reward_in_usd(aaa_addr), bigdecimal::zero()), 1402);

        assert!(voting_reward::get_single_reward(bbb_addr, btc_metadata) == 0, 1401);
        assert!(bigdecimal::eq(voting_reward::get_total_reward_in_usd(bbb_addr), bigdecimal::zero()), 1402);

        assert!(voting_reward::get_single_reward(ccc_addr, btc_metadata) == 0, 1401);
        assert!(bigdecimal::eq(voting_reward::get_total_reward_in_usd(ccc_addr), bigdecimal::zero()), 1402);

        assert!(voting_reward::get_single_reward(ddd_addr, btc_metadata) == 0, 1401);
        assert!(bigdecimal::eq(voting_reward::get_total_reward_in_usd(ddd_addr), bigdecimal::zero()), 1402);
    }

     // test that if only one user stakes, they get the full reward share
    #[test(c=@staking_addr, user_b=@0xBBB)]
    public fun test_reward_single_user_full_share_claim(c: &signer, user_b: &signer) {
        // Setup the test environment with test validator address
        test_setup(c, string::utf8(b"validator123")); // User AAA is staked

        // Get signer for user A (who will receive rewards)
        let user_a = &account::create_signer_for_test(@0xAAA);
        let aaa_addr = signer::address_of(user_a);

        // Get BTC metadata and set it as an allowed bribe token
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);

        // Define cycle and bridge ID
        let cycle = 1;
        let bridge_id = 101;
        let bribe_amount = 50_000000; // 50 BTC

        // User B deposits a BTC bribe for the specified cycle and bridge
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount, cycle, bridge_id);
        utils::increase_block(1, 1); // Ensure bribe is in a previous block

        // Snapshot the current state for reward calculation
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1); // Ensure finalize is in a later block

        // Finalize the reward cycle
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // Check that user A has pending rewards approximately equal to the bribe
        let pending_reward = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        // debug::print(&string::utf8(b"Pending Reward (Full Share):"));
        // debug::print(&pending_reward);
        assert!(pending_reward > 0, 1501);
        // Since AAA is the only staker, they get the full share (allow tiny slack for potential future fees/rounding)
        utils::test_with_slack(pending_reward, bribe_amount, 1); // 0.1% slack

        // Check total rewards view functions
        let total_rewards = voting_reward::get_total_reward(aaa_addr);
        assert!(simple_map::length(&total_rewards) == 1, 1502);
        assert!(simple_map::contains_key(&total_rewards, &btc_metadata), 1503);
        assert!(*simple_map::borrow(&total_rewards, &btc_metadata) == pending_reward, 1504);

        // Check USD value (requires oracle setup from test_setup)
        let total_usd = voting_reward::get_total_reward_in_usd(aaa_addr);
        let expected_usd = utils::get_token_value_in_usd(btc_metadata, pending_reward);
        // debug::print(&string::utf8(b"Total USD Reward:"));
        // debug::print(&total_usd);
        assert!(bigdecimal::eq(total_usd, expected_usd), 1505); // Should be equal given oracle price

        // --- Claiming part (from original test) ---
        let initial_balance_a = primary_fungible_store::balance(aaa_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        let final_balance_a = primary_fungible_store::balance(aaa_addr, btc_metadata);
        assert!(final_balance_a > initial_balance_a, 1506);
        let received_amount = final_balance_a - initial_balance_a;
        // debug::print(&string::utf8(b"Received Amount:"));
        // debug::print(&received_amount);
        assert!(received_amount == pending_reward, 1507); // Should receive exactly the calculated pending reward
    }

     // block1: snapshot , block2: bribe, block3: finalize with snapshot from block1
     //TODO: check a lot more with what bribes would be allowed, very very important
    #[test(c=@staking_addr, user_b=@0xBBB)]
    fun test_reward_timing_bribe_after_snapshot(c: &signer, user_b: &signer) {
        test_setup(c, string::utf8(b"validator123")); // User AAA staked
        let aaa_addr = @0xAAA;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);
        let cycle = 1;
        let bridge_id = 101;
        let bribe_amount = 50_000000;

        // Snapshot *before* bribe
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);

        // Bribe *after* snapshot, but for the same cycle
        utils::increase_block(1, 1);
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount, cycle, bridge_id);

        // Finalize the cycle using the earlier snapshot height
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // Verify reward is calculated correctly, as bribe lookup uses cycle number
        let pending_reward = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        utils::test_with_slack(pending_reward, bribe_amount, 1);
    }

    //block1: bribe, block2: snapshot, block3: stake, block4: finalize on snapshot of 2
    // expected behavior is that user gets no reward
    //TODO: Is this wanted? 
    #[test(c = @staking_addr, user_a = @0xAAA, user_b = @0xBBB)]
    fun test_reward_timing_stake_after_snapshot(c: &signer, user_a: &signer, user_b: &signer) {
        test_setup_no_stake(c, string::utf8(b"validator123"));

        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);

        let cycle = 1;
        let bridge_id = 101;
        let bribe_amount = 50_000000;

        // User A deposits bribe
        bribe::mock_deposit_bribe(user_a, btc_metadata, bribe_amount, cycle, bridge_id);

        // Snapshot *before* User B stakes
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);

        // User B stakes *after* snapshot
        utils::increase_block(1, 1);
        let init_to_deposit = 500_000_000_000;
        let init_metadata = coin::metadata(@initia_std, string::utf8(b"uinit"));
        primary_fungible_store::transfer(c, init_metadata, @0xBBB, init_to_deposit);
        cabal::mock_deposit_init_for_xinit(user_b, init_to_deposit);
        let xinit_metadata = cabal::get_xinit_metadata();
        let xinit_balance_b = primary_fungible_store::balance(@0xBBB, xinit_metadata);
        assert!(xinit_balance_b == init_to_deposit, 1601);
        cabal::mock_stake(user_b, 0, xinit_balance_b); // Stake xINIT

        // Finalize cycle using the earlier snapshot
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // Verify User B gets zero reward for this cycle as they weren't staked at snapshot time
        let bbb_addr = @0xBBB;
        let pending_reward = voting_reward::get_single_reward(bbb_addr, btc_metadata);
        // debug::print(&string::utf8(b"Pending Reward (Stake After Snapshot):"));
        // debug::print(&pending_reward);
        assert!(pending_reward == 0, 1602);
    }

    // single user, multiple bribing tokens
    #[test(c=@staking_addr, user_b=@0xBBB)]
    fun test_reward_multiple_bribe_tokens(c: &signer, user_b: &signer) {
        test_setup(c, string::utf8(b"validator123")); // User AAA staked
        let aaa_addr = @0xAAA;
        let user_a = &account::create_signer_for_test(@0xAAA);

        // Get metadata for bribe tokens (BTC, ETH)
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let eth_metadata = coin::metadata(@initia_std, string::utf8(b"eth"));
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata, eth_metadata]);

        let cycle = 1;
        let bridge_id = 101;
        let btc_bribe_amount = 50_000000; // 50 BTC
        let eth_bribe_amount = 10_000000; // 10 ETH

        // User B deposits bribes
        bribe::mock_deposit_bribe(user_b, btc_metadata, btc_bribe_amount, cycle, bridge_id);
        utils::increase_block(1, 1);
        bribe::mock_deposit_bribe(user_b, eth_metadata, eth_bribe_amount, cycle, bridge_id);
        utils::increase_block(1, 1);

        // Snapshot and finalize
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // Verify rewards per token
        let pending_btc = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        let pending_eth = voting_reward::get_single_reward(aaa_addr, eth_metadata);
        // debug::print(&string::utf8(b"Pending BTC:")); debug::print(&pending_btc);
        // debug::print(&string::utf8(b"Pending ETH:")); debug::print(&pending_eth);
        utils::test_with_slack(pending_btc, btc_bribe_amount, 1);
        utils::test_with_slack(pending_eth, eth_bribe_amount, 1);

        // Verify total rewards map
        let total_rewards = voting_reward::get_total_reward(aaa_addr);
        assert!(simple_map::length(&total_rewards) == 2, 1701);
        assert!(*simple_map::borrow(&total_rewards, &btc_metadata) == pending_btc, 1702);
        assert!(*simple_map::borrow(&total_rewards, &eth_metadata) == pending_eth, 1703);

        // Verify total USD value
        let total_usd = voting_reward::get_total_reward_in_usd(aaa_addr);
        let expected_btc_usd = utils::get_token_value_in_usd(btc_metadata, pending_btc);
        let expected_eth_usd = utils::get_token_value_in_usd(eth_metadata, pending_eth);
        let expected_total_usd = bigdecimal::add(expected_btc_usd, expected_eth_usd);
        // debug::print(&string::utf8(b"Total USD (Multi-Bribe):")); debug::print(&total_usd);
        // Use slack due to potential BigDecimal precision differences in summation vs individual calc
        let tolerance = bigdecimal::div(expected_total_usd, bigdecimal::from_u64(1000)); // 0.1% tolerance
        assert!(bigdecimal::le(bigdecimal::sub(total_usd, expected_total_usd), tolerance) || bigdecimal::le(bigdecimal::sub(expected_total_usd, total_usd), tolerance), 1704);

        // Claim both rewards
        let initial_btc_a = primary_fungible_store::balance(aaa_addr, btc_metadata);
        let initial_eth_a = primary_fungible_store::balance(aaa_addr, eth_metadata);
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        voting_reward::claim_voting_reward(user_a, eth_metadata);
        let final_btc_a = primary_fungible_store::balance(aaa_addr, btc_metadata);
        let final_eth_a = primary_fungible_store::balance(aaa_addr, eth_metadata);
        assert!(final_btc_a - initial_btc_a == pending_btc, 1705);
        assert!(final_eth_a - initial_eth_a == pending_eth, 1706);
    }

     // V. Reward Calculation (Multiple Users)
    // Helper function to setup multiple stakers (AAA and DDD)
    fun setup_multiple_stakers(c: &signer, user_a: &signer, user_d: &signer, stake_amount_a: u64, stake_amount_d: u64) {
         // Basic setup
        emergency::init_module_for_test(c);
        manager::initialize_for_test(signer::address_of(c)); // Also initializes package.move
        bribe::init_module_for_test(c);
        cabal_token::init_module_for_test(c);
        pool_router::init_module_for_test(c);
        voting_reward::init_module_for_test(c); // Initialize the module under test
        snapshots::init_module_for_test(c); // Initialize the module under test
        utils::increase_block(1, 2);

        assert!(bribe::deposit_voting_reward_fee_bps() == 0, 1);

        // Initialize VIP mock/dependency if needed
        let vip_signer = &account::create_signer_for_test(@vip);
        lock_staking::init_module_for_test(vip_signer);

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
        cabal::initialize(c, string::utf8(b"validator123"), signer::address_of(c)); // Use 'c' as commission addr for simplicity


        // Mint INIT to users A and D
        let init_metadata = coin::metadata(@initia_std, string::utf8(b"uinit"));
        if (stake_amount_a > 0) {
            coin::mint_to(&mint_cap, signer::address_of(user_a), stake_amount_a);
            assert!(primary_fungible_store::balance(signer::address_of(user_a), init_metadata) == stake_amount_a, 1801);
        };
        if (stake_amount_d > 0) {
            coin::mint_to(&mint_cap, signer::address_of(user_d), stake_amount_d);
            assert!(primary_fungible_store::balance(signer::address_of(user_d), init_metadata) == stake_amount_d, 1802);
        };
        
        
        utils::increase_block(1,1);

        // Mint bribe tokens (BTC)
        let (_, _, btc_mint) = utils::initialize_coin_for_testing(&account::create_signer_for_test(@initia_std), string::utf8(b"btc"));
        let (_, _, eth_mint) = utils::initialize_coin_for_testing(&account::create_signer_for_test(@initia_std), string::utf8(b"eth"));
        coin::mint_to(&btc_mint, @0xBBB, 200_000000); // Bribee needs enough
        coin::mint_to(&eth_mint, @0xBBB, 200_000000);
        coin::mint_to(&btc_mint, signer::address_of(c), 1_000_000_000_000_000);
        coin::mint_to(&eth_mint, signer::address_of(c), 1_000_000_000_000_000);
        bribe::set_allowed_bribe_tokens(c, vector[coin::metadata(@initia_std, string::utf8(b"btc"))]);

        // Set oracle price for BTC
        let btc_usd_pair_id = string::utf8(b"btc/usd");
        let eth_usd_pair_id = string::utf8(b"eth/usd");
        let btc_price = 100_00000000_u256;
        let eth_price = 10_000000000000000000_u256;
        let btc_updated_at = 1000002;
        let eth_updated_at = 1000003;
        let btc_decimals = 8;
        let eth_decimals = 18;
        oracle::set_price(&btc_usd_pair_id, btc_price, btc_updated_at, btc_decimals);
        oracle::set_price(&eth_usd_pair_id, eth_price, eth_updated_at, eth_decimals);

        utils::increase_block(1,1);


        // User A deposits and stakes
        if (stake_amount_a > 0) {
            // debug::print(&string::utf8(b"staking a"));
            cabal::mock_deposit_init_for_xinit(user_a, stake_amount_a);
            let xinit_metadata = cabal::get_xinit_metadata();
            let xinit_balance_a = primary_fungible_store::balance(@0xAAA, xinit_metadata);
            assert!(xinit_balance_a >= stake_amount_a, 1901); // Check if deposit worked
            cabal::mock_stake(user_a, 0, stake_amount_a); // Stake the specified amount
        };

        utils::increase_block(1,1); //TODO: without the increase_block everything fails, what the hell is going on here? 
        // User D deposits and stakes
         if (stake_amount_d > 0) {
            // debug::print(&string::utf8(b"staking d"));
            cabal::mock_deposit_init_for_xinit(user_d, stake_amount_d);
            let xinit_metadata = cabal::get_xinit_metadata();
            let xinit_balance_d = primary_fungible_store::balance(@0xDDD, xinit_metadata);
             assert!(xinit_balance_d >= stake_amount_d, 1902); // Check if deposit worked
            cabal::mock_stake(user_d, 0, stake_amount_d); // Stake the specified amount
        };

        utils::increase_block(1, 1); // Advance block after setup
    }

    // multiple people staking the same amount
    #[test(c=@staking_addr, user_a=@0xAAA, user_b=@0xBBB, user_d=@0xDDD)]
    fun test_reward_multiple_stakers_equal_share(c: &signer, user_a: &signer, user_b: &signer, user_d: &signer) {
        let stake_amount = 500_000_000_000; // 500k INIT each
        setup_multiple_stakers(c, user_a, user_d, stake_amount, stake_amount);

        let aaa_addr = @0xAAA;
        let ddd_addr = @0xDDD;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let cycle = 1;
        let bridge_id = 101;
        let bribe_amount = 100_000000; // 100 BTC

        // User B deposits bribe
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount, cycle, bridge_id);
        utils::increase_block(1, 1);

        // Snapshot and finalize
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // Verify rewards are split ~50/50
        let reward_a = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        let reward_d = voting_reward::get_single_reward(ddd_addr, btc_metadata);
        let total_reward_calculated = reward_a + reward_d;

        // debug::print(&string::utf8(b"Reward A (50%):")); debug::print(&reward_a);
        // debug::print(&string::utf8(b"Reward D (50%):")); debug::print(&reward_d);
        // debug::print(&string::utf8(b"Total Calculated:")); debug::print(&total_reward_calculated);

        // Check total reward is close to bribe amount
        utils::test_with_slack(total_reward_calculated, bribe_amount, 1);

        // Check individual shares are close to 50%
        let expected_share = bribe_amount / 2;
        utils::test_with_slack(reward_a, expected_share, 1);
        utils::test_with_slack(reward_d, expected_share, 1);
    }

    // 20. test_reward_multiple_stakers_unequal_share
    #[test(c=@staking_addr, user_a=@0xAAA, user_b=@0xBBB, user_d=@0xDDD)]
    fun test_reward_multiple_stakers_unequal_share(c: &signer, user_a: &signer, user_b: &signer, user_d: &signer) {
        let stake_amount_a = 750_000_000_000; // 750k INIT (75%)
        let stake_amount_d = 250_000_000_000; // 250k INIT (25%)
        setup_multiple_stakers(c, user_a, user_d, stake_amount_a, stake_amount_d);

        let aaa_addr = @0xAAA;
        let ddd_addr = @0xDDD;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let cycle = 1;
        let bridge_id = 101;
        let bribe_amount = 100_000000; // 100 BTC

        // User B deposits bribe
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount, cycle, bridge_id);
        utils::increase_block(1, 1);

        // Snapshot and finalize
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // Verify rewards are split ~75/25
        let reward_a = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        let reward_d = voting_reward::get_single_reward(ddd_addr, btc_metadata);
        let total_reward_calculated = reward_a + reward_d;

        // debug::print(&string::utf8(b"Reward A (75%):")); debug::print(&reward_a);
        // debug::print(&string::utf8(b"Reward D (25%):")); debug::print(&reward_d);
        // debug::print(&string::utf8(b"Total Calculated:")); debug::print(&total_reward_calculated);

        // Check total reward is close to bribe amount
        utils::test_with_slack(total_reward_calculated, bribe_amount, 1);

        // Check individual shares are close to expected ratio
        let expected_share_a = bribe_amount * 3 / 4; // 75%
        let expected_share_d = bribe_amount / 4;     // 25%
        utils::test_with_slack(reward_a, expected_share_a, 1);
        utils::test_with_slack(reward_d, expected_share_d, 1);
    }

     // 21. test_reward_multiple_stakers_one_joins_later
    #[test(c=@staking_addr, user_a=@0xAAA, user_b=@0xBBB, user_d=@0xDDD)]
    fun test_reward_multiple_stakers_one_joins_later(c: &signer, user_a: &signer, user_b: &signer, user_d: &signer) {
        // Basic setup, only User A stakes initially
        let stake_amount_a = 500_000_000_000;
        setup_multiple_stakers(c, user_a, user_d, stake_amount_a, 0); // User D stakes 0 initially

        let aaa_addr = @0xAAA;
        let ddd_addr = @0xDDD;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let init_metadata = coin::metadata(@initia_std, string::utf8(b"uinit"));
        let bridge_id = 101;
        let bribe_amount_cycle1 = 100_000000;
        let bribe_amount_cycle2 = 50_000000;

        // --- Cycle 1 ---
        let cycle1 = 1;
        // Bribe for Cycle 1
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount_cycle1, cycle1, bridge_id);
        utils::increase_block(1, 1);
        // Snapshot (Only User A is staked)
        let snapshot_height1 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        // Finalize Cycle 1
        voting_reward::finalize_reward_cycle(c, cycle1, snapshot_height1);

        // Verify Cycle 1 rewards: A gets 100%, D gets 0%
        let reward_a_c1 = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        let reward_d_c1 = voting_reward::get_single_reward(ddd_addr, btc_metadata);
        // debug::print(&string::utf8(b"C1 Reward A:")); debug::print(&reward_a_c1);
        // debug::print(&string::utf8(b"C1 Reward D:")); debug::print(&reward_d_c1);
        utils::test_with_slack(reward_a_c1, bribe_amount_cycle1, 1);
        assert!(reward_d_c1 == 0, 2101);

        // --- User D joins ---
        utils::increase_block(1, 1);
        let stake_amount_d = 500_000_000_000; // User D stakes 500k INIT
        primary_fungible_store::transfer(c, init_metadata, signer::address_of(user_d), stake_amount_d);
        assert!(primary_fungible_store::balance(signer::address_of(user_d), init_metadata) == stake_amount_d, 1802);
        cabal::mock_deposit_init_for_xinit(user_d, stake_amount_d);
        let xinit_metadata = cabal::get_xinit_metadata();
        let xinit_balance_d = primary_fungible_store::balance(@0xDDD, xinit_metadata);
        cabal::mock_stake(user_d, 0, xinit_balance_d);
        utils::increase_block(1, 1);

        // --- Cycle 2 ---
        let cycle2 = 2;
        // Bribe for Cycle 2
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount_cycle2, cycle2, bridge_id);
        utils::increase_block(1, 1);
        // Snapshot (Both A and D are staked equally)
        let snapshot_height2 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        // Finalize Cycle 2
        voting_reward::finalize_reward_cycle(c, cycle2, snapshot_height2);

        // Verify *total* rewards after Cycle 2
        let total_reward_a = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        let total_reward_d = voting_reward::get_single_reward(ddd_addr, btc_metadata);
        // debug::print(&string::utf8(b"Total Reward A (C1+C2):")); debug::print(&total_reward_a);
        // debug::print(&string::utf8(b"Total Reward D (C1+C2):")); debug::print(&total_reward_d);

        // Calculate expected rewards for Cycle 2 (50/50 split of bribe_amount_cycle2)
        let expected_reward_a_c2 = bribe_amount_cycle2 / 2;
        let expected_reward_d_c2 = bribe_amount_cycle2 / 2;

        // Check total rewards = C1 reward + C2 reward
        utils::test_with_slack(total_reward_a, reward_a_c1 + expected_reward_a_c2, 1);
        utils::test_with_slack(total_reward_d, reward_d_c1 + expected_reward_d_c2, 1); // reward_d_c1 is 0
    }


    // VI. Claiming Rewards (claim_voting_reward)

    // 23. test claim while paused 
    #[test(c = @staking_addr, user_a = @0xAAA, user_b = @0xBBB)]
    #[expected_failure(location = staking_addr::emergency, abort_code = 0x30002)] // error::invalid_argument = 0x3000, emergency::EPAUSED = 0x2
    fun test_claim_paused_fails(c: &signer, user_a: &signer, user_b: &signer) {
        // Setup with a reward for user A
        test_setup(c, string::utf8(b"validator123"));
        let aaa_addr = @0xAAA;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);
        let cycle = 1;
        let bridge_id = 101;
        let bribe_amount = 50_000000;
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount, cycle, bridge_id);
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);
        assert!(voting_reward::get_single_reward(aaa_addr, btc_metadata) > 0, 2301);

        // Pause the system
        emergency::set_pause(c, true);
        assert!(emergency::paused(), 2302);

        // Attempt claim while paused - should fail
        voting_reward::claim_voting_reward(user_a, btc_metadata);
    }

    //claim voting rewards after pausing and unpausing, cycle before
    #[test(c = @staking_addr, user_a = @0xAAA, user_b = @0xBBB)]
    fun test_claim_paused_unpaused_succeeds(c: &signer, user_a: &signer, user_b: &signer) {
        // Setup with a reward for user A
        test_setup(c, string::utf8(b"validator123"));
        let aaa_addr = @0xAAA;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);
        let cycle = 1;
        let bridge_id = 101;
        let bribe_amount = 50_000000;
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount, cycle, bridge_id);
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);
        let pending_reward = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        assert!(pending_reward > 0, 2402);

        // Pause and unpause
        emergency::set_pause(c, true);
        assert!(emergency::paused(), 2403);
        emergency::set_pause(c, false);
        assert!(!emergency::paused(), 2404);

        // Claim should now succeed
        let initial_balance = primary_fungible_store::balance(aaa_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        let final_balance = primary_fungible_store::balance(aaa_addr, btc_metadata);
        assert!(final_balance == initial_balance + pending_reward, 2405);
    }

    // claim voting rewards when there are no bribes thus no rewards
    #[test(c = @staking_addr, user_a = @0xAAA)]
    #[expected_failure(location = staking_addr::voting_reward, abort_code = 0x30002)]//invalid_state: 0x30000, EINVALID_REMAIN_AMOUNT=0x2
    fun test_claim_no_reward(c: &signer, user_a: &signer) {
        test_setup(c, string::utf8(b"validator123")); // User AAA is staked
        let aaa_addr = @0xAAA;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        // No bribes deposited

        // Finalize a cycle
        let cycle = 1;
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // Verify no reward exists
        assert!(voting_reward::get_single_reward(aaa_addr, btc_metadata) == 0, 2401);

        // Attempt claim - should fail as there's nothing to claim
        voting_reward::claim_voting_reward(user_a, btc_metadata);
    }

    // simple claiming of voting rewards single user
    #[test(c=@staking_addr, user_a=@0xAAA, user_b=@0xBBB)]
    fun test_claim_success_single_token_verification(c: &signer, user_a: &signer, user_b: &signer) {
        test_setup(c, string::utf8(b"validator123"));
        let aaa_addr = @0xAAA;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);
        let cycle = 1;
        let bridge_id = 101;
        let bribe_amount = 50_000000;
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount, cycle, bridge_id);
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        let pending_reward = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        utils::test_with_slack(pending_reward, bribe_amount, 1);

        let initial_balance = primary_fungible_store::balance(aaa_addr, btc_metadata);

        // Claim
        voting_reward::claim_voting_reward(user_a, btc_metadata);

        // Verify balance increase
        let final_balance = primary_fungible_store::balance(aaa_addr, btc_metadata);
        assert!(final_balance == initial_balance + pending_reward, 2502);

        // Verify remaining claimable is zero
        let remaining_reward = voting_reward::get_unclaimed_voting_reward(aaa_addr, btc_metadata);
        //debug::print(&remaining_reward);
        assert!(remaining_reward == 0, 2503);
    }

    // single user, multiple bribe tokens claiming 
     #[test(c=@staking_addr, user_a=@0xAAA, user_b=@0xBBB)]
    fun test_claim_multiple_tokens_verification(c: &signer, user_a: &signer, user_b: &signer) {
        test_setup(c, string::utf8(b"validator123")); // User AAA staked
        let aaa_addr = @0xAAA;

        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let eth_metadata = coin::metadata(@initia_std, string::utf8(b"eth"));
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata, eth_metadata]);

        let cycle = 1;
        let bridge_id = 101;
        let btc_bribe_amount = 50_000000;
        let eth_bribe_amount = 10_000000;

        bribe::mock_deposit_bribe(user_b, btc_metadata, btc_bribe_amount, cycle, bridge_id);
        utils::increase_block(1, 1);
        bribe::mock_deposit_bribe(user_b, eth_metadata, eth_bribe_amount, cycle, bridge_id);
        utils::increase_block(1, 1);

        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        let pending_btc = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        let pending_eth = voting_reward::get_single_reward(aaa_addr, eth_metadata);
        assert!(pending_btc > 0, 2601);
        assert!(pending_eth > 0, 2602);

        let initial_btc_a = primary_fungible_store::balance(aaa_addr, btc_metadata);
        let initial_eth_a = primary_fungible_store::balance(aaa_addr, eth_metadata);

        // Claim BTC
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        let mid_btc_a = primary_fungible_store::balance(aaa_addr, btc_metadata);
        let mid_eth_a = primary_fungible_store::balance(aaa_addr, eth_metadata);
        assert!(mid_btc_a == initial_btc_a + pending_btc, 2603); // BTC increased
        assert!(mid_eth_a == initial_eth_a, 2604); // ETH unchanged
        assert!(voting_reward::get_unclaimed_voting_reward(aaa_addr, btc_metadata) == 0, 2605); // BTC reward claimed
        assert!(voting_reward::get_unclaimed_voting_reward(aaa_addr, eth_metadata) == pending_eth, 2606); // ETH reward remains

        // Claim ETH
        voting_reward::claim_voting_reward(user_a, eth_metadata);
        let final_btc_a = primary_fungible_store::balance(aaa_addr, btc_metadata);
        let final_eth_a = primary_fungible_store::balance(aaa_addr, eth_metadata);
        assert!(final_btc_a == mid_btc_a, 2607); // BTC unchanged
        assert!(final_eth_a == mid_eth_a + pending_eth, 2608); // ETH increased
        assert!(voting_reward::get_unclaimed_voting_reward(aaa_addr, btc_metadata) == 0, 2609); // BTC reward still 0
        assert!(voting_reward::get_unclaimed_voting_reward(aaa_addr, eth_metadata) == 0, 2610); // ETH reward claimed
    }

    // single user, multiple cycles claiming
    #[test(c=@staking_addr, user_a=@0xAAA, user_b=@0xBBB)]
    fun test_claim_multiple_cycles(c: &signer, user_a: &signer, user_b: &signer) {
        test_setup(c, string::utf8(b"validator123"));
        let aaa_addr = @0xAAA;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);
        let bridge_id = 101;
        let bribe_c1 = 50_000000;
        let bribe_c2 = 30_000000;

        // Cycle 1
        let cycle1 = 1;
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_c1, cycle1, bridge_id);
        utils::increase_block(1, 1);
        let snapshot1 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle1, snapshot1);
        let reward_c1 = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        utils::test_with_slack(reward_c1, bribe_c1, 1);

        // Cycle 2
        let cycle2 = 2;
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_c2, cycle2, bridge_id);
        utils::increase_block(1, 1);
        let snapshot2 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle2, snapshot2);

        // Verify accumulated reward
        let total_pending = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        // debug::print(&string::utf8(b"Total Pending (C1+C2):")); debug::print(&total_pending);
        utils::test_with_slack(total_pending, bribe_c1 + bribe_c2, 1);

        // Claim all at once
        let initial_balance = primary_fungible_store::balance(aaa_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        let final_balance = primary_fungible_store::balance(aaa_addr, btc_metadata);

        // Verify total claimed amount
        assert!(final_balance == initial_balance + total_pending, 2701);
        assert!(voting_reward::get_unclaimed_voting_reward(aaa_addr, btc_metadata) == 0, 2702);
    }

    // claiming when already claimed, expect error
    #[test(c=@staking_addr, user_a=@0xAAA, user_b=@0xBBB)]
    #[expected_failure(location = staking_addr::voting_reward, abort_code = 0x30002)] //invalid_state: 0x30000, EINVALID_REMAIN_AMOUNT: 0x2 
    fun test_claim_twice(c: &signer, user_a: &signer, user_b: &signer) {
        test_setup(c, string::utf8(b"validator123"));
        let aaa_addr = @0xAAA;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);
        let cycle = 1;
        let bridge_id = 101;
        let bribe_amount = 50_000000;
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount, cycle, bridge_id);
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);
        assert!(voting_reward::get_single_reward(aaa_addr, btc_metadata) > 0, 2801);

        // First claim (success)
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        assert!(voting_reward::get_unclaimed_voting_reward(aaa_addr, btc_metadata) == 0, 2802);

        // Second claim (fail)
        voting_reward::claim_voting_reward(user_a, btc_metadata);
    }

    // claim first cycle, test that 2nd cycle claim is really just the 2nd cycle bribe
    #[test(c=@staking_addr, user_a=@0xAAA, user_b=@0xBBB)]
    fun test_claim_partial_then_more_rewards(c: &signer, user_a: &signer, user_b: &signer) {
        test_setup(c, string::utf8(b"validator123"));
        let aaa_addr = @0xAAA;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);
        let bridge_id = 101;
        let bribe_c1 = 50_000000;
        let bribe_c2 = 30_000000;

        // Cycle 1
        let cycle1 = 1;
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_c1, cycle1, bridge_id);
        utils::increase_block(1, 1);
        let snapshot1 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle1, snapshot1);
        let reward_c1 = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        utils::test_with_slack(reward_c1, bribe_c1, 1);

        // Claim Cycle 1 reward
        let initial_balance = primary_fungible_store::balance(aaa_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        let balance_after_c1_claim = primary_fungible_store::balance(aaa_addr, btc_metadata);
        assert!(balance_after_c1_claim == initial_balance + reward_c1, 2901);
        assert!(voting_reward::get_unclaimed_voting_reward(aaa_addr, btc_metadata) == 0, 2902);

        // Cycle 2
        let cycle2 = 2;
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_c2, cycle2, bridge_id);
        utils::increase_block(1, 1);
        let snapshot2 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle2, snapshot2);

        // Verify reward for Cycle 2 is available
        let reward_c2 = voting_reward::get_unclaimed_voting_reward(aaa_addr, btc_metadata);
        // debug::print(&string::utf8(b"Pending C2 Reward:")); debug::print(&reward_c2);
        utils::test_with_slack(reward_c2, bribe_c2, 1);

        // Claim again (should claim only Cycle 2 reward)
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        let final_balance = primary_fungible_store::balance(aaa_addr, btc_metadata);

        // Verify only C2 reward was transferred in the second claim
        assert!(final_balance == balance_after_c1_claim + reward_c2, 2903);
        assert!(voting_reward::get_unclaimed_voting_reward(aaa_addr, btc_metadata) == 0, 2904);

        let total_claimed = cabal::get_claimed_voting_reward_amount(aaa_addr, btc_metadata);
        assert!(total_claimed == reward_c1 + reward_c2, 2905);
    }

    // VII. Multiple Cycles

    // testing with multiple stakers and multiple tokens over multiple cycles
    #[test(c=@staking_addr, user_a=@0xAAA, user_b=@0xBBB, user_d=@0xDDD)]
    fun test_multiple_cycles_rewards_accumulation(c: &signer, user_a: &signer, user_b: &signer, user_d: &signer) {
        // Setup with two stakers A (500k) and D (500k)
        let stake_amount = 500_000_000_000;
        setup_multiple_stakers(c, user_a, user_d, stake_amount, stake_amount);
        let aaa_addr = @0xAAA;
        let ddd_addr = @0xDDD;
        //debug::print(&string::utf8(b"ddd"));
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let eth_metadata = coin::metadata(@initia_std, string::utf8(b"eth"));
        //debug::print(&string::utf8(b"ddd"));
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata, eth_metadata]);
        let bridge_id = 101;

        let btc_bribe_c1 = 100_000000; // 100 BTC
        let eth_bribe_c2 = 20_000000;  // 20 ETH
        let btc_bribe_c3 = 40_000000;  // 40 BTC

        // Cycle 1: BTC Bribe
        let cycle1 = 1;
        bribe::mock_deposit_bribe(user_b, btc_metadata, btc_bribe_c1, cycle1, bridge_id);
        utils::increase_block(1, 1);
        let snapshot1 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle1, snapshot1);
        let reward_a_c1_btc = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        let reward_d_c1_btc = voting_reward::get_single_reward(ddd_addr, btc_metadata);
        utils::test_with_slack(reward_a_c1_btc + reward_d_c1_btc, btc_bribe_c1, 1);

        // Cycle 2: ETH Bribe
        let cycle2 = 2;
        bribe::mock_deposit_bribe(user_b, eth_metadata, eth_bribe_c2, cycle2, bridge_id);
        utils::increase_block(1, 1);
        let snapshot2 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle2, snapshot2);
        let reward_a_c2_eth = voting_reward::get_single_reward(aaa_addr, eth_metadata);
        let reward_d_c2_eth = voting_reward::get_single_reward(ddd_addr, eth_metadata);
        utils::test_with_slack(reward_a_c2_eth + reward_d_c2_eth, eth_bribe_c2, 1);

        // Cycle 3: BTC Bribe again
        let cycle3 = 3;
        bribe::mock_deposit_bribe(user_b, btc_metadata, btc_bribe_c3, cycle3, bridge_id);
        utils::increase_block(1, 1);
        let snapshot3 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle3, snapshot3);
        let reward_a_c3_btc = voting_reward::get_single_reward(aaa_addr, btc_metadata) - reward_a_c1_btc; // Get C3 portion
        let reward_d_c3_btc = voting_reward::get_single_reward(ddd_addr, btc_metadata) - reward_d_c1_btc; // Get C3 portion
        utils::test_with_slack(reward_a_c3_btc + reward_d_c3_btc, btc_bribe_c3, 1);


        // Verify accumulated totals *before* claiming
        let total_a_btc = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        let total_d_btc = voting_reward::get_single_reward(ddd_addr, btc_metadata);
        let total_a_eth = voting_reward::get_single_reward(aaa_addr, eth_metadata);
        let total_d_eth = voting_reward::get_single_reward(ddd_addr, eth_metadata);

        // debug::print(&string::utf8(b"Accumulated A BTC:")); debug::print(&total_a_btc);
        // debug::print(&string::utf8(b"Accumulated D BTC:")); debug::print(&total_d_btc);
        // debug::print(&string::utf8(b"Accumulated A ETH:")); debug::print(&total_a_eth);
        // debug::print(&string::utf8(b"Accumulated D ETH:")); debug::print(&total_d_eth);

        // Check BTC totals (C1 + C3)
        utils::test_with_slack(total_a_btc + total_d_btc, btc_bribe_c1 + btc_bribe_c3, 1);
        // Check ETH totals (C2)
        utils::test_with_slack(total_a_eth + total_d_eth, eth_bribe_c2, 1);

        // Check total reward map for User A
        let total_rewards_a = voting_reward::get_total_reward(aaa_addr);
        assert!(simple_map::length(&total_rewards_a) == 2, 3001);
        assert!(*simple_map::borrow(&total_rewards_a, &btc_metadata) == total_a_btc, 3002);
        assert!(*simple_map::borrow(&total_rewards_a, &eth_metadata) == total_a_eth, 3003);

        // Check total USD for User A
        let total_usd_a = voting_reward::get_total_reward_in_usd(aaa_addr);
        let expected_btc_usd_a = utils::get_token_value_in_usd(btc_metadata, total_a_btc);
        let expected_eth_usd_a = utils::get_token_value_in_usd(eth_metadata, total_a_eth);
        let expected_total_usd_a = bigdecimal::add(expected_btc_usd_a, expected_eth_usd_a);
        let tolerance = bigdecimal::div(expected_total_usd_a, bigdecimal::from_u64(1000)); // 0.1% tolerance
        assert!(bigdecimal::le(bigdecimal::sub(total_usd_a, expected_total_usd_a), tolerance) || bigdecimal::le(bigdecimal::sub(expected_total_usd_a, total_usd_a), tolerance), 3004);
    }

    // multiple cycles single token, claim at end
    #[test(c=@staking_addr, user_a=@0xAAA, user_b=@0xBBB)]
    fun test_multiple_cycles_claim_at_end(c: &signer, user_a: &signer, user_b: &signer) {
        test_setup(c, string::utf8(b"validator123"));
        let aaa_addr = @0xAAA;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);
        let bridge_id = 101;
        let bribe_c1 = 50_000000;
        let bribe_c2 = 30_000000;
        let bribe_c3 = 20_000000;

        // Cycle 1
        let cycle1 = 1;
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_c1, cycle1, bridge_id);
        utils::increase_block(1, 1);
        let snapshot1 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle1, snapshot1);

        // Cycle 2
        let cycle2 = 2;
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_c2, cycle2, bridge_id);
        utils::increase_block(1, 1);
        let snapshot2 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle2, snapshot2);

        // Cycle 3
        let cycle3 = 3;
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_c3, cycle3, bridge_id);
        utils::increase_block(1, 1);
        let snapshot3 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle3, snapshot3);

        // Verify accumulated reward
        let total_pending = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        utils::test_with_slack(total_pending, bribe_c1 + bribe_c2 + bribe_c3, 1);

        // Claim all at the end
        let initial_balance = primary_fungible_store::balance(aaa_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        let final_balance = primary_fungible_store::balance(aaa_addr, btc_metadata);

        // Verify total claimed amount
        assert!(final_balance == initial_balance + total_pending, 3101);
        assert!(voting_reward::get_unclaimed_voting_reward(aaa_addr, btc_metadata) == 0, 3102);
    }

    // multiple cycles, claim in the middle, check that balances are fine
    #[test(c=@staking_addr, user_a=@0xAAA, user_b=@0xBBB)]
    fun test_multiple_cycles_claim_intermittently(c: &signer, user_a: &signer, user_b: &signer) {
        test_setup(c, string::utf8(b"validator123"));
        let aaa_addr = @0xAAA;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);
        let bridge_id = 101;
        let bribe_c1 = 50_000000;
        let bribe_c2 = 30_000000;

        // Cycle 1
        let cycle1 = 1;
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_c1, cycle1, bridge_id);
        utils::increase_block(1, 1);
        let snapshot1 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle1, snapshot1);
        let reward_c1 = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        utils::test_with_slack(reward_c1, bribe_c1, 1);
        //debug::print(&string::utf8(b"dddd"));

        // Claim Cycle 1
        let initial_balance = primary_fungible_store::balance(aaa_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        let balance_after_c1 = primary_fungible_store::balance(aaa_addr, btc_metadata);
        assert!(balance_after_c1 == initial_balance + reward_c1, 3201);
        assert!(voting_reward::get_unclaimed_voting_reward(aaa_addr, btc_metadata) == 0, 3202);

        // Cycle 2
        let cycle2 = 2;
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_c2, cycle2, bridge_id);
        utils::increase_block(1, 1);
        let snapshot2 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle2, snapshot2);
        let reward_c2 = voting_reward::get_unclaimed_voting_reward(aaa_addr, btc_metadata);
        //debug::print(&string::utf8(b"dddd"));
        // debug::print(&reward_c2);
        // debug::print(&bribe_c2);
        utils::test_with_slack(reward_c2, bribe_c2, 1);
        //debug::print(&string::utf8(b"dddd"));

        // Claim Cycle 2
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        let final_balance = primary_fungible_store::balance(aaa_addr, btc_metadata);
        assert!(final_balance == balance_after_c1 + reward_c2, 3203);
        assert!(voting_reward::get_unclaimed_voting_reward(aaa_addr, btc_metadata) == 0, 3204);
    }

    // VIII: Edge Cases

    // no stakers, no reward
    #[test(c = @staking_addr, user_b = @0xBBB)]
    fun test_zero_supply_snapshot(c: &signer, user_b: &signer) {
        // Setup *without* any initial staking
        test_setup_no_stake(c, string::utf8(b"validator123"));
        let aaa_addr = @0xAAA; // User exists but has no stake
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);
        let cycle = 1;
        let bridge_id = 101;
        let bribe_amount = 50_000000;

        // Snapshot when sxINIT supply is effectively zero (only MINIMUM_LIQUIDITY exists)
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);

        // Verify snapshot supply reflects only minimum liquidity (or zero if logic changes)
        let sxinit_metadata = cabal::get_sxinit_metadata();
        let snapshot_supply = cabal_token::get_snapshot_supply(sxinit_metadata, snapshot_height);
        // debug::print(&string::utf8(b"Snapshot Supply (Zero Stake):")); debug::print(&snapshot_supply);
        assert!(snapshot_supply == 100_000_000, 3301);

        // Deposit bribe
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount, cycle, bridge_id);
        utils::increase_block(1, 1);

        // Finalize cycle
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // Verify zero rewards are calculated for any user
        assert!(voting_reward::get_single_reward(aaa_addr, btc_metadata) == 0, 3302);
        assert!(bigdecimal::eq(voting_reward::get_total_reward_in_usd(aaa_addr), bigdecimal::zero()), 3303);
    }

    // stakers, but no reward
    #[test(c = @staking_addr)]
    fun test_zero_bribes_cycle(c: &signer) {
        test_setup(c, string::utf8(b"validator123")); // User AAA is staked
        let aaa_addr = @0xAAA;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let cycle = 1;

        // Snapshot and finalize without any bribes
        utils::increase_block(1, 1);
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // Verify zero rewards
        assert!(voting_reward::get_single_reward(aaa_addr, btc_metadata) == 0, 3401);
        assert!(simple_map::length(&voting_reward::get_total_reward(aaa_addr)) == 0, 3402);
        assert!(bigdecimal::eq(voting_reward::get_total_reward_in_usd(aaa_addr), bigdecimal::zero()), 3403);
    }

    // test with large numbers
    #[test(c=@staking_addr, user_a=@0xAAA, user_b=@0xBBB, user_d=@0xDDD)]
    fun test_large_numbers(c: &signer, user_a: &signer, user_b: &signer, user_d: &signer) {
        // Use large, but not necessarily max u64/u128, stake amounts to avoid easy overflow
        // but still test large number handling. Max u64 might overflow intermediate u128 calcs.
        let stake_amount_a = 100_000_000_000_000_000; // 100M INIT (10^17 uinit)
        let stake_amount_d = 300_000_000_000_000_000; // 300M INIT (3*10^17 uinit)
        setup_multiple_stakers(c, user_a, user_d, stake_amount_a, stake_amount_d);

        let aaa_addr = @0xAAA;
        let ddd_addr = @0xDDD;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let cycle = 1;
        let bridge_id = 101;
       
        let bribe_amount = 500_000_000_000_000;
        primary_fungible_store::transfer(c, btc_metadata, signer::address_of(user_b), bribe_amount);

        // User B deposits bribe
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount, cycle, bridge_id);
        utils::increase_block(1, 1);

        // Snapshot and finalize
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // Verify rewards are split ~25/75
        let reward_a = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        let reward_d = voting_reward::get_single_reward(ddd_addr, btc_metadata);
        let total_reward_calculated = reward_a + reward_d;

        // Check total reward is close to bribe amount (allow slightly larger slack for large numbers)
        utils::test_with_slack(total_reward_calculated, bribe_amount, 5); // 0.5% slack

        // Check individual shares are close to expected ratio
        let expected_share_a = bribe_amount / 4;     // 25%
        let expected_share_d = bribe_amount * 3 / 4; // 75%
        utils::test_with_slack(reward_a, expected_share_a, 5);
        utils::test_with_slack(reward_d, expected_share_d, 5);

        // Claim and check balance update
        let initial_balance_a = primary_fungible_store::balance(aaa_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        let final_balance_a = primary_fungible_store::balance(aaa_addr, btc_metadata);
        assert!(final_balance_a == initial_balance_a + reward_a, 3601);

        let initial_balance_d = primary_fungible_store::balance(ddd_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_d, btc_metadata);
        let final_balance_d = primary_fungible_store::balance(ddd_addr, btc_metadata);
        assert!(final_balance_d == initial_balance_d + reward_d, 3602);
    }

    // test with small numbers bribing
    #[test(c=@staking_addr, user_a=@0xAAA, user_b=@0xBBB, user_d=@0xDDD)]
    fun test_small_amounts(c: &signer, user_a: &signer, user_b: &signer, user_d: &signer) {
        let stake_amount = 500_000_000_000;
        setup_multiple_stakers(c, user_a, user_d, stake_amount, stake_amount);
        let aaa_addr = @0xAAA;
        let ddd_addr = @0xDDD;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let cycle = 1;
        let bridge_id = 101;
        let bribe_amount = 1; // 1 satoshi

        // User B deposits bribe
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount, cycle, bridge_id);
        utils::increase_block(1, 1);
        // Snapshot and finalize
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // Verify rewards (likely 0 for each due to integer division)
        // debug::print(&string::utf8(b"dddd"));
        let reward_a = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        let reward_d = voting_reward::get_single_reward(ddd_addr, btc_metadata);
        // debug::print(&string::utf8(b"dddd"));

        // debug::print(&string::utf8(b"Dust Reward A:")); debug::print(&reward_a);
        // debug::print(&string::utf8(b"Dust Reward D:")); debug::print(&reward_d);

        // Depending on implementation, the total might be 1 or 0, and shares might be 0 or 1/0
        // Let's assume integer division truncates the 0.5 share to 0
        assert!(reward_a == 0, 3701);
        assert!(reward_d == 0, 3702);
        assert!(reward_a + reward_d <= bribe_amount, 3703); // Total shouldn't exceed bribe

        let bribe_amount_2 = 10;
        let cycle_2 = 2;
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount_2, cycle_2, bridge_id);
        utils::increase_block(1, 1);
        let snapshot_height_2 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle_2, snapshot_height_2);

        let reward_a_c2 = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        let reward_d_c2 = voting_reward::get_single_reward(ddd_addr, btc_metadata);
        // debug::print(&string::utf8(b"Dust2 Reward A:")); debug::print(&reward_a_c2);
        // debug::print(&string::utf8(b"Dust2 Reward D:")); debug::print(&reward_d_c2);
        // debug::print(&reward_a_c2);
        // debug::print(&reward_d_c2);
        assert!(reward_a_c2 <= 5, 3704);
        assert!(reward_d_c2 <= 5, 3705);
        assert!(reward_a_c2 >= 4, 3706);
        assert!(reward_d_c2 >= 4, 3707);
    }

    // IX: unstaking tests
    // One user stakes, a bribe is deposited, unstakes, cycle ends. What happens to the rewards
    #[test(c=@staking_addr, user_a=@0xAAA, user_b=@0xBBB)]
    fun test_stake_bribe_unstake_finalize(c: &signer, user_a: &signer, user_b: &signer) {
        test_setup(c, string::utf8(b"validator123")); // User AAA is staked initially
        cabal::init_fees_exempt(c);
        cabal::set_fees_exempt(c, vector[@0xAAA]); // Whitelist user A for instant unstake

        let aaa_addr = @0xAAA;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);
        let sxinit_metadata = cabal::get_sxinit_metadata();

        let cycle = 1;
        let bridge_id = 101;
        let bribe_amount = 50_000000;
        let initial_stake_a = primary_fungible_store::balance(aaa_addr, sxinit_metadata);
        assert!(initial_stake_a > 0, 3801);

        // Deposit Bribe
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount, cycle, bridge_id);
        utils::increase_block(1, 1);

        // User A unstakes *before* snapshot/finalize
        // debug::print(&initial_stake_a);
        // debug::print(&fungible_asset::supply(sxinit_metadata));
        cabal::mock_unstake(user_a, 0, initial_stake_a); // 0 for sxINIT
        assert!(primary_fungible_store::balance(aaa_addr, sxinit_metadata) == 0, 3802);
        utils::increase_block(1, 1);

        // Snapshot and Finalize Cycle
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // Verify User A gets no reward because they unstaked before the snapshot
        let reward_a = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        assert!(reward_a == 0, 3803);
    }

    // One user stakes, bribe happens, cycle ends, unstakes
    #[test(c=@staking_addr, user_a=@0xAAA, user_b=@0xBBB)]
    fun test_stake_bribe_finalize_unstake(c: &signer, user_a: &signer, user_b: &signer) {
        test_setup(c, string::utf8(b"validator123")); // User AAA is staked initially
        cabal::init_fees_exempt(c);
        cabal::set_fees_exempt(c, vector[@0xAAA]); // Whitelist user A

        let aaa_addr = @0xAAA;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);
        let sxinit_metadata = cabal::get_sxinit_metadata();

        let cycle = 1;
        let bridge_id = 101;
        let bribe_amount = 50_000000;
        let initial_stake_a = primary_fungible_store::balance(aaa_addr, sxinit_metadata);
        assert!(initial_stake_a > 0, 3901);

        // Deposit Bribe
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount, cycle, bridge_id);
        utils::increase_block(1, 1);

        // Snapshot and Finalize Cycle *before* unstake
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // Verify User A has pending reward
        let reward_a_before_unstake = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        utils::test_with_slack(reward_a_before_unstake, bribe_amount, 1);

        // User A unstakes *after* finalize
        cabal::mock_unstake(user_a, 0, initial_stake_a); // 0 for sxINIT
        assert!(primary_fungible_store::balance(aaa_addr, sxinit_metadata) == 0, 3902);
        utils::increase_block(1, 1);

        // Verify User A still has the same pending reward
        let reward_a_after_unstake = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        assert!(reward_a_after_unstake == reward_a_before_unstake, 3903);

        // Claim reward
        let initial_btc_balance = primary_fungible_store::balance(aaa_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        let final_btc_balance = primary_fungible_store::balance(aaa_addr, btc_metadata);
        assert!(final_btc_balance == initial_btc_balance + reward_a_after_unstake, 3904);
        assert!(voting_reward::get_unclaimed_voting_reward(aaa_addr, btc_metadata) == 0, 3905);
    }

    // One user stakes, bribe happens, partial unstake, cycle ends, unstakes fully
    #[test(c=@staking_addr, user_a=@0xAAA, user_b=@0xBBB)]
    fun test_stake_bribe_partial_unstake_finalize_full_unstake(c: &signer, user_a: &signer, user_b: &signer) {
        test_setup(c, string::utf8(b"validator123")); // User AAA is staked initially
        cabal::init_fees_exempt(c);
        cabal::set_fees_exempt(c, vector[@0xAAA]); // Whitelist user A

        let aaa_addr = @0xAAA;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);
        let sxinit_metadata = cabal::get_sxinit_metadata();

        let cycle = 1;
        let bridge_id = 101;
        let bribe_amount = 50_000000;
        let initial_stake_a = primary_fungible_store::balance(aaa_addr, sxinit_metadata);
        assert!(initial_stake_a > 0, 4001);
        let partial_unstake_amount = initial_stake_a / 2;
        let remaining_stake_a = initial_stake_a - partial_unstake_amount;

        // Deposit Bribe
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount, cycle, bridge_id);
        utils::increase_block(1, 1);

        // User A partially unstakes *before* snapshot/finalize
        cabal::mock_unstake(user_a, 0, partial_unstake_amount); // 0 for sxINIT
        assert!(primary_fungible_store::balance(aaa_addr, sxinit_metadata) == remaining_stake_a, 4002);
        utils::increase_block(1, 1);

        // Snapshot and Finalize Cycle
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // Verify User A has pending reward (should be full bribe as they were the only staker at snapshot)
        let reward_a_before_full_unstake = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        utils::test_with_slack(reward_a_before_full_unstake, bribe_amount, 1); // Still gets full reward

        // User A fully unstakes *after* finalize
        cabal::mock_unstake(user_a, 0, remaining_stake_a);
        assert!(primary_fungible_store::balance(aaa_addr, sxinit_metadata) == 0, 4003);
        utils::increase_block(1, 1);

        // Verify User A still has the same pending reward
        let reward_a_after_full_unstake = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        assert!(reward_a_after_full_unstake == reward_a_before_full_unstake, 4004);

        // Claim reward
        let initial_btc_balance = primary_fungible_store::balance(aaa_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        let final_btc_balance = primary_fungible_store::balance(aaa_addr, btc_metadata);
        assert!(final_btc_balance == initial_btc_balance + reward_a_after_full_unstake, 4005);
        assert!(voting_reward::get_unclaimed_voting_reward(aaa_addr, btc_metadata) == 0, 4006);
    }

    // Two users stake equal amounts, bribe happens, cycle ends, one user fully unstakes
    #[test(c=@staking_addr, user_a=@0xAAA, user_b=@0xBBB, user_d=@0xDDD)]
    fun test_two_stake_bribe_finalize_one_unstakes(c: &signer, user_a: &signer, user_b: &signer, user_d: &signer) {
        let stake_amount = 500_000_000_000; // 500k INIT each
        setup_multiple_stakers(c, user_a, user_d, stake_amount, stake_amount);
        cabal::init_fees_exempt(c);
        cabal::set_fees_exempt(c, vector[@0xAAA, @0xDDD]); // Whitelist both

        let aaa_addr = @0xAAA;
        let ddd_addr = @0xDDD;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let sxinit_metadata = cabal::get_sxinit_metadata();

        let cycle = 1;
        let bridge_id = 101;
        let bribe_amount = 100_000000; // 100 BTC

        // Deposit Bribe
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount, cycle, bridge_id);
        utils::increase_block(1, 1);

        // Snapshot and Finalize Cycle *before* unstake
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // Verify rewards are split ~50/50 before unstake
        let reward_a_before = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        let reward_d_before = voting_reward::get_single_reward(ddd_addr, btc_metadata);
        let expected_share = bribe_amount / 2;
        utils::test_with_slack(reward_a_before, expected_share, 1);
        utils::test_with_slack(reward_d_before, expected_share, 1);
        utils::test_with_slack(reward_a_before + reward_d_before, bribe_amount, 1);

        // User D fully unstakes *after* finalize
        let stake_d = primary_fungible_store::balance(ddd_addr, sxinit_metadata);
        utils::test_with_slack(stake_d, stake_amount, 1);
        cabal::mock_unstake(user_d, 0, stake_d);
        assert!(primary_fungible_store::balance(ddd_addr, sxinit_metadata) == 0, 4102);
        utils::increase_block(1, 1);

        // Verify rewards remain unchanged after unstake
        let reward_a_after = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        let reward_d_after = voting_reward::get_single_reward(ddd_addr, btc_metadata);
        utils::test_with_slack(reward_a_after, reward_a_before, 1);
        utils::test_with_slack(reward_d_after, reward_d_before, 1);

        // Claim rewards
        let initial_btc_a = primary_fungible_store::balance(aaa_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        let final_btc_a = primary_fungible_store::balance(aaa_addr, btc_metadata);
        assert!(final_btc_a == initial_btc_a + reward_a_after, 4105);

        let initial_btc_d = primary_fungible_store::balance(ddd_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_d, btc_metadata);
        let final_btc_d = primary_fungible_store::balance(ddd_addr, btc_metadata);
        assert!(final_btc_d == initial_btc_d + reward_d_after, 4106);
    }

    // 5. Two users stake equal amounts, bribe happens, one user unstakes half, cycle ends
    #[test(c=@staking_addr, user_a=@0xAAA, user_b=@0xBBB, user_d=@0xDDD)]
    fun test_two_stake_bribe_one_unstakes_half_finalize(c: &signer, user_a: &signer, user_b: &signer, user_d: &signer) {
        let stake_amount = 500_000_000_000; // 500k INIT each
        setup_multiple_stakers(c, user_a, user_d, stake_amount, stake_amount);
        cabal::init_fees_exempt(c);
        cabal::set_fees_exempt(c, vector[@0xAAA, @0xDDD]); // Whitelist both

        let aaa_addr = @0xAAA;
        let ddd_addr = @0xDDD;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let sxinit_metadata = cabal::get_sxinit_metadata();

        let cycle = 1;
        let bridge_id = 101;
        let bribe_amount = 100_000000; // 100 BTC
        let partial_unstake_amount_d = stake_amount / 2;
        let remaining_stake_d = stake_amount - partial_unstake_amount_d;

        // Deposit Bribe
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount, cycle, bridge_id);
        utils::increase_block(1, 1);

        // User D unstakes half *before* snapshot/finalize
        let stake_d_before = primary_fungible_store::balance(ddd_addr, sxinit_metadata);
        utils::test_with_slack(stake_d_before, stake_amount, 1);
        cabal::mock_unstake(user_d, 0, partial_unstake_amount_d);
        utils::test_with_slack(primary_fungible_store::balance(ddd_addr, sxinit_metadata), remaining_stake_d, 1);
        utils::increase_block(1, 1);

        // Snapshot and Finalize Cycle
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // Verify rewards are split based on snapshot stake (A: 500k, D: 250k => A: 2/3, D: 1/3)
        let reward_a = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        let reward_d = voting_reward::get_single_reward(ddd_addr, btc_metadata);

        let expected_share_a = bribe_amount * 2 / 3;
        let expected_share_d = bribe_amount / 3;

        utils::test_with_slack(reward_a, expected_share_a, 1);
        utils::test_with_slack(reward_d, expected_share_d, 1);
        utils::test_with_slack(reward_a + reward_d, bribe_amount, 1);

        // Claim rewards
        let initial_btc_a = primary_fungible_store::balance(aaa_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        let final_btc_a = primary_fungible_store::balance(aaa_addr, btc_metadata);
        assert!(final_btc_a == initial_btc_a + reward_a, 4203);

        let initial_btc_d = primary_fungible_store::balance(ddd_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_d, btc_metadata);
        let final_btc_d = primary_fungible_store::balance(ddd_addr, btc_metadata);
        assert!(final_btc_d == initial_btc_d + reward_d, 4204);
    }

    // 6. Two users stake equal amounts, one user fully unstakes, bribe happens, cycle ends
    #[test(c=@staking_addr, user_a=@0xAAA, user_b=@0xBBB, user_d=@0xDDD)]
    fun test_two_stake_one_unstakes_bribe_finalize(c: &signer, user_a: &signer, user_b: &signer, user_d: &signer) {
        let stake_amount = 500_000_000_000; // 500k INIT each
        setup_multiple_stakers(c, user_a, user_d, stake_amount, stake_amount);
        cabal::init_fees_exempt(c);
        cabal::set_fees_exempt(c, vector[@0xAAA, @0xDDD]); // Whitelist both

        let aaa_addr = @0xAAA;
        let ddd_addr = @0xDDD;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let sxinit_metadata = cabal::get_sxinit_metadata();

        let cycle = 1;
        let bridge_id = 101;
        let bribe_amount = 100_000000; // 100 BTC

        // User D fully unstakes *before* bribe and snapshot
        let stake_d_before = primary_fungible_store::balance(ddd_addr, sxinit_metadata);
        utils::test_with_slack(stake_d_before, stake_amount, 1);
        cabal::mock_unstake(user_d, 0, stake_d_before);
        assert!(primary_fungible_store::balance(ddd_addr, sxinit_metadata) == 0, 4302);
        utils::increase_block(1, 1);

        // Deposit Bribe
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount, cycle, bridge_id);
        utils::increase_block(1, 1);

        // Snapshot and Finalize Cycle
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // Verify rewards: A gets 100%, D gets 0%
        let reward_a = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        let reward_d = voting_reward::get_single_reward(ddd_addr, btc_metadata);

        utils::test_with_slack(reward_a, bribe_amount, 1);
        assert!(reward_d == 0, 4303);

        // Claim rewards
        let initial_btc_a = primary_fungible_store::balance(aaa_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        let final_btc_a = primary_fungible_store::balance(aaa_addr, btc_metadata);
        assert!(final_btc_a == initial_btc_a + reward_a, 4304);

        // User D should not be able to claim (test separately if needed, expect failure)
    }

    // 7. Two users stake equal amounts, one user unstakes half, bribe happens, cycle ends
    #[test(c=@staking_addr, user_a=@0xAAA, user_b=@0xBBB, user_d=@0xDDD)]
    fun test_two_stake_one_unstakes_half_bribe_finalize(c: &signer, user_a: &signer, user_b: &signer, user_d: &signer) {
        let stake_amount = 500_000_000_000; // 500k INIT each
        setup_multiple_stakers(c, user_a, user_d, stake_amount, stake_amount);
        cabal::init_fees_exempt(c);
        cabal::set_fees_exempt(c, vector[@0xAAA, @0xDDD]); // Whitelist both

        let aaa_addr = @0xAAA;
        let ddd_addr = @0xDDD;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let sxinit_metadata = cabal::get_sxinit_metadata();

        let cycle = 1;
        let bridge_id = 101;
        let bribe_amount = 100_000000; // 100 BTC
        let partial_unstake_amount_d = stake_amount / 2;
        let remaining_stake_d = stake_amount - partial_unstake_amount_d;

        // User D unstakes half *before* bribe and snapshot
        let stake_d_before = primary_fungible_store::balance(ddd_addr, sxinit_metadata);
        utils::test_with_slack(stake_d_before, stake_amount, 1);
        cabal::mock_unstake(user_d, 0, partial_unstake_amount_d);
        utils::test_with_slack(primary_fungible_store::balance(ddd_addr, sxinit_metadata), remaining_stake_d, 1);
        utils::increase_block(1, 1);

        // Deposit Bribe
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount, cycle, bridge_id);
        utils::increase_block(1, 1);

        // Snapshot and Finalize Cycle
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle, snapshot_height);

        // Verify rewards are split based on snapshot stake (A: 500k, D: 250k => A: 2/3, D: 1/3)
        let reward_a = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        let reward_d = voting_reward::get_single_reward(ddd_addr, btc_metadata);

        let expected_share_a = bribe_amount * 2 / 3;
        let expected_share_d = bribe_amount / 3;

        utils::test_with_slack(reward_a, expected_share_a, 1);
        utils::test_with_slack(reward_d, expected_share_d, 1);
        utils::test_with_slack(reward_a + reward_d, bribe_amount, 1);

        // Claim rewards
        let initial_btc_a = primary_fungible_store::balance(aaa_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        let final_btc_a = primary_fungible_store::balance(aaa_addr, btc_metadata);
        assert!(final_btc_a == initial_btc_a + reward_a, 4403);

        let initial_btc_d = primary_fungible_store::balance(ddd_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_d, btc_metadata);
        let final_btc_d = primary_fungible_store::balance(ddd_addr, btc_metadata);
        assert!(final_btc_d == initial_btc_d + reward_d, 4404);
    }

    // 8. Two users stake equal amounts, bribe, cycle ends, one user unstakes half, bribe happens, next cycle ends
    #[test(c=@staking_addr, user_a=@0xAAA, user_b=@0xBBB, user_d=@0xDDD)]
    fun test_two_stake_bribe_finalize_unstake_half_bribe_finalize(c: &signer, user_a: &signer, user_b: &signer, user_d: &signer) {
        let stake_amount = 500_000_000_000; // 500k INIT each
        setup_multiple_stakers(c, user_a, user_d, stake_amount, stake_amount);
        cabal::init_fees_exempt(c);
        cabal::set_fees_exempt(c, vector[@0xAAA, @0xDDD]); // Whitelist both

        let aaa_addr = @0xAAA;
        let ddd_addr = @0xDDD;
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let sxinit_metadata = cabal::get_sxinit_metadata();

        let bridge_id = 101;
        let bribe_amount_c1 = 100_000000; // 100 BTC
        let bribe_amount_c2 = 90_000000;  // 90 BTC

        // --- Cycle 1 ---
        let cycle1 = 1;
        // Deposit Bribe C1
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount_c1, cycle1, bridge_id);
        utils::increase_block(1, 1);
        // Snapshot and Finalize C1
        let snapshot_height1 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle1, snapshot_height1);

        // Verify C1 rewards (50/50 split)
        let reward_a_c1 = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        let reward_d_c1 = voting_reward::get_single_reward(ddd_addr, btc_metadata);
        let expected_share_c1 = bribe_amount_c1 / 2;
        utils::test_with_slack(reward_a_c1, expected_share_c1, 1);
        utils::test_with_slack(reward_d_c1, expected_share_c1, 1);

        // --- User D unstakes half *after* C1 finalize ---
        let partial_unstake_amount_d = stake_amount / 2;
        let remaining_stake_d = stake_amount - partial_unstake_amount_d;
        let stake_d_before = primary_fungible_store::balance(ddd_addr, sxinit_metadata);
        utils::test_with_slack(stake_d_before, stake_amount, 1);
        cabal::mock_unstake(user_d, 0, partial_unstake_amount_d);
        utils::test_with_slack(primary_fungible_store::balance(ddd_addr, sxinit_metadata),remaining_stake_d, 1);
        utils::increase_block(1, 1);

        // --- Cycle 2 ---
        let cycle2 = 2;
        // Deposit Bribe C2
        bribe::mock_deposit_bribe(user_b, btc_metadata, bribe_amount_c2, cycle2, bridge_id);
        utils::increase_block(1, 1);
        // Snapshot and Finalize C2
        let snapshot_height2 = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        voting_reward::finalize_reward_cycle(c, cycle2, snapshot_height2);

        // Verify total rewards after C2
        let total_reward_a = voting_reward::get_single_reward(aaa_addr, btc_metadata);
        let total_reward_d = voting_reward::get_single_reward(ddd_addr, btc_metadata);

        // Calculate expected C2 rewards (A: 500k, D: 250k => A: 2/3, D: 1/3)
        let expected_reward_a_c2 = bribe_amount_c2 * 2 / 3;
        let expected_reward_d_c2 = bribe_amount_c2 / 3;

        // Check total rewards = C1 reward + C2 reward
        utils::test_with_slack(total_reward_a, reward_a_c1 + expected_reward_a_c2, 1);
        utils::test_with_slack(total_reward_d, reward_d_c1 + expected_reward_d_c2, 1);

        // Claim rewards
        let initial_btc_a = primary_fungible_store::balance(aaa_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_a, btc_metadata);
        let final_btc_a = primary_fungible_store::balance(aaa_addr, btc_metadata);
        assert!(final_btc_a == initial_btc_a + total_reward_a, 4503);
        assert!(voting_reward::get_unclaimed_voting_reward(aaa_addr, btc_metadata) == 0, 4504);

        let initial_btc_d = primary_fungible_store::balance(ddd_addr, btc_metadata);
        voting_reward::claim_voting_reward(user_d, btc_metadata);
        let final_btc_d = primary_fungible_store::balance(ddd_addr, btc_metadata);
        assert!(final_btc_d == initial_btc_d + total_reward_d, 4505);
        assert!(voting_reward::get_unclaimed_voting_reward(ddd_addr, btc_metadata) == 0, 4506);
    }
    
}