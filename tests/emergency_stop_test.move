#[test_only]
module staking_addr::emergency_stop_test {
    use std::signer;
    use std::vector;
    use initia_std::bigdecimal::BigDecimal;
    use staking_addr::cabal;
    use staking_addr::emergency;
    use staking_addr::manager;
    use staking_addr::package;
    use staking_addr::cabal_token;
    use staking_addr::pool_router;
    use staking_addr::bribe;
    use staking_addr::voting_reward;


    // packed_code = (module_index << 16) | user_abort_code

    // Abort code for emergency stop is 2 and module index for emergency.move in tests is 3

    // (3 << 16) | 2  ==  0x30000 | 0x0002  ==  0x30002  == 196610

    // TODO: look at why theres diff module indices for diff tests

    fun setup(c: &signer) {
        emergency::init_module_for_test(c);
        manager::initialize_for_test(signer::address_of(c));
        bribe::init_module_for_test(c);
        cabal_token::init_module_for_test(c);
        pool_router::init_module_for_test(c);
        voting_reward::init_module_for_test(c);
    }

    #[test(c=@staking_addr)]
    #[expected_failure(abort_code = 0x30002, location = staking_addr::emergency)]
    fun test_deposit_init_paused(c: &signer) {
        setup(c);
        emergency::mock_set_pause(c, true);
        cabal::deposit_init_for_xinit(c, 1);
    }

    #[test(c=@staking_addr)]
    #[expected_failure(abort_code = 0x30002, location = staking_addr::emergency)]
    fun test_stake_asset_paused(c: &signer) {
        setup(c);
        emergency::mock_set_pause(c, true);
        cabal::stake_asset(c, 0, 1);
    }

    #[test(c=@staking_addr)]
    #[expected_failure(abort_code = 0x30002, location = staking_addr::emergency)]
    fun test_initiate_unstake_paused(c: &signer) {
        setup(c);
        emergency::mock_set_pause(c, true);
        cabal::initiate_unstake(c, 0, 1);
    }

    #[test(c=@staking_addr)]
    #[expected_failure(abort_code = 0x30002, location = staking_addr::emergency)]
    fun test_claim_unbonded_assets_paused(c: &signer) {
        setup(c);
        emergency::mock_set_pause(c, true);
        cabal::claim_unbonded_assets(c, vector::empty<u64>());
    }

    #[test(c=@staking_addr)]
    #[expected_failure(abort_code = 0x30002, location = staking_addr::emergency)]
    fun test_vote_paused(c: &signer) {
        setup(c);
        emergency::mock_set_pause(c, true);
        cabal::vote(c, 0, vector::empty<u64>(), vector::empty<BigDecimal>());
    }

    #[test(c=@staking_addr)]
    #[expected_failure(abort_code = 0x30002, location = staking_addr::emergency)]
    fun test_vote_using_bribe_weights_paused(c: &signer) {
        setup(c);
        emergency::mock_set_pause(c, true);
        cabal::vote_using_bribe_weights(c, 0);
    }
}
