// for vip setup for bridge_ids:
// public fun test_setup(
//         chain: &signer,
//         vip: &signer,
//         operator: &signer,
//         bridge_id: u64,
//         bridge_address: address,
//         vip_l2_score_contract: string::String,
//         mint_amount: u64
//     ):
// fun test_register_bridge(
//         chain: &signer,
//         operator: &signer,
//         bridge_id: u64,
//         bridge_address: address,
//         vip_l2_score_contract: string::String,
//         mint_amount: u64,
//         commission_max_rate: BigDecimal,
//         commission_max_change_rate: BigDecimal,
//         commission_rate: BigDecimal,
//         mint_cap: &coin::MintCapability
//     ):




#[test_only]
module staking_addr::bribing_test {
    // Standard Library Imports
    use std::error;
    use std::option;
    use std::signer;
    use std::string::{Self, String};
    use std::vector;

    // Initia Standard Library Imports
    use initia_std::account;
    use initia_std::bigdecimal::{Self, BigDecimal};
    use initia_std::coin;
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
    use staking_addr::bribe; // The module under test
    use staking_addr::emergency; // Dependency for bribe::deposit_bribe
    use staking_addr::package; // Dependency for bribe::deposit_bribe & setup
    use staking_addr::utils; // For test setup helpers
    use staking_addr::manager;

    // External Dependencies (if needed by bribe functions or setup)
    use vip::vip; // Dependency for bribe::deposit_bribe

    // Import necessary types/functions from bribe module
    use staking_addr::bribe::{
        ModuleStore, // Needed for acquires in test functions
        SupportTokenResponse, // For view function test
        deposit_voting_reward_fee_bps,
        set_deposit_voting_reward_fee_bps,
        is_voting_reward_token,
        set_allowed_bribe_tokens,
        deposit_bribe,
        get_total_bribes_by_token_for_cycle,
        calculate_bribe_weights_for_cycle,
        init_module_for_test, // Still needed from the original module
        get_bridge_reward_response_amount,  // Getter for the test
        get_bridge_reward_response_bridge_id,
        get_bridge_reward_response_weight,
        mock_deposit_bribe
    };


    // Test Setup Function (Moved from bribe.move)
    public fun test_setup(c: &signer) {
        // init dependent moudule
        emergency::init_module_for_test(c);
        package::init_module_for_test(c);

        // vip
        vip::vip::test_setup(
            &account::create_signer_for_test(@initia_std),
            &account::create_signer_for_test(@vip),
            &account::create_signer_for_test(@0x56ccf33c45b99546cd1da172cf6849395bbf8573),
            1,
            @0x99,
            string::utf8(b"vip_l2_contract1"),
            1_000_000_000_000,
        );

        // mint token
        let (_, _, btc_mint) = utils::initialize_coin_for_testing(&account::create_signer_for_test(@initia_std), string::utf8(b"btc"));
        let (_, _, eth_mint) = utils::initialize_coin_for_testing(&account::create_signer_for_test(@initia_std), string::utf8(b"eth"));

        coin::mint_to(&btc_mint, @0x111111, 100_000000);
        coin::mint_to(&eth_mint, @0x111111, 10000_000000);

        coin::mint_to(&btc_mint, @0x222222, 100_000000);
        coin::mint_to(&eth_mint, @0x222222, 10000_000000);

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
    }

    // Test Functions (Moved from bribe.move)
    #[test(c=@staking_addr)]
    public fun test_set_deposit_voting_reward_fee_bps(c: &signer) { // Removed acquires ModuleStore
        init_module_for_test(c);
        let bps = deposit_voting_reward_fee_bps();
        assert!(bps == 0, 101);
        set_deposit_voting_reward_fee_bps(c, 100);
        let bps = deposit_voting_reward_fee_bps();
        assert!(bps == 100, 102);
    }

    #[test(c=@staking_addr)]
    public fun test_set_bribe_tokens(c: &signer) { // Removed acquires ModuleStore
        init_module_for_test(c);
        test_setup(c);

        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let eth_metadata = coin::metadata(@initia_std, string::utf8(b"eth"));

        assert!(!is_voting_reward_token(btc_metadata), 201);
        assert!(!is_voting_reward_token(eth_metadata), 202);

        set_allowed_bribe_tokens(c, vector[btc_metadata, eth_metadata]);
        assert!(is_voting_reward_token(btc_metadata), 203);
        assert!(is_voting_reward_token(eth_metadata), 204);
    }

