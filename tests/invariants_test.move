#[test_only]
module staking_addr::invariants_test {
    // Standard Library Imports
    use std::error;
    use std::option::{Self, Option};
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

    // External Dependencies (if needed by functions or setup)
    use vip::lock_staking;
    use vip::weight_vote;
    use vip::vip; // Likely needed if interacting with VIP cycles/rewards

    // Test Setup Function (Adapted from other tests)
    // This setup initializes necessary modules and creates some initial state.
    fun test_setup(c: &signer): (object::Object<fungible_asset::Metadata>, object::Object<fungible_asset::Metadata>, object::Object<fungible_asset::Metadata>, coin::MintCapability) {
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

        let (init_mint_cap, _, _) = coin::initialize(
            initia_signer,
            option::none(),
            string::utf8(b"init token"),
            string::utf8(b"uinit"),
            6, // decimals
            string::utf8(b""),
            string::utf8(b"")
        );
        let init_metadata = coin::metadata(@initia_std, string::utf8(b"uinit"));
        // Mint plenty of INIT to the deployer/test account 'c'
        coin::mint_to(&init_mint_cap, signer::address_of(c), 1_000_000_000_000_000_000); 

        // Initialize the main cabal module
        cabal::initialize(c, string::utf8(b"initvaloper1test"), signer::address_of(c)); // Use 'c' as commission addr

        utils::increase_block(1, 1);

        // --- Setup Bribe Token (e.g., BTC) ---
        let (_, _, btc_mint) = utils::initialize_coin_for_testing(initia_signer, string::utf8(b"btc"));
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let btc_usd_pair_id = string::utf8(b"btc/usd");
        oracle::set_price(&btc_usd_pair_id, 50000_000000, 1000002, 8); // $50k per BTC
        bribe::set_allowed_bribe_tokens(c, vector[btc_metadata]);
        // Mint some BTC to potential bribers
        coin::mint_to(&btc_mint, @0xBBB, 10_00000000); // 10 BTC to User B
        coin::mint_to(&btc_mint, @0xCCC, 10_00000000); // 10 BTC to User C

        utils::increase_block(1, 1); // Final block advance after setup

        (init_metadata, cabal::get_xinit_metadata(), cabal::get_sxinit_metadata(), btc_mint)
    }

    //Total INIT \approx Total xINIT
    #[test(c = @staking_addr, user_a = @0xAAA, user_b = @0xBBB)]
    fun test_invariant_init_vs_xinit(c: &signer, user_a: &signer, user_b: &signer) {
        let (init_metadata, xinit_metadata, _, _) = test_setup(c);
        let aaa_addr = signer::address_of(user_a);
        let bbb_addr = signer::address_of(user_b);

        let initial_total_init = cabal::get_pool_router_total_init();
        let initial_xinit_supply = cabal::get_xinit_total_supply();
        assert!(initial_total_init == (initial_xinit_supply as u64), 101);

        // User A deposits
        let deposit_a = 500_000_000_000;
        primary_fungible_store::transfer(c, init_metadata, aaa_addr, deposit_a);
        cabal::mock_deposit_init_for_xinit(user_a, deposit_a);
        utils::increase_block(1, 1);

        let total_init_after_a = cabal::get_pool_router_total_init();
        let xinit_supply_after_a = cabal::get_xinit_total_supply();
        utils::test_with_slack(total_init_after_a, xinit_supply_after_a as u64, 1);

        // User B deposits
        let deposit_b = 250_000_000_000;
        primary_fungible_store::transfer(c, init_metadata, bbb_addr, deposit_b);
        cabal::mock_deposit_init_for_xinit(user_b, deposit_b);
        utils::increase_block(1, 1);

        let total_init_after_b = cabal::get_pool_router_total_init();
        let xinit_supply_after_b = cabal::get_xinit_total_supply();
        utils::test_with_slack(total_init_after_b, xinit_supply_after_b as u64, 1);

        //User A stakes
        cabal::mock_stake(user_a, 0, 100_000_000_000);
        utils::increase_block(1, 1);

        let total_init_after_stake = cabal::get_pool_router_total_init();
        let xinit_supply_after_stake = cabal::get_xinit_total_supply();
        utils::test_with_slack(total_init_after_stake, xinit_supply_after_stake as u64, 1);
    }//TODO: Add validator rewards to here, to see if that still holds

