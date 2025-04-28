#[test_only]
module staking_addr::deployer_auth_test {
    use std::signer;
    use std::string;
    use initia_std::account;

    use staking_addr::cabal;
    use staking_addr::package;
    use staking_addr::pool_router;
    use staking_addr::cabal_token;
    use staking_addr::emergency;


    // These error codes are a bit inconsistent but w/e lol

    // Functions that we only allow the staking_addr to do:
    // Cabal::initialize
    // package::set_commission_fee_store_addr
    // Emergency:: init, set_pause, mock_set_pause
    // pool_router:: init_module, change validator

    
    // Helper to get a random non-deployer signer
    fun make_random(): signer {
        account::create_signer_for_test(@0x1111)
    }

    // 1) Only staking addr should be able to call cabal initialize
    // EMODULE_OPERATION = 7 
    #[test(c = @staking_addr)]
    #[expected_failure(abort_code = 0x40006, location = staking_addr::cabal)]
    fun test_cabal_initialize_not_deployer(c: &signer) {
        let bad = make_random();
        // attempt to re-init as someone else
        cabal::initialize(&bad, string::utf8(b"valoper"), signer::address_of(c));
    }

    // 2) package::set_commission_fee_store_addr 
    // EMODULE_OPERATION = 3
    #[test(c = @staking_addr)]
    #[expected_failure(abort_code = 0x40003, location = staking_addr::package)]
    fun test_package_set_commission_not_deployer(c: &signer) {
        let bad = make_random();
        package::set_commission_fee_store_addr(&bad, signer::address_of(c));
    }

    // 4) cabal_token::initialize (via test helper)  only @staking_addr
    // EMODULE_OPERATION = 1
    #[test]
    #[expected_failure(abort_code = 0x40001, location = staking_addr::cabal_token)]
    fun test_cabal_token_init_not_deployer() {
        let bad = make_random();
        cabal_token::init_module_for_test(&bad);
    }

    // 5) emergency::init_module_for_test only @staking_addr
    // EMODULE_OPERATION = 1
    #[test(c = @staking_addr)]
    #[expected_failure(abort_code = 0x40001, location = staking_addr::emergency)]
    fun test_emergency_init_not_deployer(c: &signer) {
        let bad = make_random();
        emergency::init_module_for_test(&bad);
    }
}