    #[test(c=@staking_addr, user_a=@0x111111, user_b=@0x222222, )]
    public fun test_deposit_bribe(c: &signer, user_a: &signer, user_b: &signer) {
        init_module_for_test(c);
        test_setup(c);

        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let eth_metadata = coin::metadata(@initia_std, string::utf8(b"eth"));
        set_allowed_bribe_tokens(c, vector[btc_metadata, eth_metadata]);
        assert!(is_voting_reward_token(btc_metadata), 301);
        assert!(is_voting_reward_token(eth_metadata), 302);

        deposit_bribe(user_a, btc_metadata, 1_000000, 10, 1);
        let bribes = get_total_bribes_by_token_for_cycle(10);
        assert!(simple_map::contains_key(&bribes, &btc_metadata), 303);
        assert!(*simple_map::borrow(&bribes, &btc_metadata) == 1_000000, 304);

        set_deposit_voting_reward_fee_bps(c, 1000);

        deposit_bribe(user_a, eth_metadata, 1_000000, 10, 1);
        let bribes = get_total_bribes_by_token_for_cycle(10);
        assert!(simple_map::contains_key(&bribes, &eth_metadata), 305);
        assert!(*simple_map::borrow(&bribes, &eth_metadata) == 0_900000, 306);

        let weights = calculate_bribe_weights_for_cycle(10);
        assert!(vector::length(&weights) == 1, 307);
        // 100*1+10*0.9*10^6=109_000000
        assert!(get_bridge_reward_response_amount(&weights[0]) == 109_000000, 308);

    }

    // Test auth to set deposit reward fees
    #[test(c=@staking_addr, random_user=@0x333333)]
    #[expected_failure(location = staking_addr::bribe, abort_code = 0x40005)] // error:unauthenticated: 0x40000, EMODULE_OPERATION: 0x5
    public fun test_auth_random_user_cannot_set_params(c: &signer, random_user: &signer) {
        init_module_for_test(c);
        // Random user tries to set deposit fee
        set_deposit_voting_reward_fee_bps(random_user, 100);
    }

    // Test bribe token whitelist functionality
    #[test(c=@staking_addr, user_a=@0x111111)]
    #[expected_failure(loaction = staking_addr::bribe, abort_code = 0x10001)] // error::invalid_argument:0x10000  EINVALID_TOKEN: 0x1
    public fun test_non_whitelisted_token_cannot_bribe(c: &signer, user_a: &signer) {
        init_module_for_test(c);
        test_setup(c);

        // Create a new non-whitelisted token
        let (_, _, usdt_mint) = utils::initialize_coin_for_testing(
            &account::create_signer_for_test(@initia_std), 
            string::utf8(b"usdt")
        );
        
        // Mint usdt to user_a
        coin::mint_to(&usdt_mint, signer::address_of(user_a), 1000_000000);
        
        // Try to bribe with non-whitelisted token (should fail)
        let usdt_metadata = coin::metadata(@initia_std, string::utf8(b"usdt"));
        deposit_bribe(user_a, usdt_metadata, 100_000000, 15, 1);
    }

    // Test that bribes affect voting weights proportionally
    #[test(c=@staking_addr, user_a=@0x111111, user_b=@0x222222)]
    public fun test_bribes_affect_voting_weights_proportionally(c: &signer, user_a: &signer, user_b: &signer) {
        init_module_for_test(c);
        test_setup(c);
        
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let eth_metadata = coin::metadata(@initia_std, string::utf8(b"eth"));
        set_allowed_bribe_tokens(c, vector[eth_metadata, btc_metadata]);
        assert!(is_voting_reward_token(btc_metadata), 301);
        assert!(is_voting_reward_token(eth_metadata), 302);

        let cycle = 20;
        let bridge_id_1 = 1;
        let bridge_id_2 = 2;
        
        // User A bribes for bridge 1 with BTC
        mock_deposit_bribe(user_a, btc_metadata, 2_000000, cycle, bridge_id_1); // 2 BTC
        
        assert!(is_voting_reward_token(btc_metadata), 301);
        assert!(is_voting_reward_token(eth_metadata), 302);
        // User B bribes for bridge 2 with ETH
        mock_deposit_bribe(user_a, eth_metadata, 10_000000, cycle, bridge_id_2); // 10 ETH
        
        // Get weights for the cycle
        let weights = calculate_bribe_weights_for_cycle(cycle);
        assert!(vector::length(&weights) == 2, 401); // Should have weights for both bridges
        
        // Get individual weights
        let bridge_1_weight = bigdecimal::zero();
        let bridge_2_weight = bigdecimal::zero();
        
        for (i in 0..vector::length(&weights)) {
            let bridge_id = get_bridge_reward_response_bridge_id(&weights[i]);
            let weight = get_bridge_reward_response_weight(&weights[i]);
            
            if (bridge_id == bridge_id_1) {
                bridge_1_weight = weight;
            } else if (bridge_id == bridge_id_2) {
                bridge_2_weight = weight;
            };
        };
        
        let bridge_1_decimal = bigdecimal::truncate_u64(bigdecimal::mul_by_u64(bridge_1_weight, 100));
        let bridge_2_decimal = bigdecimal::truncate_u64(bigdecimal::mul_by_u64(bridge_2_weight, 100));
        
        assert!(bridge_1_decimal >= 66 && bridge_1_decimal <= 67, 402);
        assert!(bridge_2_decimal >= 33 && bridge_2_decimal <= 34, 403);
        assert!(bridge_1_decimal + bridge_2_decimal >= 99);
        assert!(bridge_1_decimal + bridge_2_decimal <= 100); 
    }

