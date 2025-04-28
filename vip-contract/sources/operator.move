module vip::operator {
    use std::error;
    use std::event;
    use std::signer;
    use std::vector;

    use initia_std::bigdecimal::{Self, BigDecimal};
    use initia_std::table::{Self, Table};
    use initia_std::table_key;

    use vip::utils;
    friend vip::vip;
    //
    // Errors
    //

    const EOPERATOR_STORE_ALREADY_EXISTS: u64 = 1;
    const EOPERATOR_STORE_NOT_FOUND: u64 = 2;
    const EINVALID_COMMISSION_CHANGE_RATE: u64 = 3;
    const EOVER_MAX_COMMISSION_RATE: u64 = 4;
    const EINVALID_STAGE: u64 = 5;
    const EINVALID_COMMISSION_RATE: u64 = 6;
    const EUNAUTHORIZED: u64 = 7;

    //
    // Resources
    //
    struct ModuleStore has key {
        operator_infos: Table<vector<u8> /*bridge id + version*/, OperatorInfo>
    }

    struct OperatorInfo has store {
        operator_addr: address,
        last_changed_stage: u64,
        commission_max_rate: BigDecimal,
        commission_max_change_rate: BigDecimal,
        commission_rate: BigDecimal
    }

    //
    // Events
    //
    #[event]
    struct UpdateCommissionEvent has drop, store {
        operator: address,
        bridge_id: u64,
        version: u64,
        stage: u64,
        commission_rate: BigDecimal
    }

    fun init_module(vip: &signer) {
        move_to(
            vip,
            ModuleStore {
                operator_infos: table::new<vector<u8>, OperatorInfo>()
            }
        );
    }

    //
    // Helper Functions
    //

    fun check_valid_rate(rate: &BigDecimal) {
        assert!(
            bigdecimal::le(*rate, bigdecimal::one()),
            error::invalid_argument(EINVALID_COMMISSION_RATE)
        );
    }

    fun check_valid_commission_rates(
        commission_max_rate: &BigDecimal,
        commission_max_change_rate: &BigDecimal,
        commission_rate: &BigDecimal
    ) {
        check_valid_rate(commission_max_rate);
        check_valid_rate(commission_max_change_rate);
        check_valid_rate(commission_rate);
        assert!(
            bigdecimal::le(*commission_rate, *commission_max_rate),
            error::invalid_argument(EOVER_MAX_COMMISSION_RATE)
        );
    }

    fun generate_key(bridge_id: u64, version: u64): vector<u8> {
        let key = table_key::encode_u64(bridge_id);
        vector::append(&mut key, table_key::encode_u64(version));
        key
    }

    //
    // Friend Functions
    //

    public(friend) fun register_operator_store(
        chain: &signer,
        operator_addr: address,
        bridge_id: u64,
        version: u64,
        stage: u64,
        commission_max_rate: BigDecimal,
        commission_max_change_rate: BigDecimal,
        commission_rate: BigDecimal
    ) acquires ModuleStore {
        utils::check_chain_permission(chain);
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        let key = generate_key(bridge_id, version);
        assert!(
            !table::contains(&module_store.operator_infos, key),
            error::already_exists(EOPERATOR_STORE_ALREADY_EXISTS)
        );

        check_valid_commission_rates(
            &commission_max_rate,
            &commission_max_change_rate,
            &commission_rate
        );

        table::add<vector<u8>, OperatorInfo>(
            &mut module_store.operator_infos,
            key,
            OperatorInfo {
                operator_addr,
                last_changed_stage: stage,
                commission_max_rate,
                commission_max_change_rate,
                commission_rate
            }
        );
    }

    public(friend) fun update_operator_commission(
        operator: &signer,
        bridge_id: u64,
        version: u64,
        stage: u64,
        commission_rate: BigDecimal
    ) acquires ModuleStore {
        let operator_addr = signer::address_of(operator);
        let key = generate_key(bridge_id, version);
        let module_store = borrow_global_mut<ModuleStore>(@vip);

        let operator_info = table::borrow_mut(&mut module_store.operator_infos, key);
        assert!(
            operator_addr == operator_info.operator_addr,
            error::permission_denied(EUNAUTHORIZED)
        );
        // commission can be updated once per a stage.
        assert!(
            stage > operator_info.last_changed_stage,
            error::invalid_argument(EINVALID_STAGE)
        );

        assert!(
            bigdecimal::le(commission_rate, operator_info.commission_max_rate),
            error::invalid_argument(EOVER_MAX_COMMISSION_RATE)
        );

        // operator max change rate limits
        let change =
            if (bigdecimal::gt(operator_info.commission_rate, commission_rate)) {
                bigdecimal::sub(operator_info.commission_rate, commission_rate)
            } else {
                bigdecimal::sub(commission_rate, operator_info.commission_rate)
            };

        assert!(
            bigdecimal::le(change, operator_info.commission_max_change_rate),
            error::invalid_argument(EINVALID_COMMISSION_CHANGE_RATE)
        );

        operator_info.commission_rate = commission_rate;
        operator_info.last_changed_stage = stage;

        event::emit(
            UpdateCommissionEvent {
                operator: operator_addr,
                bridge_id,
                version,
                stage: operator_info.last_changed_stage,
                commission_rate
            }
        );
    }

    public(friend) fun update_operator_addr(
        old_operator: &signer,
        bridge_id: u64,
        version: u64,
        new_operator_addr: address
    ) acquires ModuleStore {
        let key = generate_key(bridge_id, version);
        let module_store = borrow_global_mut<ModuleStore>(@vip);
        let operator_info = table::borrow_mut(&mut module_store.operator_infos, key);
        assert!(
            operator_info.operator_addr == signer::address_of(old_operator),
            error::permission_denied(EUNAUTHORIZED)
        );

        operator_info.operator_addr = new_operator_addr;
    }

    public fun check_operator_permission(
        operator: &signer, bridge_id: u64, version: u64
    ) acquires ModuleStore {
        let key = generate_key(bridge_id, version);
        let module_store = borrow_global<ModuleStore>(@vip);
        let operator_info = table::borrow(&module_store.operator_infos, key);

        assert!(
            operator_info.operator_addr == signer::address_of(operator),
            error::permission_denied(EUNAUTHORIZED)
        );
    }

    public fun get_operator_commission(bridge_id: u64, version: u64): BigDecimal acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        assert!(
            table::contains(
                &module_store.operator_infos,
                generate_key(bridge_id, version)
            ),
            error::not_found(EOPERATOR_STORE_NOT_FOUND)
        );
        let operator_info =
            table::borrow(
                &module_store.operator_infos,
                generate_key(bridge_id, version)
            );
        operator_info.commission_rate
    }

    public fun is_bridge_registered(bridge_id: u64, version: u64): bool acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        table::contains(
            &module_store.operator_infos,
            generate_key(bridge_id, version)
        )
    }

    //
    // Tests
    //
    #[test_only]
    struct OperatorInfoResponse has drop {
        operator_addr: address,
        last_changed_stage: u64,
        commission_max_rate: BigDecimal,
        commission_max_change_rate: BigDecimal,
        commission_rate: BigDecimal
    }

    #[test_only]
    public fun init_module_for_test(chain: &signer) {
        init_module(chain);
    }

    #[test_only]
    public fun get_operator_info(
        bridge_id: u64, version: u64
    ): OperatorInfoResponse acquires ModuleStore {
        let module_store = borrow_global<ModuleStore>(@vip);
        assert!(
            table::contains(
                &module_store.operator_infos,
                generate_key(bridge_id, version)
            ),
            error::not_found(EOPERATOR_STORE_NOT_FOUND)
        );
        let operator_info =
            table::borrow(
                &module_store.operator_infos,
                generate_key(bridge_id, version)
            );

        OperatorInfoResponse {
            operator_addr: operator_info.operator_addr,
            last_changed_stage: operator_info.last_changed_stage,
            commission_max_rate: operator_info.commission_max_rate,
            commission_max_change_rate: operator_info.commission_max_change_rate,
            commission_rate: operator_info.commission_rate
        }
    }

    #[test(vip = @vip, operator = @0x999)]
    fun test_update_operator_commission(vip: &signer, operator: &signer) acquires ModuleStore {
        init_module_for_test(vip);
        let bridge_id = 1;
        let operator_addr = signer::address_of(operator);

        register_operator_store(
            vip,
            operator_addr,
            bridge_id,
            1,
            10,
            bigdecimal::from_ratio_u64(2, 10),
            bigdecimal::from_ratio_u64(2, 10),
            bigdecimal::zero()
        );

        assert!(
            get_operator_info(bridge_id, 1)
                == OperatorInfoResponse {
                    operator_addr: operator_addr,
                    last_changed_stage: 10,
                    commission_max_rate: bigdecimal::from_ratio_u64(2, 10),
                    commission_max_change_rate: bigdecimal::from_ratio_u64(2, 10),
                    commission_rate: bigdecimal::zero()
                },
            1
        );

        update_operator_commission(
            operator,
            bridge_id,
            1,
            11,
            bigdecimal::from_ratio_u64(2, 10)
        );

        assert!(
            get_operator_info(bridge_id, 1)
                == OperatorInfoResponse {
                    operator_addr: operator_addr,
                    last_changed_stage: 11,
                    commission_max_rate: bigdecimal::from_ratio_u64(2, 10),
                    commission_max_change_rate: bigdecimal::from_ratio_u64(2, 10),
                    commission_rate: bigdecimal::from_ratio_u64(2, 10)
                },
            2
        );

        update_operator_commission(
            operator,
            bridge_id,
            1,
            12,
            bigdecimal::from_ratio_u64(1, 10)
        );

        assert!(
            get_operator_info(bridge_id, 1)
                == OperatorInfoResponse {
                    operator_addr: operator_addr,
                    last_changed_stage: 12,
                    commission_max_rate: bigdecimal::from_ratio_u64(2, 10),
                    commission_max_change_rate: bigdecimal::from_ratio_u64(2, 10),
                    commission_rate: bigdecimal::from_ratio_u64(1, 10)
                },
            3
        );
    }

    #[test(vip = @vip, operator = @0x999)]
    #[expected_failure(abort_code = 0x10003, location = Self)]
    fun failed_invalid_change_rate(vip: &signer, operator: &signer) acquires ModuleStore {
        init_module_for_test(vip);
        let bridge_id = 1;
        let operator_addr = signer::address_of(operator);

        register_operator_store(
            vip,
            operator_addr,
            bridge_id,
            1,
            10,
            bigdecimal::from_ratio_u64(2, 10),
            bigdecimal::from_ratio_u64(1, 10),
            bigdecimal::zero()
        );

        update_operator_commission(
            operator,
            bridge_id,
            1,
            11,
            bigdecimal::from_ratio_u64(2, 10)
        );
    }

    #[test(vip = @vip, operator = @0x999)]
    #[expected_failure(abort_code = 0x10004, location = Self)]
    fun failed_over_max_rate(vip: &signer, operator: &signer) acquires ModuleStore {
        init_module_for_test(vip);
        let bridge_id = 1;
        let operator_addr = signer::address_of(operator);

        register_operator_store(
            vip,
            operator_addr,
            bridge_id,
            1,
            10,
            bigdecimal::from_ratio_u64(2, 10),
            bigdecimal::from_ratio_u64(2, 10),
            bigdecimal::zero()
        );

        update_operator_commission(
            operator,
            bridge_id,
            1,
            11,
            bigdecimal::from_ratio_u64(3, 10)
        );
    }

    #[test(vip = @vip, operator = @0x999)]
    #[expected_failure(abort_code = 0x10005, location = Self)]
    fun failed_not_valid_stage(vip: &signer, operator: &signer) acquires ModuleStore {
        init_module_for_test(vip);
        let bridge_id = 1;
        let operator_addr = signer::address_of(operator);

        register_operator_store(
            vip,
            operator_addr,
            bridge_id,
            1,
            10,
            bigdecimal::from_ratio_u64(2, 10),
            bigdecimal::from_ratio_u64(2, 10),
            bigdecimal::zero()
        );

        update_operator_commission(operator, bridge_id, 1, 10, bigdecimal::zero());
    }

    #[test(vip = @vip, operator = @0x999)]
    #[expected_failure(abort_code = 0x10006, location = Self)]
    fun failed_invalid_commission_rate(vip: &signer, operator: &signer) acquires ModuleStore {
        init_module_for_test(vip);
        let bridge_id = 1;
        let operator_addr = signer::address_of(operator);

        register_operator_store(
            vip,
            operator_addr,
            bridge_id,
            1,
            10,
            bigdecimal::from_ratio_u64(2, 10),
            bigdecimal::from_ratio_u64(2, 10),
            bigdecimal::from_ratio_u64(15, 10)
        );
    }
}
