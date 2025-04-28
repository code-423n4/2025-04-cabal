module staking_addr::manager {
    use std::option::{Self, Option};
    use std::signer;
    use std::vector;
    use initia_std::account;
    use initia_std::event;
    use initia_std::object;

    use staking_addr::package;

    // Authorization
    const ERR_UNAUTHORIZED: u64 = 0;

    // Initialization
    const ERR_MANAGER_UNINITIALIZED: u64 = 1;
    const ERR_MANAGER_INITIALIZED: u64 = 2;

    // Business logic
    const ERR_MANAGER_INVALID_MANAGER_ADDRESS: u64 = 3;
    const ERR_MANAGER_NO_MANAGER_CHANGE_PROPOSAL: u64 = 4;
    const ERR_MANAGER_ROLE_EXISTS: u64 = 5;
    const ERR_MANAGER_ROLE_NOT_EXISTS: u64 = 6;
    const ERR_MANAGER_ROLE_ADMIN_NOT_EXISTS: u64 = 7;

    struct Manager has key {
        manager_address: address,
    }

    struct Role has key {
        admin: Option<address>,
        members: vector<address>
    }

    struct ManagerChangeProposal has key, drop {
        new_manager_address: address
    }

    #[event]
    struct ManagerChangeProposalCreated has store, drop {
        current_manager: address,
        new_manager: address
    }

    #[event]
    struct ManagerChangeProposalDropped has store, drop {
        current_manager: address,
        dropped_manager: address
    }

    #[event]
    struct ManagerChangeProposalAccepted has store, drop {
        new_manager: address
    }

    ///
    /// Initialization
    ///

    /// Initialize the Cabal Manager. We do not utilize an `init` module given the simplicity of this
    /// package. **MUST** be called from the original deployer account of this package.
    ///
    /// All manager operations of Cabal products are gated by `manager::is_authorized(&signer)`.
    /// The authorized signer is the one controlling the supplied `manager_address`.
    ///
    /// This model allows for the deployment of
    ///   (a) A centralized manager via an externally owned `manager_address`
    ///   (b) Governance controlled manager. In which `manager_address` is not externally owned.
    public entry fun initialize(deployer: &signer, manager_address: address) {
        assert!(!initialized(), ERR_MANAGER_INITIALIZED);
        assert!(signer::address_of(deployer) == @staking_addr, ERR_UNAUTHORIZED);
        assert!(account::exists_at(manager_address), ERR_MANAGER_INVALID_MANAGER_ADDRESS);

        // Dependencies
        assert!(package::initialized(), ERR_MANAGER_UNINITIALIZED);

        let resource_account_signer = package::resource_account_signer();
        move_to(&resource_account_signer, Manager {
            manager_address,
        });
    }

    ///
    /// Config & Param Management
    ///

    /// Change the manager address of the manager
    public entry fun change_manager_address(account: &signer, new_manager_address: address) acquires Manager, ManagerChangeProposal {
        assert!(is_authorized(account), ERR_UNAUTHORIZED);

        let resource_account_address = package::resource_account_address();
        let manager = borrow_global_mut<Manager>(resource_account_address);
        let manager_addr = manager.manager_address;
        assert!(new_manager_address != manager_addr && account::exists_at(new_manager_address), ERR_MANAGER_INVALID_MANAGER_ADDRESS);

        // drop any existing proposals
        if (exists<ManagerChangeProposal>(resource_account_address)) {
            let old_proposal = move_from<ManagerChangeProposal>(resource_account_address);
            event::emit(ManagerChangeProposalDropped {
                current_manager: manager_addr,
                dropped_manager: old_proposal.new_manager_address
            });

            // old_proposal is dropped from here on out
        };

        // store this latest proposal
        event::emit(ManagerChangeProposalCreated {
            current_manager: manager_addr,
            new_manager: new_manager_address
        });

        move_to(&package::resource_account_signer(), ManagerChangeProposal { new_manager_address });
    }

    /// Accept the manager change, officially making the switch
    public entry fun accept_manager_proposal(account: &signer) acquires Manager, ManagerChangeProposal {
        let account_addr = signer::address_of(account);

        let resource_account_address = package::resource_account_address();
        let manager = borrow_global_mut<Manager>(resource_account_address);
        assert!(exists<ManagerChangeProposal>(resource_account_address), ERR_MANAGER_NO_MANAGER_CHANGE_PROPOSAL);

        let change_proposal = borrow_global<ManagerChangeProposal>(resource_account_address);
        assert!(account_addr == change_proposal.new_manager_address, ERR_UNAUTHORIZED);

        // Drop the proposal from storage & update the manager address
        let _ = move_from<ManagerChangeProposal>(resource_account_address);
        manager.manager_address = account_addr;

        event::emit(ManagerChangeProposalAccepted {
            new_manager: account_addr
        });
    }

    ///
    /// Role Management
    ///

    /// Protocol manager can create a new role
    public entry fun create_role(manager: &signer, role_name: vector<u8>, admin: Option<address>) acquires Manager {
        assert!(is_authorized(manager), ERR_UNAUTHORIZED);
        assert!(!exists<Role>(role_object_address(role_name)), ERR_MANAGER_ROLE_EXISTS);
        let resource_account_signer = package::resource_account_signer();
        let constructor_ref = object::create_named_object(&resource_account_signer, role_name);
        let role_signer = object::generate_signer(&constructor_ref);
        move_to(&role_signer, Role {
            admin,
            members: vector::empty<address>()
        });
    }

    /// Protocol manager can set role admin address or remove admin by setting an empty Option
    public entry fun set_role_admin(manager: &signer, role_name: vector<u8>, admin: Option<address>) acquires Manager, Role {
        assert!(is_authorized(manager), ERR_UNAUTHORIZED);
        let role_object_address = role_object_address(role_name);
        assert!(exists<Role>(role_object_address), ERR_MANAGER_ROLE_NOT_EXISTS);
        let role = borrow_global_mut<Role>(role_object_address);
        role.admin = admin;
    }

    /// Role admin can renounce its admin role. This function provides a mechanism for accounts to lose their privileges
    /// if they are compromised (such as when a trusted device is misplaced)
    public entry fun renounce_role_admin(admin: &signer, role_name: vector<u8>) acquires Role {
        let role_object_address = role_object_address(role_name);
        assert!(exists<Role>(role_object_address), ERR_MANAGER_ROLE_NOT_EXISTS);
        let role = borrow_global_mut<Role>(role_object_address);
        assert!(option::is_some(&role.admin), ERR_MANAGER_ROLE_ADMIN_NOT_EXISTS);
        assert!(*option::borrow(&role.admin) == signer::address_of(admin), ERR_UNAUTHORIZED);
        role.admin = option::none<address>();
    }

    /// Role admin and protocol manager can add a member to the role
    public entry fun add_role_member(admin: &signer, role_name: vector<u8>, member: address) acquires Manager, Role {
        assert!(is_role_admin(signer::address_of(admin), role_name), ERR_UNAUTHORIZED);
        assert!(exists<Role>(role_object_address(role_name)), ERR_MANAGER_ROLE_NOT_EXISTS);
        if (!is_role_member(member, role_name)) {
            let role = borrow_global_mut<Role>(role_object_address(role_name));
            vector::push_back(&mut role.members, member);
        }
    }

    /// Role admin and protocol manager can remove a member from the role
    public entry fun remove_role_member(admin: &signer, role_name: vector<u8>, member: address) acquires Manager, Role {
        assert!(is_role_admin(signer::address_of(admin), role_name), ERR_UNAUTHORIZED);
        assert!(exists<Role>(role_object_address(role_name)), ERR_MANAGER_ROLE_NOT_EXISTS);
        let role = borrow_global_mut<Role>(role_object_address(role_name));
        let members = &mut role.members;
        let (found, index) = vector::index_of(members, &member);
        if (found) {
            vector::swap_remove(members, index);
        }
    }

    ///
    /// Functions
    ///

    /// Check if an account is the current manager.
    public fun is_authorized(account: &signer): bool acquires Manager {
        is_authorized_address(signer::address_of(account))
    }

    /// Query if an address it associated with the current manager
    public fun is_authorized_address(account_addr: address): bool acquires Manager {
        assert!(initialized(), ERR_MANAGER_UNINITIALIZED);

        let manager = borrow_global<Manager>(package::resource_account_address());
        account_addr  == manager.manager_address
    }

    // Public Getters

    public fun initialized(): bool {
        exists<Manager>(package::resource_account_address())
    }

    #[view]
    public fun manager_address(): address acquires Manager {
        borrow_global<Manager>(package::resource_account_address()).manager_address
    }

    #[view]
    /// Check if an account can manage membership of a role
    /// Cabal protocol manager can always manage membership of any role
    public fun is_role_admin(account: address, role_name: vector<u8>): bool acquires Manager, Role {
        if (is_authorized_address(account)) {
            return true
        };
        let role_object_address = role_object_address(role_name);
        if (!exists<Role>(role_object_address)) {
            return false
        };
        let role = borrow_global<Role>(role_object_address);
        option::is_some(&role.admin) && *option::borrow(&role.admin) == account
    }

    #[view]
    public fun is_role_member(account: address, role_name: vector<u8>): bool acquires Role {
        let role_object_address = role_object_address(role_name);
        if (exists<Role>(role_object_address)) {
            let role = borrow_global<Role>(role_object_address);
            vector::contains(&role.members, &account)
        }
        else {
            false
        }
    }

    #[view]
    /// Get all role members
    /// Disclaimer: This function may be costly. Use it at your own discretion.
    public fun role_members(role_name: vector<u8>): vector<address> acquires Role {
        let role_object_address = role_object_address(role_name);
        if (!exists<Role>(role_object_address)) {
            return vector::empty()
        };
        let role = borrow_global<Role>(role_object_address);
        let result = vector::empty<address>();
        let i = 0;
        let n = vector::length(&role.members);
        while (i < n) {
            vector::push_back(&mut result, *vector::borrow(&role.members, i));
            i = i + 1;
        };
        result
    }

    #[view]
    public fun role_admin(role_name: vector<u8>): Option<address> acquires Role {
        let role_object_address = role_object_address(role_name);
        if (!exists<Role>(role_object_address)) {
            return option::none<address>()
        };
        let role = borrow_global<Role>(role_object_address);
        role.admin
    }

    #[view]
    /// Deterministically generate the address of a role object given the role name
    /// "V2" is appended to the role name internally to differentiate from the previous version
    public fun role_object_address(role_name: vector<u8>): address {
        object::create_object_address(&package::resource_account_address(), role_name)
    }

    //
    // Tests
    //

    #[test_only]
    public fun initialize_for_test(manager_address: address) {
        // In order for other modules to depend on CabalManager and mock the manager in tests, we internally
        // create this module's deployer account to initialize from. This is important as various modules
        // may differ in the deployer address used. We do not call `create_account_for_test` as modules may
        // also share the deployer
        let deployer = account::create_signer_for_test(@staking_addr);
        if (!account::exists_at(manager_address)) _ = account::create_account_for_test(manager_address);

        package::init_module_for_test(&deployer);
        initialize(&deployer, manager_address);
    }

    #[test]
    #[expected_failure(abort_code = ERR_UNAUTHORIZED)]
    public fun initialize_unauthorized_err() {
        let deployer = account::create_signer_for_test(@staking_addr);
        package::init_module_for_test(&deployer);
        let incorrect_deployer = account::create_account_for_test(@0xA);
        initialize(&incorrect_deployer, @0xA);
    }

    #[test]
    #[expected_failure(abort_code = ERR_MANAGER_INITIALIZED)]
    fun initialize_twice_err() {
        // prepare
        let deployer = account::create_account_for_test(@staking_addr);
        initialize_for_test(@0xA);

        // test
        initialize(&deployer, @0xA)
    }

    #[test]
    fun change_manager_address_ok() acquires Manager, ManagerChangeProposal {
        // prepare
        let accountA = account::create_account_for_test(@0xA);
        let accountB = account::create_account_for_test(@0xB);
        initialize_for_test(@0xA);

        // test
        assert!(is_authorized(&accountA), 0);
        assert!(!is_authorized(&accountB), 0);

        change_manager_address(&accountA, @0xB);
        accept_manager_proposal(&accountB);
        assert!(!is_authorized(&accountA), 0);
        assert!(is_authorized(&accountB), 0);

        change_manager_address(&accountB, @0xA);
        accept_manager_proposal(&accountA);
        assert!(is_authorized(&accountA), 0);
        assert!(!is_authorized(&accountB), 0);
    }

    #[test]
    fun change_manager_2phase_ok() acquires Manager, ManagerChangeProposal {
        // prepare
        let accountA = account::create_account_for_test(@0xA);
        let accountB = account::create_account_for_test(@0xB);
        initialize_for_test(@0xA);

        // test
        assert!(is_authorized(&accountA), 0);
        assert!(!is_authorized(&accountB), 0);

        change_manager_address(&accountA, @0xB);

        // accountA is stil the manager
        assert!(is_authorized(&accountA), 0);
        assert!(!is_authorized(&accountB), 0);

        // manager change only on accept
        accept_manager_proposal(&accountB);
        assert!(!is_authorized(&accountA), 0);
        assert!(is_authorized(&accountB), 0);
    }

    #[test]
    #[expected_failure(abort_code = ERR_UNAUTHORIZED)]
    fun change_manager_overwriten_proposal_unauthorize_err() acquires Manager, ManagerChangeProposal {
        // prepare
        let accountA = account::create_account_for_test(@0xA);
        let accountB = account::create_account_for_test(@0xB);
        initialize_for_test(@0xA);

        // test
        assert!(is_authorized(&accountA), 0);
        assert!(!is_authorized(&accountB), 0);

        change_manager_address(&accountA, @0xB);

        account::create_account_for_test(@0xC);
        change_manager_address(&accountA, @0xC); // overwrite to a different manager

        accept_manager_proposal(&accountB);
    }

    #[test]
    fun change_manager_accept_overwriten_proposal_ok() acquires Manager, ManagerChangeProposal {
        // prepare
        let accountA = account::create_account_for_test(@0xA);
        let accountB = account::create_account_for_test(@0xB);
        initialize_for_test(@0xA);

        // test
        assert!(is_authorized(&accountA), 0);
        assert!(!is_authorized(&accountB), 0);

        account::create_account_for_test(@0xC);
        change_manager_address(&accountA, @0xC);
        change_manager_address(&accountA, @0xB); // overwrite to a different manager

        accept_manager_proposal(&accountB);
        assert!(!is_authorized(&accountA), 0);
        assert!(is_authorized(&accountB), 0);
    }

    #[test]
    #[expected_failure(abort_code = ERR_UNAUTHORIZED)]
    fun change_manager_address_unauthorized_err() acquires Manager, ManagerChangeProposal {
        // prepare
        let accountA = account::create_account_for_test(@0xA);
        let accountB = account::create_account_for_test(@0xB);
        initialize_for_test(@0xA);

        // test
        change_manager_address(&accountA, @0xB);
        accept_manager_proposal(&accountB);

        change_manager_address(&accountA, @0xB);
    }

    #[test]
    fun manager_set_members_ok() acquires Manager, Role {
        // prepare
        let manager = account::create_account_for_test(@0xA);
        initialize_for_test(@0xA);
        let role_name = b"test_role";
        let incorrect_name = b"incorrect_name";

        // test
        assert!(!is_role_member(@0xB, role_name), 0);
        assert!(!is_role_member(@0xB, incorrect_name), 0);

        let members = role_members(role_name);
        assert!(vector::length(&members) == 0, 0);

        create_role(&manager, role_name, option::none<address>());
        add_role_member(&manager, role_name, @0xB);
        assert!(is_role_member(@0xB, role_name), 0);

        let members = role_members(role_name);
        assert!(vector::length(&members) == 1, 0);
        assert!(*vector::borrow(&members, 0) == @0xB, 0);

        remove_role_member(&manager, role_name, @0xB);
        assert!(!is_role_member(@0xB, role_name), 0);

        let members = role_members(role_name);
        assert!(vector::length(&members) == 0, 0);
    }

    #[test]
    #[expected_failure(abort_code = ERR_MANAGER_ROLE_EXISTS)]
    fun create_role_twice_err() acquires Manager {
        // prepare
        let manager = account::create_account_for_test(@0xA);
        initialize_for_test(@0xA);
        let role_name = b"test_role";

        create_role(&manager, role_name, option::none<address>());
        create_role(&manager, role_name, option::none<address>());
    }

    #[test]
    fun role_admin_managerment_ok() acquires Manager, Role {
        // prepare
        let manager = account::create_account_for_test(@0xA);
        let admin = account::create_account_for_test(@0xB);
        initialize_for_test(@0xA);

        let role_name = b"test_role";
        create_role(&manager, role_name, option::some<address>(@0xB));

        // test: role admin is set correctly
        assert!(is_role_admin(@0xB, role_name), 0);
        assert!(role_admin(role_name) == option::some<address>(@0xB), 0);

        // test: admin can add and remove members
        add_role_member(&admin, role_name, @0xC);
        assert!(is_role_member(@0xC, role_name), 0);

        remove_role_member(&admin, role_name, @0xC);
        assert!(!is_role_member(@0xC, role_name), 0);

        // test: manager can remove admin
        set_role_admin(&manager, role_name, option::none<address>());
        assert!(!is_role_admin(@0xB, role_name), 0);
        assert!(role_admin(role_name) == option::none<address>(), 0);
    }

    #[test]
    fun renounce_role_admin_ok() acquires Manager, Role {
        // prepare
        let manager = account::create_account_for_test(@0xA);
        let admin = account::create_account_for_test(@0xB);
        initialize_for_test(@0xA);

        let role_name = b"test_role";
        create_role(&manager, role_name, option::some<address>(@0xB));

        // test: admin can renounce
        renounce_role_admin(&admin, role_name);
        assert!(!is_role_admin(@0xB, role_name), 0);
        assert!(role_admin(role_name) == option::none<address>(), 0);
    }
}