    // Test oracle price updates affect weights
    #[test(c=@staking_addr, user_a=@0x111111)]
    public fun test_oracle_price_updates_affect_weights(c: &signer, user_a: &signer) {
        init_module_for_test(c);
        test_setup(c);

        // Whitelist tokens
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        set_allowed_bribe_tokens(c, vector[btc_metadata]);
        
        // User makes an initial bribe
        let cycle = 25;
        let bridge_id = 1;
        mock_deposit_bribe(user_a, btc_metadata, 1_000000, cycle, bridge_id); // 1 BTC
        
        // Get initial weights
        let initial_weights = calculate_bribe_weights_for_cycle(cycle);
        assert!(vector::length(&initial_weights) == 1, 501);
        
        // Initial BTC price was 100 USD (10000000000 with 8 decimals)
        // Update BTC price to 200 USD
        let btc_usd_pair_id = string::utf8(b"btc/usd");
        let new_btc_price = 200_00000000_u256; // Double the price
        let btc_updated_at = 1000005;
        let btc_decimals = 8;
        
        oracle::set_price(
            &btc_usd_pair_id,
            new_btc_price,
            btc_updated_at,
            btc_decimals
        );
        
        // Make a second bribe for a different bridge with same amount
        let bridge_id_2 = 2;
        mock_deposit_bribe(user_a, btc_metadata, 1_000000, cycle, bridge_id_2); // Another 1 BTC
        
        // Get updated weights
        let updated_weights = calculate_bribe_weights_for_cycle(cycle);
        assert!(vector::length(&updated_weights) == 2, 502);
        
        // The two bribes should have equal weight now since they're both 1 BTC
        // at the same price (200 USD per BTC)
        let weight_1 = bigdecimal::zero();
        let weight_2 = bigdecimal::zero();
        
        for (i in 0..vector::length(&updated_weights)) {
            let bridge_id_here = get_bridge_reward_response_bridge_id(&updated_weights[i]);
            let weight = get_bridge_reward_response_weight(&updated_weights[i]);
            
            if (bridge_id_here == bridge_id) {
                weight_1 = weight;
            } else if (bridge_id_here == bridge_id_2) {
                weight_2 = weight;
            };
        };
        
        // Weights should be approximately equal (close to 0.5 each)
        let weight_1_decimal = bigdecimal::truncate_u64(bigdecimal::mul_by_u64(weight_1, 100));
        let weight_2_decimal = bigdecimal::truncate_u64(bigdecimal::mul_by_u64(weight_2, 100));
        
        assert!(weight_1_decimal >= 49 && weight_1_decimal <= 51, 503);
        assert!(weight_2_decimal >= 49 && weight_2_decimal <= 51, 504);
    }

    // Test oracle price updates affect weights
    #[test(c=@staking_addr, user_a=@0x111111)]
    public fun test_oracle_price_updates_affect_weights_diff_curr(c: &signer, user_a: &signer) {
        init_module_for_test(c);
        test_setup(c);

        // Whitelist tokens
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let eth_metadata = coin::metadata(@initia_std, string::utf8(b"eth"));
        set_allowed_bribe_tokens(c, vector[btc_metadata, eth_metadata]);
        assert!(is_voting_reward_token(btc_metadata), 301);
        assert!(is_voting_reward_token(eth_metadata), 302);

        /*
        From test_setup we get the current prices:

        let btc_price = 100_00000000_u256;
        let eth_price = 10_000000000000000000_u256;

        let btc_updated_at = 1000002;
        let eth_updated_at = 1000001;

        let btc_decimals = 8;
        let eth_decimals = 18;
        */
        
        let cycle = 10;
        let bridge_id = 1;
        mock_deposit_bribe(user_a, eth_metadata, 10_000000, cycle, bridge_id); // 1 BTC
        // Get initial weights
        let initial_weights = calculate_bribe_weights_for_cycle(cycle);
        assert!(vector::length(&initial_weights) == 1, 501);
        
        // Initial ETH price was 10 USD
        // Update ETH price to 100 USD, same as BTC
        let eth_usd_pair_id = string::utf8(b"eth/usd");
        let new_eth_price = 100_000000000000000000_u256; 
        let eth_updated_at = 1000005;
        let eth_decimals = 18;
        
        oracle::set_price(
            &eth_usd_pair_id,
            new_eth_price,
            eth_updated_at,
            eth_decimals
        );
        
        // Make a second bribe for a diff bridge with 10 BTC to see if htey are worth the same now
        let bridge_id_2 = 2;
        mock_deposit_bribe(user_a, btc_metadata, 10_000000, cycle, bridge_id_2);
        
        // Get updated weights
        let updated_weights = calculate_bribe_weights_for_cycle(cycle);
        assert!(vector::length(&updated_weights) == 2, 502);
        
        // They should have equal weight now, since price of BTC and ETH is the same
        let weight_1 = bigdecimal::zero();
        let weight_2 = bigdecimal::zero();
        
        for (i in 0..vector::length(&updated_weights)) {
            let bridge_id_here = get_bridge_reward_response_bridge_id(&updated_weights[i]);
            let weight = get_bridge_reward_response_weight(&updated_weights[i]);
            
            if (bridge_id_here == bridge_id) {
                weight_1 = weight;
            } else if (bridge_id_here == bridge_id_2) {
                weight_2 = weight;
            };
        };
        
        // Weights should be approximately equal (close to 0.5 each)
        let weight_1_decimal = bigdecimal::truncate_u64(bigdecimal::mul_by_u64(weight_1, 100));
        let weight_2_decimal = bigdecimal::truncate_u64(bigdecimal::mul_by_u64(weight_2, 100));
        
        assert!(weight_1_decimal >= 49 && weight_1_decimal <= 51, 503);
        assert!(weight_2_decimal >= 49 && weight_2_decimal <= 51, 504);
    }

