module staking_addr::emergency {
    use std::error;
    use std::signer;

    use initia_std::event;
    use staking_addr::manager;

    const EMODULE_OPERATION: u64 = 1;
    const EPAUSED: u64 = 2;
    const EUNAUTHORIZED: u64 = 3;

    struct PauseFlag has key {
        paused: bool,
    }

    #[event]
    struct PauseEvent has drop, store {
        paused: bool,
    }

    fun init_module(admin: &signer) {
        assert!(signer::address_of(admin) == @staking_addr, error::unauthenticated(EMODULE_OPERATION));

        // Start it with pause to give admins time to set up pools, stake tokens, etc.
        // once the protocol is first initialized
        move_to(admin, PauseFlag {
            paused: true
        });
    }

    public fun assert_no_paused() acquires PauseFlag {
        assert!(!paused(), error::invalid_state(EPAUSED));
    }

    #[view]
    public fun paused(): bool acquires PauseFlag {
        let flag = borrow_global<PauseFlag>(@staking_addr);
        flag.paused
    }

    public entry fun set_pause(account: &signer, paused: bool) acquires PauseFlag {
        assert!(manager::is_authorized(account), error::permission_denied(EUNAUTHORIZED));

        let flag = borrow_global_mut<PauseFlag>(@staking_addr);
        flag.paused = paused;
        event::emit(PauseEvent {
            paused,
        });
    }

    #[test_only]
    public fun init_module_for_test(staking_addr: &signer) {
        assert!(signer::address_of(staking_addr) == @staking_addr, error::unauthenticated(EMODULE_OPERATION));

        move_to(staking_addr, PauseFlag {
            paused: false
        });
    }

    #[test_only]
    public entry fun mock_set_pause(account: &signer, paused: bool) acquires PauseFlag {
        assert!(signer::address_of(account) == @staking_addr);

        let flag = borrow_global_mut<PauseFlag>(@staking_addr);
        flag.paused = paused;
        event::emit(PauseEvent {
            paused,
        });
    }

}