    // Deposit 1 INIT -> Get 1 xINIT (ignoring fees/rewards)
    #[test(c = @staking_addr, user_a = @0xAAA)]
    fun test_invariant_deposit_ratio(c: &signer, user_a: &signer) {
        let (init_metadata, xinit_metadata, _, _) = test_setup(c);
        let aaa_addr = signer::address_of(user_a);

        let deposit_amount = 1_000_000;
        primary_fungible_store::transfer(c, init_metadata, aaa_addr, deposit_amount);

        let initial_xinit_balance = balance(aaa_addr, xinit_metadata);

        // Deposit 1 INIT
        cabal::mock_deposit_init_for_xinit(user_a, deposit_amount);
        utils::increase_block(1, 1);

        let final_xinit_balance = balance(aaa_addr, xinit_metadata);
        let minted_xinit = final_xinit_balance - initial_xinit_balance;

        assert!(minted_xinit == deposit_amount || minted_xinit == deposit_amount - 1, 201);

        deposit_amount = 500_000_000_000;
        primary_fungible_store::transfer(c, init_metadata, aaa_addr, deposit_amount);
        cabal::mock_deposit_init_for_xinit(user_a, deposit_amount);
        utils::increase_block(1, 1);

        let xinit_balance_2 = balance(aaa_addr, xinit_metadata);
        let minted_xinit_2 = xinit_balance_2 - final_xinit_balance;

        assert!(minted_xinit_2 == deposit_amount || minted_xinit_2 == deposit_amount - 1, 202);
    }

    // sum(snapshot balances) == snapshot supply
    #[test(c = @staking_addr, user_a = @0xAAA, user_b = @0xBBB)]
    fun test_invariant_snapshot_balance_vs_supply(c: &signer, user_a: &signer, user_b: &signer) {
        let (init_metadata, xinit_metadata, sxinit_metadata, _) = test_setup(c);
        let aaa_addr = signer::address_of(user_a);
        let bbb_addr = signer::address_of(user_b);

        // User A stakes
        let stake_a = 500_000_000_000;
        primary_fungible_store::transfer(c, init_metadata, aaa_addr, stake_a);
        cabal::mock_deposit_init_for_xinit(user_a, stake_a);
        let xinit_a = balance(aaa_addr, xinit_metadata);
        cabal::mock_stake(user_a, 0, xinit_a); // Stake sxINIT
        utils::increase_block(1, 1);

        // User B stakes
        let stake_b = 300_000_000_000;
        primary_fungible_store::transfer(c, init_metadata, bbb_addr, stake_b);
        cabal::mock_deposit_init_for_xinit(user_b, stake_b);
        let xinit_b = balance(bbb_addr, xinit_metadata);
        cabal::mock_stake(user_b, 0, xinit_b); // Stake sxINIT
        utils::increase_block(1, 1);

        // Take snapshot
        let snapshot_height = block::get_current_block_height();
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1);
        assert!(snapshots::has_snapshot_at(snapshot_height), 301);

        let snapshot_supply = cabal_token::get_snapshot_supply(sxinit_metadata, snapshot_height);
        let snapshot_balance_a = cabal_token::get_snapshot_balance(aaa_addr, sxinit_metadata, snapshot_height);
        let snapshot_balance_b = cabal_token::get_snapshot_balance(bbb_addr, sxinit_metadata, snapshot_height);
        // there is 100 INIT from the cabal initialization, that are from the staking addr
        let snapshot_balance_contract = cabal_token::get_snapshot_balance(signer::address_of(c), sxinit_metadata, snapshot_height);


        let sum_balances = (snapshot_balance_a as u128)+ (snapshot_balance_b as u128) + (snapshot_balance_contract as u128);