    // Test depositing with an unregistered bridge ID (using real deposit_bribe)
    #[test(c=@staking_addr, user_a=@0x111111)]
    #[expected_failure(abort_code = 0x10003, location = staking_addr::bribe)] //error::invalid_argument:0x10000 EINVALID_BRIDGE: 0x1
    public fun test_deposit_unregistered_bridge_id(c: &signer, user_a: &signer) {
        init_module_for_test(c);
        test_setup(c); // Sets up VIP with bridge_id 1

        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        set_allowed_bribe_tokens(c, vector[btc_metadata]);
        assert!(is_voting_reward_token(btc_metadata), 601);

        let unregistered_bridge_id = 99; // This ID is not registered in test_setup
        let cycle = 30;

        // Attempt to deposit using the real function with an unregistered bridge ID
        deposit_bribe(user_a, btc_metadata, 1_000000, cycle, unregistered_bridge_id);
    }

    // Test depositing zero amount
    #[test(c=@staking_addr, user_a=@0x111111)]
    #[expected_failure(abort_code = 0x10002, location = staking_addr::bribe)] //error::invalid_argument: 0x10000, EINVALID_COIN_AMOUNT:0x2
    public fun test_deposit_zero_amount(c: &signer, user_a: &signer) {
        init_module_for_test(c);
        test_setup(c);

        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        set_allowed_bribe_tokens(c, vector[btc_metadata]);
        assert!(is_voting_reward_token(btc_metadata), 701);

        let cycle = 31;
        let bridge_id = 1; // Registered bridge ID

        // Attempt to deposit zero amount
        deposit_bribe(user_a, btc_metadata, 0, cycle, bridge_id);
    }

    // Test depositing with zero fee
    #[test(c=@staking_addr, user_a=@0x111111)]
    public fun test_deposit_with_zero_fee(c: &signer, user_a: &signer) {
        init_module_for_test(c);
        test_setup(c);

        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        set_allowed_bribe_tokens(c, vector[btc_metadata]);
        set_deposit_voting_reward_fee_bps(c, 0); // Set fee to 0
        assert!(deposit_voting_reward_fee_bps() == 0, 801);

        let cycle = 32;
        let bridge_id = 1;
        let amount = 5_000000;

        mock_deposit_bribe(user_a, btc_metadata, amount, cycle, bridge_id);

        // Check that the full amount was recorded (no fee deducted)
        let bribes = get_total_bribes_by_token_for_cycle(cycle);
        assert!(simple_map::contains_key(&bribes, &btc_metadata), 802);
        assert!(*simple_map::borrow(&bribes, &btc_metadata) == amount, 803);
    }

    // Test depositing with fifty percent fee
    #[test(c=@staking_addr, user_a=@0x111111)]
    public fun test_deposit_with_fifty_pct_fee(c: &signer, user_a: &signer) {
        init_module_for_test(c);
        test_setup(c);

        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        set_allowed_bribe_tokens(c, vector[btc_metadata]);
        set_deposit_voting_reward_fee_bps(c, 5_000); // 5_000 bps is 50%
        assert!(deposit_voting_reward_fee_bps() == 5_000, 801);

        let cycle = 32;
        let bridge_id = 1;
        let amount = 5_000000;

        mock_deposit_bribe(user_a, btc_metadata, amount, cycle, bridge_id);

        let bribes = get_total_bribes_by_token_for_cycle(cycle);
        assert!(simple_map::contains_key(&bribes, &btc_metadata), 802);
        assert!(*simple_map::borrow(&bribes, &btc_metadata) == amount/2, 803);
    }

    // Test depositing with max fee (100%)
    #[test(c=@staking_addr, user_a=@0x111111)]
    public fun test_deposit_with_max_fee(c: &signer, user_a: &signer) {
        init_module_for_test(c);
        test_setup(c);

        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        set_allowed_bribe_tokens(c, vector[btc_metadata]);
        set_deposit_voting_reward_fee_bps(c, 10000); // 10_000 BPS is 100%, correct? - Yes
        assert!(deposit_voting_reward_fee_bps() == 10000, 901);

        let cycle = 33;
        let bridge_id = 1;
        let amount = 5_000000;

        mock_deposit_bribe(user_a, btc_metadata, amount, cycle, bridge_id);

        let bribes = get_total_bribes_by_token_for_cycle(cycle);
        if (simple_map::contains_key(&bribes, &btc_metadata)) {
            // debug::print(&string::utf8(b"Key exists, check if this is correct"));
             assert!(*simple_map::borrow(&bribes, &btc_metadata) == 0, 902);
        } //otherwise the key does not exist, which is also fine, as the value is essentially 0

    }

    // Test accumulating bribes for the same cycle/bridge/token
    #[test(c=@staking_addr, user_a=@0x111111)]
    public fun test_accumulating_bribes(c: &signer, user_a: &signer) {
        init_module_for_test(c);
        test_setup(c);

        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        set_allowed_bribe_tokens(c, vector[btc_metadata]);
        set_deposit_voting_reward_fee_bps(c, 1000); // 10% fee
        assert!(deposit_voting_reward_fee_bps() == 1000, 1001);

        let cycle = 34;
        let bridge_id = 1;
        let amount1 = 2_000000; // Net: 1_800000
        let amount2 = 3_000000; // Net: 2_700000
        let expected_total_net = 4_500000;

        mock_deposit_bribe(user_a, btc_metadata, amount1, cycle, bridge_id);
        mock_deposit_bribe(user_a, btc_metadata, amount2, cycle, bridge_id);

        // Check that the total recorded amount is the sum of net amounts
        let bribes = get_total_bribes_by_token_for_cycle(cycle);
        assert!(simple_map::contains_key(&bribes, &btc_metadata), 1002);
        assert!(*simple_map::borrow(&bribes, &btc_metadata) == expected_total_net, 1003);
    }

    // Test depositing bribe when emergency pause is active
    #[test(c=@staking_addr, user_a=@0x111111)]
    #[expected_failure(location = staking_addr::emergency, abort_code = 0x30002)] //error::invalid_state:0x30000 emergency::EPAUSED: 0x2
    public fun test_deposit_bribe_when_paused(c: &signer, user_a: &signer) {
        init_module_for_test(c);
        test_setup(c);

        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        set_allowed_bribe_tokens(c, vector[btc_metadata]);

        // Activate emergency pause
        emergency::mock_set_pause(c, true);
        assert!(emergency::paused(), 1101);
        // Attempt to deposit bribe (should fail due to pause)
        deposit_bribe(user_a, btc_metadata, 1_000000, 35, 1);
    }

    //TODO: Do that 
    // // Test bribing restrictions for past cycles
    // #[test(c=@staking_addr, user_a=@0x111111)]
    // #[expected_failure] // should not be able to bribe for stuff in the past
    // public fun test_cannot_bribe_for_past_cycles(c: &signer, user_a: &signer) {
    //     init_module_for_test(c);
    //     test_setup(c);

    //     // Whitelist tokens
    //     let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
    //     set_allowed_bribe_tokens(c, vector[btc_metadata]);
        
    //     // Current cycle
    //     let current_cycle = 30;
    //     let past_cycle = 29;
    //     let bridge_id = 1;
        
    //     //TODO: Implement simulation for past code
        
    //     // Try to bribe for a past cycle (should fail)
    //     deposit_bribe(user_a, btc_metadata, 1_000000, past_cycle, bridge_id);
    // }
    
    // Test calculating weights for a cycle with no bribes
    #[test(c=@staking_addr)]
    public fun test_calculate_weights_no_bribes(c: &signer) {
        init_module_for_test(c);
        test_setup(c);

        let cycle_with_no_bribes = 40;
        let weights = calculate_bribe_weights_for_cycle(cycle_with_no_bribes);
        assert!(vector::is_empty(&weights), 1201);
    }

    // Test calculating weights for a cycle with a single bribe
    #[test(c=@staking_addr, user_a=@0x111111)]
    public fun test_calculate_weights_single_bribe(c: &signer, user_a: &signer) {
        init_module_for_test(c);
        test_setup(c);

        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        set_allowed_bribe_tokens(c, vector[btc_metadata]);

        let cycle = 41;
        let bridge_id = 1;
        mock_deposit_bribe(user_a, btc_metadata, 1_000000, cycle, bridge_id);

        let weights = calculate_bribe_weights_for_cycle(cycle);
        assert!(vector::length(&weights) == 1, 1301);
        let weight_response = &weights[0];
        assert!(get_bridge_reward_response_bridge_id(weight_response) == bridge_id, 1302);
        assert!(get_bridge_reward_response_weight(weight_response) == bigdecimal::one(), 1303);
        // Value = 1_000000 * (100_00000000 / 10^8) * 10^6 = 100_000000
        assert!(get_bridge_reward_response_amount(weight_response) == 100_000000, 1304);
    }