        assert!(snapshot_supply == sum_balances, 302);
    }

    // sum(bribe weights) == 1
    #[test(c = @staking_addr, user_b = @0xBBB, user_c = @0xCCC)]
    fun test_invariant_bribe_weights_sum(c: &signer, user_b: &signer, user_c: &signer) {
        let (_, _, _, btc_mint) = test_setup(c);
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));

        let cycle = 10;
        let bridge_id_1 = 1;
        let bridge_id_2 = 2;
        let bridge_id_3 = 3;

        bribe::mock_deposit_bribe(user_b, btc_metadata, 2_000000, cycle, bridge_id_1); // 2 BTC
        bribe::mock_deposit_bribe(user_c, btc_metadata, 3_000000, cycle, bridge_id_2); // 3 BTC
        bribe::mock_deposit_bribe(user_b, btc_metadata, 5_000000, cycle, bridge_id_3); // 5 BTC

        let weights = bribe::calculate_bribe_weights_for_cycle(cycle);
        assert!(vector::length(&weights) == 3, 401); 

        // Sum the weights
        let total_weight = bigdecimal::zero();
        let i = 0;
        while (i < vector::length(&weights)) {
            let weight_response = vector::borrow(&weights, i);
            let weight = bribe::get_bridge_reward_response_weight(weight_response);
            total_weight = bigdecimal::add(total_weight, weight);
            i = i + 1;
        };

        // Check if the sum is approximately 1 (allow for tiny precision errors)
        let one = bigdecimal::one();
        utils::test_with_slack((bigdecimal::mul_by_u64_truncate(total_weight, 1_000_000_000_000) as u64),1_000_000_000_000, 1);
    }
    // sum(bribe weights) == 1, with many bribes and bridges
    #[test(c = @staking_addr, user_b = @0xBBB, user_c = @0xCCC, user_d = @0xDDD, user_e = @0xEEE)]
    fun test_invariant_bribe_weights_sum_many_bribes(
        c: &signer, 
        user_b: &signer, 
        user_c: &signer,
        user_d: &signer,
        user_e: &signer
    ) {
        let (_, _, _, btc_mint) = test_setup(c);
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        
        // Get user addresses for later use
        let addr_b = signer::address_of(user_b);
        let addr_c = signer::address_of(user_c);
        let addr_d = signer::address_of(user_d);
        let addr_e = signer::address_of(user_e);


        coin::mint_to(&btc_mint, addr_b, 1_000_000_00000000); 
        coin::mint_to(&btc_mint, addr_c, 1_000_000_00000000); 
        coin::mint_to(&btc_mint, addr_d, 1_000_000_00000000); 
        coin::mint_to(&btc_mint, addr_e, 1_000_000_00000000); 
        
        let cycle = 10;
        let num_bridges = 1_000;
        let total_bribes = 0;
        
        // Array of users to cycle through for bribes
        let users = vector[signer::address_of(user_b), signer::address_of(user_c), signer::address_of(user_d), signer::address_of(user_e)];
        
        // Create a variety of bribe amounts - small to large
        let bribe_amounts = vector[
            0_000001,   
            0_000010,   
            0_000100,   
            0_001000,   
            0_010000,   
            0_100000,   
            1_000000,   
            2_500000,   
            5_000000,   
            7_500000,
            10_000000,
            100_000000,
            1_000_000000,
        ];
        
        // Deposit bribes to bridges in a loop
        let bridge_id = 1;
        while (bridge_id <= num_bridges) {
            // Select a user (cycling through the list)
            let user_index = (bridge_id - 1) % vector::length(&users);
            let user = &account::create_signer_for_test(*vector::borrow(&users, user_index));
            
            // Select a bribe amount (cycling through list, but with some variation)
            let amount_index = (bridge_id * 7) % vector::length(&bribe_amounts); // Use multiplication for more variation
            let bribe_amount = *vector::borrow(&bribe_amounts, amount_index);
            
            // add second bribe
            if (bridge_id % 3 == 0) {
                // Add a second bribe to every 5th bridge
                let second_user_index = (user_index + 1) % vector::length(&users);
                let second_user = &account::create_signer_for_test(*vector::borrow(&users, second_user_index));
                let second_amount_index = (bridge_id * 3) % vector::length(&bribe_amounts);
                let second_bribe_amount = *vector::borrow(&bribe_amounts, second_amount_index);
                
                bribe::mock_deposit_bribe(second_user, btc_metadata, second_bribe_amount, cycle, bridge_id);
                total_bribes = total_bribes + 1;
            };
            
            // For some bridges, add a third bribe
            if (bridge_id % 5 == 0) {
                // Add a third bribe to every 10th bridge
                let third_user_index = (user_index + 2) % vector::length(&users);
                let third_user = &account::create_signer_for_test(*vector::borrow(&users, third_user_index));
                let third_amount_index = (bridge_id * 11) % vector::length(&bribe_amounts);
                let third_bribe_amount = *vector::borrow(&bribe_amounts, third_amount_index);
                
                bribe::mock_deposit_bribe(third_user, btc_metadata, third_bribe_amount, cycle, bridge_id);
                total_bribes = total_bribes + 1;
            };
            
            // Deposit the main bribe
            bribe::mock_deposit_bribe(user, btc_metadata, bribe_amount, cycle, bridge_id);
            total_bribes = total_bribes + 1;
            
            bridge_id = bridge_id + 1;
        };
        
        // Calculate and verify weights
        let weights = bribe::calculate_bribe_weights_for_cycle(cycle);
        
        // We should have weights for all bridges with bribes (some bridges have multiple bribes)
        assert!(vector::length(&weights) == num_bridges, 601);
        
        // Sum the weights - should still add up to 1
        let total_weight = bigdecimal::zero();
        let i = 0;
        while (i < vector::length(&weights)) {
            let weight_response = vector::borrow(&weights, i);
            let weight = bribe::get_bridge_reward_response_weight(weight_response);
            
            // Debug output for weight inspection (optional)
            // debug::print(&weight);
            
            // Each weight should be between 0 and 1
            assert!(bigdecimal::le(weight, bigdecimal::one()), 602);
            assert!(bigdecimal::ge(weight, bigdecimal::zero()), 603);
            
            total_weight = bigdecimal::add(total_weight, weight);
            i = i + 1;
        };
        
        // Check if the sum is approximately 1 (allow for tiny precision errors)
        // Convert to integer representation for easier comparison with slack
        let scaled_weight = bigdecimal::mul_by_u64_truncate(total_weight, 1_000_000_000_000) as u64;
        let expected = 1_000_000_000_000;
    
        utils::test_with_slack(scaled_weight, expected, 1);
    }

    // weight sum invariant does not hold when there are no bribes, should be obv, but still
    #[test(c = @staking_addr)]
    fun test_invariant_bribe_weights_sum_no_bribes(c: &signer) {
        test_setup(c);
        let cycle = 11; 
        let weights = bribe::calculate_bribe_weights_for_cycle(cycle);
        assert!(vector::is_empty(&weights), 501);

        // should be 0
        let total_weight = bigdecimal::zero();
        assert!(bigdecimal::eq(total_weight, bigdecimal::zero()), 502);
    }

    // Stress test for test_invariant_init_vs_xinit
    #[test(
        c = @staking_addr, user_a = @0xAAA, user_b = @0xBBB, user_c = @0xCCC, user_d = @0xDDD,
        user_e = @0xEEE, user_f = @0xFFF, user_g = @0x111, user_h = @0x222
    )]
    fun test_stress_invariant_init_vs_xinit(
        c: &signer, user_a: &signer, user_b: &signer, user_c: &signer, user_d: &signer,
        user_e: &signer, user_f: &signer, user_g: &signer, user_h: &signer
    ) {
        let (init_metadata, _, _, _) = test_setup(c);

        let users = vector[signer::address_of(user_a), signer::address_of(user_b), signer::address_of(user_c), signer::address_of(user_d), signer::address_of(user_e), signer::address_of(user_f), signer::address_of(user_g), signer::address_of(user_h)];
        let deposit_amounts = vector[
            1,                  // Very small
            100,
            1_000_000,          // Medium
            50_000_000,
            100_000_000_000,    // Large
            500_000_000_000,
            1_000_000_000_000_000 // Very large
        ];
        let stake_fractions = vector[0, 10, 25, 50, 75, 90, 100]; // Percentage to stake

        let num_users = vector::length(&users);
        let num_deposits = vector::length(&deposit_amounts);
        let num_stakes = vector::length(&stake_fractions);

        let i = 0;
        while (i < num_users) {
            let user = &account::create_signer_for_test(*vector::borrow(&users, i));
            let user_addr = signer::address_of(user);

            // Check invariant before user actions
            let total_init_before = cabal::get_pool_router_total_init();
            let xinit_supply_before = cabal::get_xinit_total_supply();
            utils::test_with_slack(total_init_before, xinit_supply_before as u64, 1);

            // Deposit varying amounts
            let j = 0;
            while (j < num_deposits) {
                let deposit_amount = *vector::borrow(&deposit_amounts, j);
                // Ensure user has enough INIT (mint if necessary, assuming 'c' has infinite)
                if (balance(user_addr, init_metadata) < deposit_amount) {
                     primary_fungible_store::transfer(c, init_metadata, user_addr, deposit_amount * 2); // Give them extra
                };

                cabal::mock_deposit_init_for_xinit(user, deposit_amount);
                utils::increase_block(1, 1);

                // Check invariant after deposit
                let total_init_after_deposit = cabal::get_pool_router_total_init();
                let xinit_supply_after_deposit = cabal::get_xinit_total_supply();
                utils::test_with_slack(total_init_after_deposit, xinit_supply_after_deposit as u64, 1);

                j = j + 1;
            };

            // Stake varying fractions
            let k = 0;
            while (k < num_stakes) {
                let fraction = *vector::borrow(&stake_fractions, k);
                let current_xinit = balance(user_addr, cabal::get_xinit_metadata());
                if (current_xinit > 0 && fraction > 0) {
                    let stake_amount = (current_xinit as u128) * (fraction as u128) / 100;
                     if (stake_amount > 0) {
                        cabal::mock_stake(user, 0, stake_amount as u64);
                        utils::increase_block(1, 1);

                        // Check invariant after stake
                        let total_init_after_stake = cabal::get_pool_router_total_init();
                        let xinit_supply_after_stake = cabal::get_xinit_total_supply();
                        utils::test_with_slack(total_init_after_stake, xinit_supply_after_stake as u64, 1);
                     };
                };
                k = k + 1;
            };
            i = i + 1;
        };
    }

    // Stress test for test_invariant_deposit_ratio
    #[test(
        c = @staking_addr, user_a = @0xAAA, user_b = @0xBBB, user_c = @0xCCC, user_d = @0xDDD
    )]
    fun test_stress_invariant_deposit_ratio(
        c: &signer, user_a: &signer, user_b: &signer, user_c: &signer, user_d: &signer
    ) {
        let (init_metadata, xinit_metadata, _, _) = test_setup(c);

        let users = vector[signer::address_of(user_a), signer::address_of(user_b), signer::address_of(user_c), signer::address_of(user_d)];
        let deposit_amounts = vector[
            1,                  // Very small
            10,
            100,
            1_000,
            10_000,
            100_000,
            1_000_000,          // Medium
            50_000_000,
            100_000_000_000,    // Large
            500_000_000_000,
            1_000_000_000_000_000 // Very large
        ];

        let num_users = vector::length(&users);
        let num_deposits = vector::length(&deposit_amounts);

        let i = 0;
        while (i < num_users) {
            let user = &account::create_signer_for_test(*vector::borrow(&users, i));
            let user_addr = signer::address_of(user);

            let j = 0;
            while (j < num_deposits) {
                let deposit_amount = *vector::borrow(&deposit_amounts, j);

                // Ensure user has enough INIT
                 primary_fungible_store::transfer(c, init_metadata, user_addr, deposit_amount);

                let initial_xinit_balance = balance(user_addr, xinit_metadata);

                // Deposit INIT
                cabal::mock_deposit_init_for_xinit(user, deposit_amount);
                utils::increase_block(1, 1);

                let final_xinit_balance = balance(user_addr, xinit_metadata);
                let minted_xinit = final_xinit_balance - initial_xinit_balance;

                // Check the ratio: minted xINIT should be equal to deposited INIT (or off by 1)
                assert!(minted_xinit == deposit_amount || minted_xinit == deposit_amount - 1, (2000 + i * 100 + j) as u64);

                j = j + 1;
            };
            i = i + 1;
        };
    }


    // Stress test for test_invariant_snapshot_balance_vs_supply
    #[test(
        c = @staking_addr, user_a = @0xAAA, user_b = @0xBBB, user_c = @0xCCC, user_d = @0xDDD,
        user_e = @0xEEE, user_f = @0xFFF, user_g = @0x111, user_h = @0x222,
        user_i = @0x333, user_j = @0x444
    )]
    fun test_stress_invariant_snapshot_balance_vs_supply(
        c: &signer, user_a: &signer, user_b: &signer, user_c: &signer, user_d: &signer,
        user_e: &signer, user_f: &signer, user_g: &signer, user_h: &signer,
        user_i: &signer, user_j: &signer
    ) {
        let (init_metadata, xinit_metadata, sxinit_metadata, _) = test_setup(c);

                let users = vector[signer::address_of(user_a), signer::address_of(user_b), signer::address_of(user_c), signer::address_of(user_d), signer::address_of(user_e), signer::address_of(user_f), signer::address_of(user_g), signer::address_of(user_h), signer::address_of(user_i),signer::address_of(user_j)];

        let stake_amounts = vector[
            1,                  // Very small
            1_000,
            100_000,
            1_000_000,          // Medium
            500_000_000,
            10_000_000_000,    // Large
            250_000_000_000,
            1_000_000_000_000 // Very large
        ];

        let num_users = vector::length(&users);
        let num_stakes = vector::length(&stake_amounts);
        let user_addrs = vector::empty<address>();

        let k = 0;
        while (k < num_users) {
            let user = &account::create_signer_for_test(*vector::borrow(&users, k));
            let user_addr = signer::address_of(user);
            vector::push_back(&mut user_addrs, user_addr);

            // Alternate between staking all and staking a portion based on stake_amounts index
            let stake_amount_index = k % num_stakes;
            let stake_amount = *vector::borrow(&stake_amounts, stake_amount_index);

            // Ensure user has enough INIT, deposit, and get xINIT
             primary_fungible_store::transfer(c, init_metadata, user_addr, stake_amount * 2); // Give extra
             cabal::mock_deposit_init_for_xinit(user, stake_amount);
             utils::increase_block(1, 1);

            let current_xinit = balance(user_addr, xinit_metadata);

            // Stake either the calculated amount or all available xINIT, whichever is smaller
            let actual_stake = if (current_xinit < stake_amount) { current_xinit } else { stake_amount };

            k = k + 1;
        };

        // Take snapshot
        let snapshot_height = block::get_current_block_height() + 1; // Predict next block height
        utils::increase_block(1, 1); // Advance to the height we want to snapshot
        voting_reward::mock_snapshot(c);
        utils::increase_block(1, 1); // Advance block after snapshot
        assert!(snapshots::has_snapshot_at(snapshot_height), 3001);

        // Verify invariant
        let snapshot_supply = cabal_token::get_snapshot_supply(sxinit_metadata, snapshot_height);
        let total_snapshot_balance = 0u128;

        // Add contract's balance (initial stake)
        total_snapshot_balance = total_snapshot_balance + (cabal_token::get_snapshot_balance(signer::address_of(c), sxinit_metadata, snapshot_height) as u128);

        // Add balances of all test users
        let m = 0;
        while (m < num_users) {
            let user_addr = *vector::borrow(&user_addrs, m);
            let user_balance = cabal_token::get_snapshot_balance(user_addr, sxinit_metadata, snapshot_height);
            total_snapshot_balance = total_snapshot_balance + (user_balance as u128);
            m = m + 1;
        };

        // Allow potential slack due to multiple operations and potential rounding
        utils::test_with_slack(snapshot_supply as u64, total_snapshot_balance as u64, 1);
    }
}