    // Test calculating weights when an oracle price is missing for a bribed token
    #[test(c=@staking_addr, user_a=@0x111111)]
    #[expected_failure] // error in the oracle 
    public fun test_calculate_weights_missing_oracle_price(c: &signer, user_a: &signer) {
        init_module_for_test(c);
        test_setup(c); // Sets up BTC and ETH prices

        // Create a new token without setting an oracle price
        let (_, _, doge_mint) = utils::initialize_coin_for_testing(&account::create_signer_for_test(@initia_std), string::utf8(b"doge"));
        let doge_metadata = coin::metadata(@initia_std, string::utf8(b"doge"));
        coin::mint_to(&doge_mint, signer::address_of(user_a), 1000_000000);

        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        set_allowed_bribe_tokens(c, vector[btc_metadata, doge_metadata]);

        let cycle = 42;
        let bridge_id_1 = 1;
        let bridge_id_2 = 2;

        // Bribe with BTC (has price)
        mock_deposit_bribe(user_a, btc_metadata, 1_000000, cycle, bridge_id_1); // 1 BTC = 100 USD value
        // Bribe with DOGE (no price set)
        mock_deposit_bribe(user_a, doge_metadata, 500_000000, cycle, bridge_id_2); // 500 DOGE

        // Calculate weights - utils::get_token_value_in_usd should break, as there is no price
        let weights = calculate_bribe_weights_for_cycle(cycle);
    }

    // Test accuracy of get_total_bribes_by_token_for_cycle view function
    #[test(c=@staking_addr, user_a=@0x111111, user_b=@0x222222)]
    public fun test_get_total_bribes_by_token(c: &signer, user_a: &signer, user_b: &signer) {
        init_module_for_test(c);
        test_setup(c);

        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let eth_metadata = coin::metadata(@initia_std, string::utf8(b"eth"));
        set_allowed_bribe_tokens(c, vector[btc_metadata, eth_metadata]);
        set_deposit_voting_reward_fee_bps(c, 1000); // 10% fee

        let cycle = 43;
        let bridge_id_1 = 1;
        let bridge_id_2 = 2;

        // Bribes:
        // User A -> Bridge 1: 2 BTC (Net 1.8 BTC)
        // User A -> Bridge 2: 5 ETH (Net 4.5 ETH)
        // User B -> Bridge 1: 3 BTC (Net 2.7 BTC)
        // User B -> Bridge 2: 10 ETH (Net 9.0 ETH)
        // Note: Using mock_deposit_bribe which applies fees internally for calculation storage
        mock_deposit_bribe(user_a, btc_metadata,  2_000000, cycle, bridge_id_1);
        mock_deposit_bribe(user_a, eth_metadata,  5_000000, cycle, bridge_id_2); // 5 ETH
        mock_deposit_bribe(user_b, btc_metadata,  3_000000, cycle, bridge_id_1);
        mock_deposit_bribe(user_b, eth_metadata, 10_000000, cycle, bridge_id_2); // 10 ETH

        let expected_total_btc_net = 1_800000 + 2_700000; // 4.5 BTC
        let expected_total_eth_net = 4_500000 + 9_000000; // 13.5 ETH

        let total_bribes = get_total_bribes_by_token_for_cycle(cycle);
        // debug::print(&total_bribes);
        // debug::print(&simple_map::length(&total_bribes));
        assert!(simple_map::length(&total_bribes) == 2, 1501);
        assert!(simple_map::contains_key(&total_bribes, &btc_metadata), 1502);
        assert!(simple_map::contains_key(&total_bribes, &eth_metadata), 1503);

        assert!(*simple_map::borrow(&total_bribes, &btc_metadata) == expected_total_btc_net, 1504);
        assert!(*simple_map::borrow(&total_bribes, &eth_metadata) == expected_total_eth_net, 1505);
    }

    // Test get_voting_reward_tokens view function
    #[test(c=@staking_addr)]
    public fun test_get_voting_reward_tokens_accuracy(c: &signer) {
        init_module_for_test(c);
        test_setup(c); // Initializes BTC and ETH

        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let eth_metadata = coin::metadata(@initia_std, string::utf8(b"eth"));

        // empty
        let initial_tokens = bribe::get_voting_reward_tokens();
        assert!(vector::is_empty(&initial_tokens), 1601);

        // Set allowed tokens
        set_allowed_bribe_tokens(c, vector[btc_metadata, eth_metadata]);

        let allowed_tokens = bribe::get_voting_reward_tokens();
        assert!(vector::length(&allowed_tokens) == 2, 1602);

        // Clear allowed tokens
        set_allowed_bribe_tokens(c, vector::empty());
        let final_tokens = bribe::get_voting_reward_tokens();
        assert!(vector::is_empty(&final_tokens), 1608);
    }


    // Test auth: Random user cannot set allowed bribe tokens
    #[test(c=@staking_addr, random_user=@0x333333)]
    #[expected_failure(location = staking_addr::bribe, abort_code = 0x40005)] //error::unauthenticated:0x40000 EMODULE_OPERATION:0x5
    public fun test_auth_random_user_cannot_set_allowed_tokens(c: &signer, random_user: &signer) {
        init_module_for_test(c);
        test_setup(c);
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        // Random user attempts to set allowed tokens
        set_allowed_bribe_tokens(random_user, vector[btc_metadata]);
    }

    // Test that the commission fee is transferred to the correct address
    #[test(c=@staking_addr, user_a=@0x111111)]
    public fun test_fee_transfer_destination(c: &signer, user_a: &signer) {
        init_module_for_test(c);
        test_setup(c);

        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        set_allowed_bribe_tokens(c, vector[btc_metadata]);
        let fee_bps = 2500; // 25% fee
        set_deposit_voting_reward_fee_bps(c, fee_bps);

        let cycle = 44;
        let bridge_id = 1;
        let bribe_amount = 10_000000; // 10 BTC
        let expected_fee = bribe_amount * fee_bps / 10000; // 2.5 BTC

        let commission_addr = package::get_commission_fee_store_address();
        let initial_commission_balance = balance(commission_addr, btc_metadata);

        // Use mock_deposit_bribe as it performs the internal transfer
        mock_deposit_bribe(user_a, btc_metadata, bribe_amount, cycle, bridge_id);

        let final_commission_balance = balance(commission_addr, btc_metadata);

        assert!(final_commission_balance == initial_commission_balance + expected_fee, 1701);
    }

    // Test calculating weights when total bribe value is 0 (e.g., oracle price is zero)
    #[test(c=@staking_addr, user_a=@0x111111)]
    #[expected_failure] // Expecting division by zero in bigdecimal
    public fun test_calculate_weights_zero_value_bribes(c: &signer, user_a: &signer) {
        init_module_for_test(c);
        test_setup(c);

        // Use ETH, but set its oracle price to 0
        let eth_metadata = coin::metadata(@initia_std, string::utf8(b"eth"));
        set_allowed_bribe_tokens(c, vector[eth_metadata]);

        let eth_usd_pair_id = string::utf8(b"eth/usd");
        oracle::set_price(
            &eth_usd_pair_id,
            0, // Set price to 0
            1000010,
            18 // Decimals
        );

        let cycle = 46;
        let bridge_id = 1;

        // Bribe with ETH (now has zero value according to oracle)
        mock_deposit_bribe(user_a, eth_metadata, 10_000000, cycle, bridge_id); // 10 ETH

        // Calculate weights. tptal value is 0
        // we have a div by 0 in the individual weights
        let _weights = calculate_bribe_weights_for_cycle(cycle);
    }

    //Test minimum possible bribe amount
    #[test(c=@staking_addr, user_a=@0x111111)]
    public fun test_minimum_bribe_amount(c: &signer, user_a: &signer) {
        init_module_for_test(c);
        test_setup(c);

        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        set_allowed_bribe_tokens(c, vector[btc_metadata]);
        
        // Set a small fee to verify rounding behavior
        set_deposit_voting_reward_fee_bps(c, 100); // 1% fee
        
        let cycle = 50;
        let bridge_id = 1;
        let min_amount = 1;
        
        // Deposit the minimum amount
        mock_deposit_bribe(user_a, btc_metadata, min_amount, cycle, bridge_id);
        
        // With 1% fee, the expected amount after fee would be 0.99 uBTC, but we are working with ints
        let bribes = get_total_bribes_by_token_for_cycle(cycle);
        assert!(simple_map::contains_key(&bribes, &btc_metadata), 1801);
        
        let recorded_amount = *simple_map::borrow(&bribes, &btc_metadata);
        // For a 1% fee on 1 unit, we'd expect 0.99 uBTC, which should get rounded up to 1
        assert!(recorded_amount == 1, 1802);
        
        // Now try with no fee
        set_deposit_voting_reward_fee_bps(c, 0);
        
        let cycle2 = 51;
        mock_deposit_bribe(user_a, btc_metadata, min_amount, cycle2, bridge_id);
        
        let bribes2 = get_total_bribes_by_token_for_cycle(cycle2);
        assert!(simple_map::contains_key(&bribes2, &btc_metadata), 1803);
        assert!(*simple_map::borrow(&bribes2, &btc_metadata) == 1, 1804);
        
        let weights = calculate_bribe_weights_for_cycle(cycle2);
        assert!(vector::length(&weights) == 1, 1805);
        
        // Value = 1 * (100_00000000 / 10^8) * 10^6 = 100
        assert!(get_bridge_reward_response_amount(&weights[0]) == 100, 1806);
        assert!(get_bridge_reward_response_weight(&weights[0]) == bigdecimal::one(), 1807);
    }

    // Test multiple small bribes from different users
    #[test(c=@staking_addr, user_a=@0x111111, user_b=@0x222222)]
    public fun test_multiple_small_bribes(c: &signer, user_a: &signer, user_b: &signer) {
        init_module_for_test(c);
        test_setup(c);
        
        
        let btc_metadata = coin::metadata(@initia_std, string::utf8(b"btc"));
        let eth_metadata = coin::metadata(@initia_std, string::utf8(b"eth"));
        set_allowed_bribe_tokens(c, vector[btc_metadata, eth_metadata]);
        
        
        // Set no fee to avoid rounding complications
        set_deposit_voting_reward_fee_bps(c, 0);
        
        let cycle = 60;
        let bridge_id_1 = 1;
        let bridge_id_2 = 2;
        let bridge_id_3 = 3;
        
        // Multiple users place small bribes for different bridges
        // User A bribes 1 unit of BTC for bridge 1
        mock_deposit_bribe(user_a, btc_metadata, 1, cycle, bridge_id_1);
        
        // User B bribes 5 units of BTC for bridge 2
        mock_deposit_bribe(user_b, btc_metadata, 5, cycle, bridge_id_2);
        
        // User A bribes 10 units of ETH for bridge 3
        mock_deposit_bribe(user_a, eth_metadata, 10, cycle, bridge_id_3);
        
        // Check that all bribes were recorded correctly
        let bribes = get_total_bribes_by_token_for_cycle(cycle);
        assert!(simple_map::contains_key(&bribes, &btc_metadata), 1901);
        assert!(simple_map::contains_key(&bribes, &eth_metadata), 1902);
        assert!(*simple_map::borrow(&bribes, &btc_metadata) == 6, 1903); // 1 + 5 = 6 uBTC total
        assert!(*simple_map::borrow(&bribes, &eth_metadata) == 10, 1904); // 10 uETH total
        
        // Check the weights calculation for tiny amounts
        let weights = calculate_bribe_weights_for_cycle(cycle);
        assert!(vector::length(&weights) == 3, 1905); // Should have weights for all three bridges
        
        // Extract weights and amounts
        let bridge_1_weight = bigdecimal::zero();
        let bridge_2_weight = bigdecimal::zero();
        let bridge_3_weight = bigdecimal::zero();
        let bridge_1_amount = 0;
        let bridge_2_amount = 0;
        let bridge_3_amount = 0;
        
        for (i in 0..vector::length(&weights)) {
            let bridge_id = get_bridge_reward_response_bridge_id(&weights[i]);
            let weight = get_bridge_reward_response_weight(&weights[i]);
            let amount = get_bridge_reward_response_amount(&weights[i]);
            
            if (bridge_id == bridge_id_1) {
                bridge_1_weight = weight;
                bridge_1_amount = amount;
            } else if (bridge_id == bridge_id_2) {
                bridge_2_weight = weight;
                bridge_2_amount = amount;
            } else if (bridge_id == bridge_id_3) {
                bridge_3_weight = weight;
                bridge_3_amount = amount;
            };
        };
        
        
        // Expected weights: Bridge 1 = 1/7, Bridge 2 = 5/7, Bridge 3 = 1/7
        let bridge_1_decimal = bigdecimal::truncate_u64(bigdecimal::mul_by_u64(bridge_1_weight, 700));
        let bridge_2_decimal = bigdecimal::truncate_u64(bigdecimal::mul_by_u64(bridge_2_weight, 700));
        let bridge_3_decimal = bigdecimal::truncate_u64(bigdecimal::mul_by_u64(bridge_3_weight, 700));
        
        // Check the computed USD values are correct
        assert!(bridge_1_amount == 100, 1906); // 1 BTC at $100 each
        assert!(bridge_2_amount == 500, 1907); // 5 BTC at $100 each
        assert!(bridge_3_amount == 100, 1908); // 10 ETH at $10 each
        
        // Bridge 1 weight should be ~100/700 = ~14.3%
        assert!(bridge_1_decimal >= 99 && bridge_1_decimal <= 101, 1909);
        // Bridge 2 weight should be ~500/700 = ~71.4%
        assert!(bridge_2_decimal >= 499 && bridge_2_decimal <= 501, 1910);
        // Bridge 3 weight should be ~100/700 = ~14.3%
        assert!(bridge_3_decimal >= 99 && bridge_3_decimal <= 101, 1911);
    }


}