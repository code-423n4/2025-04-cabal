module staking_addr::cabal {
    use std::bcs;
    use std::error;
    use std::option::Self;
    use std::signer;
    use std::string::{Self, String};
    use std::vector;

    use initia_std::bigdecimal::{Self, BigDecimal};
    use initia_std::block;
    use initia_std::coin;
    use initia_std::cosmos;
    use initia_std::debug;
    use initia_std::dex;
    use initia_std::dex::Config;
    use initia_std::fungible_asset::{Self, Metadata};
    use initia_std::object::{Self, Object};
    use initia_std::primary_fungible_store;
    use initia_std::simple_map::{Self, SimpleMap};
    use staking_addr::utils;
    use vip::weight_vote;

    use staking_addr::bribe;
    use staking_addr::cabal_token;
    use staking_addr::emergency;
    use staking_addr::manager;
    use staking_addr::package;
    use staking_addr::pool_router;
    #[test_only]
    use initia_std::account;

    #[test_only]
    use initia_std::fungible_asset::FungibleAsset;

    friend staking_addr::voting_reward;

    //
    // Errors
    //

    const EINVALID_COIN_AMOUNT: u64 = 1;
    const EINVALID_BPS: u64 = 2;
    const EINVALID_REMAIN_AMOUNT: u64 = 3;
    const ECABAL_STORE_NOT_FOUND: u64 = 4;
    const ECABAL_STORE_ALREADY_EXISTS: u64 = 5;
    const EMODULE_OPERATION: u64 = 6;
    const EUNAUTHORIZED: u64 = 7;
    const EINVALID_INDEX: u64 = 8;
    const ENOT_RELEASED: u64 = 9;
    const EINVALID_BRIDGE: u64 = 10;
    const EINVALID_TOKEN: u64 = 11;
    const EINVALID_BRIBE: u64 = 12;
    const EINVALID_STAKE_AMOUNT: u64 = 13;
    const ENOT_TIME_YET: u64 = 14;
    const EUNSUPPORT_TOKEN: u64 = 15;

    //
    //  Constants
    //

    const BPS_BASE: u64 = 10000;
    const MINIMUM_LIQUIDITY: u64 = 100_000_000; // 10.1 INIT TODO: Change for prod
    const XINIT_UNBOND_PERIOD: u64 = 604800; // 60 * 60 * 24 * 7 (7 days); // TODO: Change for prod
    const UNDELEGATE_LP_INTERVAL: u64 = 259200; // 60 * 60 * 24 * 3 (3 days); 

    struct ModuleStore has key {

        stake_xinit_fee_bps: u64,
        xinit_stake_reward_fee_bps: u64,

        // module info
        x_init_metadata: Object<Metadata>,
        x_init_caps: CoinCapabilities,

        // pool info
        unbond_period: vector<u64>, // Unboding period in seconds for each pool
        stake_token_metadata: vector<Object<Metadata>>, 
        cabal_stake_token_metadata: vector<Object<Metadata>>, // Metadata of the Cabal LP token minted for each pool
        cabal_stake_token_caps: vector<Capabilities>, 
        staked_amounts: vector<u64>, // Total amount of underlying stake_token staked in each pool
        stake_reward_amounts: vector<u64>, // Accumulated staking rewards for each pool
        unstaked_pending_amounts: vector<u64>, // Accumulator for underlying LP tokens waiting to be undelegated in batches
        last_undelegate_time: u64, // Timestamp of the last LP undelegation successfully run

        stake_token_cabal_token_map: SimpleMap<Object<Metadata>, Object<Metadata>>, // stake token ==> cabal token(DFA)
    }

    struct LockExempt has key {
        addresses: vector<address>
    }

    // Mint/freeze/burn capabilities of a specific Cabal token
    struct Capabilities has store {
        burn_cap: cabal_token::BurnCapability,
        freeze_cap: cabal_token::FreezeCapability,
        mint_cap: cabal_token::MintCapability,
    }

    struct CoinCapabilities has store, drop {
        burn_cap: coin::BurnCapability,
        freeze_cap: coin::FreezeCapability,
        mint_cap: coin::MintCapability,
    }

    // Per-user
    struct CabalStore has key {
        unbonding_entries: vector<UnbondingEntry>, // Lists of assets currently unbonding for the user
        // Total amount of voting (bribe) rewards, queried by the token's denom string
        voting_reward_claimed_amount: SimpleMap<String, u64> 
    }

    // A single unboding request for a user
    struct UnbondingEntry has store {
        pool_index: u64,
        metadata: Object<Metadata>,
        amount: u64,
        release_time: u64,
    }

    // Response

    // Detailed info about a specific staking pool
    struct StakePoolResponse has drop {
        stake_id: u64,
        stake_token_name: String,
        stake_token_symbol: String,
        stake_token_metadata: Object<Metadata>,
        stake_token_denom: String,
        stake_token_decimals: u8,
        stake_token_icon_uri: String,
        unstake_token_name: String,
        unstake_token_symbol: String,
        unstake_token_metadata: Object<Metadata>,
        unstake_token_denom: String,
        unstake_token_decimals: u8,
        unstake_token_icon_uri: String,
        unbonding_period: u64,
        staked_amount: u64,
        stake_reward_amount: u64,
    }

    // Information about a token supported by Cabal (INIT, xINIT, sxINIT, Cabal LPs, etc.)
    struct SupportTokenResponse has drop {
        name: String,
        symbol: String,
        metadata: Object<Metadata>,
        denom: String,
        decimals: u8,
        icon_uri: String
    }

    // A single unbonding entry for a user
    struct UnbondingEntryResponse has drop {
        metadata: Object<Metadata>,
        amount: u64,
        release_time: u64,
    }

    // Claimed voting rewards for a specific token type
    struct ClaimedVotingRewardResponse has drop {
        metadata: Object<Metadata>,
        amount: u64,
    }

    public entry fun initialize(account: &signer, init_validator_address: String, commission_fee_store_addr: address) acquires ModuleStore {
        assert!(signer::address_of(account) == @staking_addr, error::unauthenticated(EMODULE_OPERATION));

        let (mint_cap, burn_cap, freeze_cap) = coin::initialize(
            &package::get_assets_store_signer(),
            option::none(),
            string::utf8(b"cabal init coin"),
            string::utf8(b"xINIT"),
            6,
            string::utf8(b""),
            string::utf8(b""),
        );

        let caps = CoinCapabilities { burn_cap, freeze_cap, mint_cap };

        let init_metadata = coin::metadata(@initia_std, string::utf8(b"uinit"));
        let metadata = coin::metadata(package::get_assets_store_address(), string::utf8(b"xINIT"));

        move_to(account, ModuleStore {
            stake_xinit_fee_bps: 0,
            xinit_stake_reward_fee_bps: 0,
            x_init_metadata: metadata,
            x_init_caps: caps,
            unbond_period: vector::empty(),
            stake_token_metadata: vector::empty(),
            cabal_stake_token_metadata: vector::empty(),
            cabal_stake_token_caps: vector::empty(),
            staked_amounts: vector::empty(),
            stake_reward_amounts: vector::empty(),
            unstaked_pending_amounts: vector::empty(),
            last_undelegate_time: 0,
            stake_token_cabal_token_map: simple_map::new()
        });

        pool_router::add_pool(account, init_metadata, init_validator_address);
        emergency::set_pause(account, false);
        package::set_commission_fee_store_addr(account, commission_fee_store_addr);

        config_stake_token(
            account,
            XINIT_UNBOND_PERIOD,
            init_metadata,
            metadata,
            string::utf8(b"cabal stake xinit coin"),
            string::utf8(b"sxINIT"),
            string::utf8(b""),
            string::utf8(b"")
        );

        // USE THIS FOR TESTING
        mock_deposit_init_for_xinit(account, MINIMUM_LIQUIDITY);

        // USE THIS FOR PROD
        //deposit_init_for_xinit(account, MINIMUM_LIQUIDITY);
        
        stake_asset(account, 0, MINIMUM_LIQUIDITY);

        // LEAVE THIS FOR TESTING ONLY. COMMENT THIS OUT FOR PROD.
        process_xinit_stake(&package::get_assets_store_signer(), signer::address_of(account), 0, MINIMUM_LIQUIDITY);

        }

    public entry fun init_fees_exempt(manager: &signer) {
        assert!(manager::is_authorized(manager), error::permission_denied(EUNAUTHORIZED));
        move_to(&package::resource_account_signer(), LockExempt {
            addresses: vector::empty<address>(),
        });
    }

    // ViewFunctions

    // View detailed information about all configured staking pools
    #[view]
    public fun get_pools(): vector<StakePoolResponse> acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);

        let res = vector::empty<StakePoolResponse>();
        for (i in 0..vector::length(&m_store.unbond_period)) {
            vector::push_back(&mut res, StakePoolResponse {
                stake_id: i,
                stake_token_name: fungible_asset::name(m_store.stake_token_metadata[i]),
                stake_token_symbol: fungible_asset::symbol(m_store.stake_token_metadata[i]),
                stake_token_metadata: m_store.stake_token_metadata[i],
                stake_token_denom: coin::metadata_to_denom(m_store.stake_token_metadata[i]),
                stake_token_decimals: fungible_asset::decimals(m_store.stake_token_metadata[i]),
                stake_token_icon_uri: fungible_asset::icon_uri(m_store.stake_token_metadata[i]),
                unstake_token_name: fungible_asset::name(m_store.cabal_stake_token_metadata[i]),
                unstake_token_symbol: fungible_asset::symbol(m_store.cabal_stake_token_metadata[i]),
                unstake_token_metadata: m_store.cabal_stake_token_metadata[i],
                unstake_token_denom: coin::metadata_to_denom(m_store.cabal_stake_token_metadata[i]),
                unstake_token_decimals: fungible_asset::decimals(m_store.cabal_stake_token_metadata[i]),
                unstake_token_icon_uri: fungible_asset::icon_uri(m_store.cabal_stake_token_metadata[i]),
                unbonding_period: m_store.unbond_period[i],
                staked_amount: m_store.staked_amounts[i],
                stake_reward_amount: m_store.stake_reward_amounts[i]
            });
        };

        res
    }

    // Return a map of metadata object of all Cabal origin LSTS to Cabal LSTS (INIT=> sxINIT, LPTs=> Cabal LPTs)
    // Using by voting_reward module to know which balances to check
    #[view]
    public fun get_stake_token_cabal_token_map(): SimpleMap<Object<Metadata>, Object<Metadata>> acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        m_store.stake_token_cabal_token_map
    }

    // Current fee for staking xINIT -> sxINIT 
    #[view]
    public fun stake_xinit_fee_bps(): u64 acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        m_store.stake_xinit_fee_bps
    }

    // Return the current fee taken from the sxINIT rewards (in INIT)
    #[view]
    public fun xinit_stake_reward_fee_bps(): u64 acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        m_store.xinit_stake_reward_fee_bps
    }

    // Return information about all tokens involved in the protocol
    #[view]
    public fun get_support_tokens(): vector<SupportTokenResponse> acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        let init_metadata = coin::metadata(@initia_std, string::utf8(b"uinit"));

        let res = vector::empty<SupportTokenResponse>();
        vector::push_back(&mut res, SupportTokenResponse{
            name: fungible_asset::name(init_metadata),
            symbol: fungible_asset::symbol(init_metadata),
            metadata: init_metadata,
            denom: coin::metadata_to_denom(init_metadata),
            decimals: fungible_asset::decimals(init_metadata),
            icon_uri: fungible_asset::icon_uri(init_metadata),
        });

        for (i in 0..vector::length(&m_store.unbond_period)) {
            vector::push_back(&mut res, SupportTokenResponse {
                name: fungible_asset::name(m_store.stake_token_metadata[i]),
                symbol: fungible_asset::symbol(m_store.stake_token_metadata[i]),
                metadata: m_store.stake_token_metadata[i],
                denom: coin::metadata_to_denom(m_store.stake_token_metadata[i]),
                decimals: fungible_asset::decimals(m_store.stake_token_metadata[i]),
                icon_uri: fungible_asset::icon_uri(m_store.stake_token_metadata[i]),
            });

            vector::push_back(&mut res, SupportTokenResponse {
                name: fungible_asset::name(m_store.cabal_stake_token_metadata[i]),
                symbol: fungible_asset::symbol(m_store.cabal_stake_token_metadata[i]),
                metadata: m_store.cabal_stake_token_metadata[i],
                denom: coin::metadata_to_denom(m_store.cabal_stake_token_metadata[i]),
                decimals: fungible_asset::decimals(m_store.cabal_stake_token_metadata[i]),
                icon_uri: fungible_asset::icon_uri(m_store.cabal_stake_token_metadata[i]),
            });
        };

        res
    }

    // View the amount of a specific voting reward token already claimed by a user
    // Reads data stored in the user's Cabalstore
    #[view]
    public fun get_claimed_voting_reward(account_addr: address, metadata: Object<Metadata>): u64 acquires CabalStore {
        if (!exists<CabalStore>(account_addr)) {
            return 0;
        };
        let cabal_store = borrow_global<CabalStore>(account_addr);
        let coin_denom = coin::metadata_to_denom(metadata);
        if (cabal_store.voting_reward_claimed_amount.contains_key(&coin_denom)) {
            *cabal_store.voting_reward_claimed_amount.borrow(&coin_denom)
        } else {
            0
        }
    }

    // View all claimed voting rewards for a user, across all possible bribe tokens
    #[view]
    public fun get_claimed_voting_rewards(account_addr: address): vector<ClaimedVotingRewardResponse> acquires CabalStore {
        let res = vector::empty<ClaimedVotingRewardResponse>();
        let claimed_map = if (!exists<CabalStore>(account_addr)) {
            simple_map::create()
        } else {
            borrow_global<CabalStore>(account_addr).voting_reward_claimed_amount
        };
        let metadatas = bribe::get_voting_reward_metadatas();

        for (i in 0..vector::length(&metadatas)) {
            let coin_denom = coin::metadata_to_denom(metadatas[i]);
            let amount = if (claimed_map.contains_key(&coin_denom)) {
                *claimed_map.borrow(&coin_denom)
            } else {
                0
            };
            vector::push_back(&mut res, ClaimedVotingRewardResponse{
                metadata: metadatas[i],
                amount
            });
        };

        res
    }

    // View all claimed voting rewards for a user, across all possible bribe tokens
    #[view]
    public fun get_claimed_voting_rewards_in_usd(account_addr: address): BigDecimal acquires CabalStore {
        let total_value = bigdecimal::zero();
        let claimed_map = if (!exists<CabalStore>(account_addr)) {
            simple_map::create()
        } else {
            borrow_global<CabalStore>(account_addr).voting_reward_claimed_amount
        };
        let metadatas = bribe::get_voting_reward_metadatas();

        for (i in 0..vector::length(&metadatas)) {
            let coin_denom = coin::metadata_to_denom(metadatas[i]);
            let amount = if (claimed_map.contains_key(&coin_denom)) {
                *claimed_map.borrow(&coin_denom)
            } else {
                0
            };
            let value = utils::get_token_value_in_usd(metadatas[i], amount);
            total_value = bigdecimal::add(total_value, value);
        };

        total_value
    }

    // Calculate the total voting power controlled by Cabal across all pools
    // Sum from the assets store/sxINIT and each pool object/Cabal LPTs
    #[view]
    public fun get_voting_power(): u64 {
        let power = weight_vote::get_voting_power(package::get_assets_store_address());
        let addresses = pool_router::get_all_pool_address();
        for (i in 0..vector::length(&addresses)) {
            power = power + weight_vote::get_voting_power(addresses[i]);
        };
        power
    }

    // View function to calculate the relative weight of each Cabal token in the final voting power
    // Used by voting_reward during snapshotting
    #[view]
    public fun get_voting_power_weight(): SimpleMap<Object<Metadata>, BigDecimal> acquires ModuleStore {
        let res = simple_map::new<Object<Metadata>, BigDecimal>();
        let weights = pool_router::get_voting_power_weight();
        let keys = simple_map::keys(&weights);

        for (i in 0..vector::length(&keys)) {
            simple_map::add(
                &mut res,
                convert_to_cabal_token(keys[i]),
                *simple_map::borrow(&weights, &keys[i])
            );
        };

        res
    }

    // View function to get the list of all active unbonding entries for a user
    #[view]
    public fun get_unbonding_list(addr: address): vector<UnbondingEntryResponse> acquires CabalStore {
        if (!exists<CabalStore>(addr)) {
            return vector[]
        };

        let cabal_store = borrow_global<CabalStore>(addr);

        let res = vector::empty<UnbondingEntryResponse>();
        let len = vector::length(&cabal_store.unbonding_entries);
        let i = 0;
        while( i < len ) {
            let unbonding_entry = vector::borrow(&cabal_store.unbonding_entries, i);
            vector::push_back(&mut res, UnbondingEntryResponse{
                metadata: unbonding_entry.metadata,
                amount: unbonding_entry.amount,
                release_time: unbonding_entry.release_time,
            });
            i = i + 1;
        };

        res
    }

    // View function to get the cabal of cabal tvl
    #[view]
    public fun get_cabal_tvl(): BigDecimal acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        let tokens = simple_map::keys(&m_store.stake_token_cabal_token_map);
        let total_value = bigdecimal::zero();
        for (i in 0..vector::length(&tokens)) {
            let amount = pool_router::get_real_total_stakes(tokens[i]);
            let value = utils::get_token_value_in_usd(tokens[i], amount);
            total_value = bigdecimal::add(total_value, value);
        };
        total_value
    }

    // View function to get the pool tvl
    #[view]
    public fun get_cabal_tvl_for_pool(pool_index: u64): BigDecimal acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        assert!(vector::length(&m_store.unbond_period) > pool_index, error::out_of_range(EINVALID_INDEX));
        let stake_metadata = if (m_store.stake_token_metadata[pool_index] == m_store.x_init_metadata) {
            utils::get_init_metadata()
        } else {
            m_store.stake_token_metadata[pool_index]
        };

        let amount = pool_router::get_real_total_stakes(stake_metadata);
        let value = utils::get_token_value_in_usd(stake_metadata, amount);
        value
    }

    // View function to get the percent of staked xINIT
    #[view]
    public fun get_xinit_staked_percent(): BigDecimal acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        let staked_amount = coin::balance(package::get_assets_store_address(), m_store.x_init_metadata);
        let supply = coin::supply(m_store.x_init_metadata);
        if (option::get_with_default(&supply, 0) == 0) {
            return bigdecimal::zero();
        };
        bigdecimal::from_ratio_u128(staked_amount as u128, option::extract(&mut supply))
    }

    #[view]
    public fun get_estimate_unstake_amount(unstaking_type: u64, unstaking_amount: u64): u64 acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        assert!(vector::length(&m_store.unbond_period) > unstaking_type, error::out_of_range(EINVALID_INDEX));

        if (m_store.stake_token_metadata[unstaking_type] != m_store.x_init_metadata) {
            let lp_amount = pool_router::get_real_total_stakes(m_store.stake_token_metadata[unstaking_type]);
            let cabal_lp_amount = option::extract(&mut fungible_asset::supply(m_store.cabal_stake_token_metadata[unstaking_type]));
            let ratio = bigdecimal::from_ratio_u128(unstaking_amount as u128, cabal_lp_amount);
            bigdecimal::mul_by_u64_truncate(ratio, lp_amount)
        } else {
            let x_init_amount = m_store.staked_amounts[unstaking_type];
            let sx_init_amount = option::extract(&mut fungible_asset::supply(m_store.cabal_stake_token_metadata[unstaking_type]));
            let ratio = bigdecimal::from_ratio_u128(unstaking_amount as u128, sx_init_amount);
            bigdecimal::mul_by_u64_truncate(ratio, x_init_amount)
        }
    }

    // Ensure that a Cabalstore exists for a signer. If not, then register is and create it.
    public fun ensure_cabal_store_exists(account: &signer) {
        if (!exists<CabalStore>(signer::address_of(account))) {
            register(account);
        };
    }


    // Internal function used by voting reward to get the claimed voting reward for a user and token
    public fun get_claimed_voting_reward_amount(account_addr: address, metadata: Object<Metadata>): u64 acquires CabalStore {
        assert!(exists<CabalStore>(account_addr), error::not_found(ECABAL_STORE_NOT_FOUND));
        let cabal_store = borrow_global<CabalStore>(account_addr);
        let coin_denom = coin::metadata_to_denom(metadata);
        if (cabal_store.voting_reward_claimed_amount.contains_key(&coin_denom)) {
            *cabal_store.voting_reward_claimed_amount.borrow(&coin_denom)
        } else {
            0
        }
    }

    // Internal function to update the claimed voting reward for a user for a token
    public(friend) fun update_claimed_voting_reward_amount(account_addr: address, metadata: Object<Metadata>, new_amount: u64) acquires CabalStore {
        assert!(exists<CabalStore>(account_addr), error::not_found(ECABAL_STORE_NOT_FOUND));
        let cabal_store = borrow_global_mut<CabalStore>(account_addr);
        let coin_denom = coin::metadata_to_denom(metadata);
        cabal_store.voting_reward_claimed_amount.upsert(coin_denom, new_amount);
    }

    // EntryFunctions

    // Admin function to configure a new staking pool/token (for a new LP token for example)
    public entry fun config_stake_token(account: &signer, unbond_period: u64, origin_token_metadata: Object<Metadata>, stake_token_metadata: Object<Metadata>, name: String, symbol: String, icon_uri: String, project_uri: String) acquires ModuleStore {
        // Only the staking addr should be able to call this 
        assert!(signer::address_of(account) == @staking_addr, error::unauthenticated(EMODULE_OPERATION));
        
        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);

        vector::push_back(&mut m_store.unbond_period, unbond_period);
        vector::push_back(&mut m_store.stake_token_metadata, stake_token_metadata);

        let (mint_cap, burn_cap, freeze_cap) = cabal_token::initialize(
            &package::get_assets_store_signer(), // account (object creator)
            account, // module_owner (@staking_addr)
            option::none(),
            name,
            symbol,
            fungible_asset::decimals(stake_token_metadata),
            icon_uri,
            project_uri
        );
        let caps = Capabilities { burn_cap, freeze_cap, mint_cap };
        let cabal_token_metadata = cabal_token::metadata(package::get_assets_store_address(), symbol);

        vector::push_back(&mut m_store.cabal_stake_token_metadata, cabal_token_metadata);
        vector::push_back(&mut m_store.cabal_stake_token_caps, caps);
        vector::push_back(&mut m_store.staked_amounts, 0);
        vector::push_back(&mut m_store.stake_reward_amounts, 0);
        vector::push_back(&mut m_store.unstaked_pending_amounts, 0);
        link_stake_token2cabal_token(origin_token_metadata, cabal_token_metadata);
    }

    public entry fun set_unbond_period(account: &signer, pool_index: u64, unbond_period: u64) acquires ModuleStore {
        assert!(manager::is_authorized(account), error::permission_denied(EUNAUTHORIZED));
        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);
        assert!(vector::length(&m_store.unbond_period) > pool_index, error::out_of_range(EINVALID_INDEX));
        m_store.unbond_period[pool_index] = unbond_period;
    }

    public entry fun set_fees_exempt(manager: &signer, addresses: vector<address>) acquires LockExempt {
        assert!(manager::is_authorized(manager), error::permission_denied(EUNAUTHORIZED));

        let fees_exempt = borrow_global_mut<LockExempt>(package::resource_account_address());
        fees_exempt.addresses = addresses;
    }

    public entry fun set_stake_xinit_fee_bps(account: &signer, new_bps: u64) acquires ModuleStore {
        assert!(manager::is_authorized(account), error::permission_denied(EUNAUTHORIZED));
        assert!(new_bps <= BPS_BASE, error::invalid_argument(EINVALID_BPS));

        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);
        m_store.stake_xinit_fee_bps = new_bps;
    }

    public entry fun set_xinit_stake_reward_fee_bps(account: &signer, new_bps: u64) acquires ModuleStore {
        assert!(manager::is_authorized(account), error::permission_denied(EUNAUTHORIZED));
        assert!(new_bps <= BPS_BASE, error::invalid_argument(EINVALID_BPS));

        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);
        m_store.xinit_stake_reward_fee_bps = new_bps;
    }

    // Called to compound all existing LP rewards
    public entry fun batch_undelegate_pending_lps() acquires ModuleStore {
        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);
        let (_, block_time) = block::get_block_info();
        assert!(block_time > m_store.last_undelegate_time + UNDELEGATE_LP_INTERVAL, error::invalid_state(ENOT_TIME_YET));
        m_store.last_undelegate_time = block_time;

        for (i in 0..vector::length(&m_store.unbond_period)) {
            if (m_store.unstaked_pending_amounts[i] == 0) {
                continue;
            };

            // undelegate
            pool_router::unlock(m_store.stake_token_metadata[i], m_store.unstaked_pending_amounts[i]);

            // clear pending
            m_store.unstaked_pending_amounts[i] = 0;
        };
    }

    /// publish CabalStore for a user
    public entry fun register(account: &signer) {
        assert!(!exists<CabalStore>(signer::address_of(account)), error::already_exists(ECABAL_STORE_ALREADY_EXISTS));
        move_to(account, CabalStore{
            unbonding_entries: vector::empty(),
            voting_reward_claimed_amount: simple_map::create()
        });
    }

    // Entry function for a user to deposit native INIT and receive xINIT
    public entry fun deposit_init_for_xinit(account: &signer, deposit_amount: u64) acquires ModuleStore {
        emergency::assert_no_paused();
        assert!(deposit_amount > 0, error::invalid_argument(EINVALID_COIN_AMOUNT));
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        let coin_metadata = coin::metadata(@initia_std, string::utf8(b"uinit"));

        // calculate mint xinit
        let init_amount = pool_router::get_real_total_stakes(coin_metadata);

        let x_init_amount = option::extract(&mut fungible_asset::supply(m_store.x_init_metadata));
        let mint_x_init_amount = if (x_init_amount == 0) {
            deposit_amount
        } else {
            let ratio = bigdecimal::from_ratio_u64(deposit_amount, init_amount);
            // Round up because of trunaction
            (bigdecimal::mul_by_u128_ceil(ratio, x_init_amount) as u64)
        };
        assert!(mint_x_init_amount > 0, error::invalid_argument(EINVALID_STAKE_AMOUNT));

        // withdraw init to stake
        let fa = primary_fungible_store::withdraw(
            account,
            coin_metadata,
            deposit_amount
        );
        pool_router::add_stake(fa);

        // mint xINIT to user
        coin::mint_to(&m_store.x_init_caps.mint_cap, signer::address_of(account), mint_x_init_amount);
    }

    // Entry function for a user to stake an asset (xINIT or LP token) into a specific pool
    public entry fun stake_asset(account: &signer, staking_type: u64, stake_amount: u64) acquires ModuleStore {
        emergency::assert_no_paused();
        assert!(stake_amount > 0, error::invalid_argument(EINVALID_COIN_AMOUNT));
        let account_addr = signer::address_of(account);

        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);
        assert!(vector::length(&m_store.unbond_period) > staking_type, error::out_of_range(EINVALID_INDEX));

        // transfer stake token to pool
        primary_fungible_store::transfer(
            account,
            m_store.stake_token_metadata[staking_type],
            package::get_assets_store_address(),
            stake_amount
        );

        if (m_store.stake_token_metadata[staking_type] != m_store.x_init_metadata) {
            stake_lp(account_addr, m_store, staking_type, stake_amount);
        } else {
            stake_xinit(account_addr, staking_type, stake_amount);
        };
    }

    // Entry function for a user to unstake their Cabal LST such as sxINIT or Cabal LPT
    public entry fun initiate_unstake(account: &signer, unstaking_type: u64, unstaking_amount: u64) acquires ModuleStore {
        emergency::assert_no_paused();
        assert!(unstaking_amount > 0, error::invalid_argument(EINVALID_COIN_AMOUNT));
        let account_addr = signer::address_of(account);
        ensure_cabal_store_exists(account);

        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);
        assert!(vector::length(&m_store.unbond_period) > unstaking_type, error::out_of_range(EINVALID_INDEX));

        // undelegate
        if (m_store.stake_token_metadata[unstaking_type] != m_store.x_init_metadata) {
            unstake_lp(account_addr, m_store, unstaking_type, unstaking_amount);
        } else {
            unstake_xinit(account_addr, unstaking_type, unstaking_amount);
        };

        // withdraw to burn
        let burn_coin = primary_fungible_store::withdraw(account, m_store.cabal_stake_token_metadata[unstaking_type], unstaking_amount);
        cabal_token::burn(&m_store.cabal_stake_token_caps[unstaking_type].burn_cap, burn_coin);
    }


    // Entry function for a user to claim their underlying assets that have finished unbonding
    public entry fun claim_unbonded_assets(account: &signer, indices: vector<u64>) acquires CabalStore {
        emergency::assert_no_paused();
        let account_addr = signer::address_of(account);
        assert!(exists<CabalStore>(account_addr), error::not_found(ECABAL_STORE_NOT_FOUND));

        let cabal_store = borrow_global_mut<CabalStore>(account_addr);
        let (_, block_time) = block::get_block_info();

        let sorted_indices: vector<u64> = vector[];
        for (i in 0..vector::length(&cabal_store.unbonding_entries)) {
            if (vector::contains(&indices, &i)) {
                vector::push_back(&mut sorted_indices, i);
            };
        };
        vector::reverse(&mut sorted_indices);
        assert!(vector::length(&indices) == vector::length(&sorted_indices), error::out_of_range(EINVALID_INDEX));

        for (i in 0..vector::length(&sorted_indices)) {
            let unbonding_entry = vector::remove(&mut cabal_store.unbonding_entries, sorted_indices[i]);
            // destroy unbonding_entry
            let UnbondingEntry {
                pool_index: _,
                metadata,
                amount,
                release_time,
            } = unbonding_entry;

            assert!(block_time > release_time, error::unavailable(ENOT_RELEASED));
            let fa = pool_router::withdraw_assets(metadata);
            primary_fungible_store::deposit(package::get_assets_store_address(), fa);

            // transfer staking token to user
            primary_fungible_store::transfer(
                &package::get_assets_store_signer(),
                metadata,
                account_addr,
                amount
            );
        };
    }

    // entry function for the @staking_addr admin to submit votes to the VIP weight_vote module
    // Use the combined voting power from all Cabal pools
    public entry fun vote(account: &signer,
                      cycle: u64, // Current voting cycle
                      bridge_ids: vector<u64>, // Vector of bridge IDs to vote for
                      weights: vector<BigDecimal> // Corresponding weights for each bridge ID
                      ) {
        emergency::assert_no_paused();
        // Only the manager
        assert!(manager::is_authorized(account), error::permission_denied(EUNAUTHORIZED));

        let signers = pool_router::get_all_signers();

        // Vote using each pool object signer (Cabal LPT power)
        for (i in 0..vector::length(&signers)) {
            weight_vote::vote(&signers[i], cycle, bridge_ids, weights);
        };
    }


    // Entry function for the admin to vote based on calculated bribe weights
    public entry fun vote_using_bribe_weights(account: &signer,
                      cycle: u64) {
        emergency::assert_no_paused();

        // Only the manager
        assert!(manager::is_authorized(account), error::permission_denied(EUNAUTHORIZED));


        let bribeInfos = bribe::calculate_bribe_weights_for_cycle(cycle);
        assert!(vector::length(&bribeInfos) > 0, error::invalid_state(EINVALID_BRIBE));

        let bridge_ids: vector<u64> = vector::empty();
        let weights: vector<BigDecimal> = vector::empty();
        for (i in 0..vector::length(&bribeInfos)) {
            let (bridge_id, _, weight) = bribe::unpack_bridge_reward_response(bribeInfos[i]);
            vector::push_back(&mut bridge_ids, bridge_id);
            vector::push_back(&mut weights, weight);
        };

        vote(account, cycle, bridge_ids, weights)
    }

    // Internal function to update the sxINIT pool (pool 0) based on accumulated INIT rewards
    fun compound_xinit_pool_rewards(m_store: &mut ModuleStore, pool_index: u64) {
        let coin_metadata = coin::metadata(@initia_std, string::utf8(b"uinit"));
        let reward_fa = pool_router::withdraw_rewards(coin_metadata);
        let reward_amount = fungible_asset::amount(&reward_fa);

        // debug::print(&string::utf8(b"Reward from pool amount"));
        // debug::print(&(reward_amount / 1_000_000));


        if (reward_amount > 0) {
            // calculate fee amount
            let fee_ratio = bigdecimal::from_ratio_u64(m_store.xinit_stake_reward_fee_bps, BPS_BASE);
            let fee_amount = bigdecimal::mul_by_u64_truncate(fee_ratio, reward_amount);
            let fee_fa = fungible_asset::extract(&mut reward_fa, fee_amount);
            let rewards_remaining = reward_amount - fee_amount;
            primary_fungible_store::deposit(package::get_commission_fee_store_address(), fee_fa);

            m_store.stake_reward_amounts[pool_index] = m_store.stake_reward_amounts[pool_index] + rewards_remaining;
            pool_router::add_stake(reward_fa);

            // mint xINIT to pool
            m_store.staked_amounts[pool_index] = m_store.staked_amounts[pool_index] + rewards_remaining;
            coin::mint_to(&m_store.x_init_caps.mint_cap, package::get_assets_store_address(), rewards_remaining);
        } else {
            fungible_asset::destroy_zero(reward_fa);
        }
    }

    // Internal function to initiate the xINIT staking process
    // Claims rewards via pool_router and triggers the process function via move_execute
    // This is done for timing/async issue reasons
    fun stake_xinit(account_addr: address, staking_type: u64, stake_amount: u64) {
        let extend_signer = package::get_assets_store_signer();
        let coin_metadata = coin::metadata(@initia_std, string::utf8(b"uinit"));
        pool_router::request_claim_rewards(coin_metadata);

        cosmos::move_execute(
            &extend_signer,
            @staking_addr,
            string::utf8(b"cabal"),
            string::utf8(b"process_xinit_stake"),
            vector[],
            vector[
                bcs::to_bytes(&account_addr),
                bcs::to_bytes(&staking_type),
                bcs::to_bytes(&stake_amount),],
        )
    }

    // Helper function executed via move_execute to handle xINIT staking logic
    // Updates rewards, calculated fees, calculates mint amount based on ratio, updates state, and mints sxINIT
    // Internal helper function executed via move_execute to handle xINIT staking logic
    entry fun process_xinit_stake(account: &signer, staker_addr: address, staking_type: u64, stake_amount: u64) acquires ModuleStore {
        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);
        let assets_extend_addr = package::get_assets_store_address();
        assert!(signer::address_of(account) == assets_extend_addr, error::permission_denied(EUNAUTHORIZED));

        // // Update pool rewards before calculating mint ratio
        compound_xinit_pool_rewards(m_store, staking_type);

        // Calculate and deduct staking fee
        let fee_ratio = bigdecimal::from_ratio_u64(m_store.stake_xinit_fee_bps, BPS_BASE);
        // Given to sxINIT holders as "income", it's just taken out of this user. We don't take it for ourselves.
        let fee_amount = bigdecimal::mul_by_u64_truncate(fee_ratio, stake_amount);

        // calculate mint sx init
        let x_init_amount = m_store.staked_amounts[staking_type];

        // debug::print(&string::utf8(b"Inside process_xinit_stake, the initial x_init_amount staked is"));
        // debug::print(&(x_init_amount / 1_000_000));


        let sx_init_amount = option::extract(&mut fungible_asset::supply(m_store.cabal_stake_token_metadata[staking_type]));
        let net_stake_amount = stake_amount - fee_amount;
        let mint_sx_init_amount = if (sx_init_amount == 0) {
            net_stake_amount
        } else {
            let ratio = bigdecimal::from_ratio_u64(net_stake_amount, x_init_amount);
            // So net_stake * (sx_supply / x_init_in_pool)?
            (bigdecimal::mul_by_u128_truncate(ratio, sx_init_amount) as u64)
        };


        assert!(mint_sx_init_amount > 0, error::invalid_argument(EINVALID_STAKE_AMOUNT));

        // Update the total underlying xINIT staked in the pool
        m_store.staked_amounts[staking_type] = m_store.staked_amounts[staking_type] + stake_amount;


        // debug::print(&string::utf8(b"Inside process_xinit_stake, the input argument stake amount is"));
        // debug::print(&(stake_amount / 1_000_000));

        // debug::print(&string::utf8(b"Inside process_xinit_stake, the prior sx_init_amount is"));
        // debug::print(&(sx_init_amount / 1_000_000));

        // debug::print(&string::utf8(b"Inside process_xinit_stake, the mint_sx_init_amount is"));
        // debug::print(&(net_stake_amount / 1_000_000));

        // Mint the calculated amount of sxINIT to the user 
        cabal_token::mint_to(&m_store.cabal_stake_token_caps[staking_type].mint_cap, staker_addr, mint_sx_init_amount);
    }

    fun compound_lp_pool_rewards(m_store: &mut ModuleStore, pool_index: u64): u64 {
        let reward_fa = pool_router::withdraw_rewards(m_store.stake_token_metadata[pool_index]);
        let reward_amount = fungible_asset::amount(&reward_fa);

        if (reward_amount > 0) {
            let lp = dex::single_asset_provide_liquidity(object::convert<Metadata, Config>(m_store.stake_token_metadata[pool_index]), reward_fa, option::some<u64>(1));
            let reward_lp = fungible_asset::amount(&lp);

            pool_router::add_stake(lp);

            m_store.stake_reward_amounts[pool_index] = m_store.stake_reward_amounts[pool_index] + reward_lp;
            m_store.staked_amounts[pool_index] = m_store.staked_amounts[pool_index] + reward_lp;
            return reward_lp;
        } else {
            fungible_asset::destroy_zero(reward_fa);
        };
        0
    }

    fun stake_lp(account_addr: address, m_store: &mut ModuleStore, staking_type: u64, stake_amount: u64) {
        // claim reward
        if (m_store.staked_amounts[staking_type] > 0)  {
            pool_router::request_claim_rewards(m_store.stake_token_metadata[staking_type]);
        };

        cosmos::move_execute(
            &package::get_assets_store_signer(),
            @staking_addr,
            string::utf8(b"cabal"),
            string::utf8(b"process_lp_stake"),
            vector[],
            vector[
                bcs::to_bytes(&account_addr),
                bcs::to_bytes(&staking_type),
                bcs::to_bytes(&stake_amount),],
        )
    }

    // Update rewards, calculates mint amount based on the ratio, delegates LP, updates state, mints Cabal LPT
    // Internal helper function executed via move_execute to handle LP staking logic
    entry fun process_lp_stake(account: &signer, staker_addr: address, staking_type: u64, stake_amount: u64) acquires ModuleStore {
        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);
        let assets_extend_addr = package::get_assets_store_address();
        assert!(signer::address_of(account) == assets_extend_addr, error::permission_denied(EUNAUTHORIZED));

        let reward_amount = compound_lp_pool_rewards(m_store, staking_type);

        // calculate mint cabal lp token amount
        let lp_amount = reward_amount + pool_router::get_real_total_stakes(m_store.stake_token_metadata[staking_type]);
        let cabal_lp_amount = option::extract(&mut fungible_asset::supply(m_store.cabal_stake_token_metadata[staking_type]));
        let mint_cabal_lp_amount = if (cabal_lp_amount == 0) {
            stake_amount
        } else {
            let ratio = bigdecimal::from_ratio_u64(stake_amount, lp_amount);
            (bigdecimal::mul_by_u128_truncate(ratio, cabal_lp_amount) as u64)
        };
        assert!(mint_cabal_lp_amount > 0, error::invalid_argument(EINVALID_STAKE_AMOUNT));

        // staking to mstaking
        let stake_fa = primary_fungible_store::withdraw(
            &package::get_assets_store_signer(),
            m_store.stake_token_metadata[staking_type],
            stake_amount
        );
        pool_router::add_stake(stake_fa);
        m_store.staked_amounts[staking_type] = m_store.staked_amounts[staking_type] + stake_amount;
        // mint cabal staking token to user
        cabal_token::mint_to(&m_store.cabal_stake_token_caps[staking_type].mint_cap, staker_addr, mint_cabal_lp_amount);
    }

    fun unstake_xinit(account_addr: address, unstaking_type: u64, unstake_amount: u64) {
        let extend_signer = package::get_assets_store_signer();
        let coin_metadata = coin::metadata(@initia_std, string::utf8(b"uinit"));
        pool_router::request_claim_rewards(coin_metadata);

        cosmos::move_execute(
            &extend_signer,
            @staking_addr,
            string::utf8(b"cabal"),
            string::utf8(b"process_xinit_unstake"),
            vector[],
            vector[
                bcs::to_bytes(&account_addr),
                bcs::to_bytes(&unstaking_type),
                bcs::to_bytes(&unstake_amount),],
        );
    }

    // Helper function executed via move_execute to handle xINIT unstaking logic
    // Updates rewards, calculates underlying xINIT to unbond, updates state, creates unbonding entry
    entry fun process_xinit_unstake(account: &signer, staker_addr: address, unstaking_type: u64, unstake_amount: u64) acquires ModuleStore, CabalStore, LockExempt {
        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);
        let extend_addr = package::get_assets_store_address();
        assert!(signer::address_of(account) == extend_addr, error::permission_denied(EUNAUTHORIZED));

        compound_xinit_pool_rewards(m_store, unstaking_type);

        // calculate claim xinit
        let x_init_amount = m_store.staked_amounts[unstaking_type];
        let sx_init_amount = option::extract(&mut fungible_asset::supply(m_store.cabal_stake_token_metadata[unstaking_type]));
        let ratio = bigdecimal::from_ratio_u128(unstake_amount as u128, sx_init_amount);
        let unbonding_amount = bigdecimal::mul_by_u64_truncate(ratio, x_init_amount);
        
        m_store.staked_amounts[unstaking_type] = m_store.staked_amounts[unstaking_type] - unbonding_amount;

        // skip lock period if user is in the whitelist
        if (vector::contains(
            &borrow_global<LockExempt>(package::resource_account_address()).addresses,
            &staker_addr)
        ) {
            primary_fungible_store::transfer(
                &package::get_assets_store_signer(),
                m_store.stake_token_metadata[unstaking_type],
                staker_addr,
                unbonding_amount
            )
        } else {
            let (_, block_time) = block::get_block_info();
            let cabal_store = borrow_global_mut<CabalStore>(staker_addr);
            vector::push_back(&mut cabal_store.unbonding_entries, UnbondingEntry {
                pool_index: unstaking_type,
                metadata: m_store.stake_token_metadata[unstaking_type],
                amount: unbonding_amount,
                release_time: block_time + m_store.unbond_period[unstaking_type],
            });
        }
    }

    fun unstake_lp(account_addr: address, m_store: &mut ModuleStore, unstaking_type: u64, unstaking_amount: u64) {
        // claim reward
        pool_router::request_claim_rewards(m_store.stake_token_metadata[unstaking_type]);

        cosmos::move_execute(
            &package::get_assets_store_signer(),
            @staking_addr,
            string::utf8(b"cabal"),
            string::utf8(b"process_lp_unstake"),
            vector[],
            vector[
                bcs::to_bytes(&account_addr),
                bcs::to_bytes(&unstaking_type),
                bcs::to_bytes(&unstaking_amount),],
        );
    }

    entry fun process_lp_unstake(account: &signer, staker_addr: address, unstaking_type: u64, unstake_amount: u64) acquires ModuleStore, CabalStore {
        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);
        let extend_addr = package::get_assets_store_address();
        assert!(signer::address_of(account) == extend_addr, error::permission_denied(EUNAUTHORIZED));

        let reward_amount = compound_lp_pool_rewards(m_store, unstaking_type);

        // calculate claim lp token amount
        let lp_amount = reward_amount + pool_router::get_real_total_stakes(m_store.stake_token_metadata[unstaking_type]);
        let cabal_lp_amount = option::extract(&mut fungible_asset::supply(m_store.cabal_stake_token_metadata[unstaking_type]));
        let ratio = bigdecimal::from_ratio_u128(unstake_amount as u128, cabal_lp_amount);
        let unbonding_amount = bigdecimal::mul_by_u64_truncate(ratio, lp_amount);

        m_store.staked_amounts[unstaking_type] = m_store.staked_amounts[unstaking_type] - unbonding_amount;
        // Changes rolled back
        // // skip lock period if user is in the whitelist
        // if (vector::contains(
        //     &borrow_global<LockExempt>(package::resource_account_address()).addresses,
        //     &staker_addr)
        // ) {
        //     primary_fungible_store::transfer(
        //         &package::get_assets_store_signer(),
        //         m_store.stake_token_metadata[unstaking_type],
        //         staker_addr,
        //         unbonding_amount
        //     )
        // } else {
        m_store.unstaked_pending_amounts[unstaking_type] = m_store.unstaked_pending_amounts[unstaking_type] + unbonding_amount;

        // deposit unbonding entry
        let (_, block_time) = block::get_block_info();
        let cabal_store = borrow_global_mut<CabalStore>(staker_addr);
        vector::push_back(&mut cabal_store.unbonding_entries, UnbondingEntry {
            pool_index: unstaking_type,
            metadata: m_store.stake_token_metadata[unstaking_type],
            amount: unbonding_amount,
            release_time: block_time + m_store.unbond_period[unstaking_type],
        });
        //}
        
    }

    fun link_stake_token2cabal_token(stake_token_metadata: Object<Metadata>, cabal_token_metadata: Object<Metadata>) acquires ModuleStore {
        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);
        simple_map::upsert(&mut m_store.stake_token_cabal_token_map, stake_token_metadata, cabal_token_metadata);
    }

    fun convert_to_cabal_token(stake_token_metadata: Object<Metadata>): Object<Metadata> acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        assert!(simple_map::contains_key(&m_store.stake_token_cabal_token_map, &stake_token_metadata), error::invalid_argument(EINVALID_TOKEN));
        *simple_map::borrow(&m_store.stake_token_cabal_token_map, &stake_token_metadata)
    }

    // --- View Functions for Testing ---

    #[view]
    public fun get_xinit_metadata(): Object<Metadata> acquires ModuleStore {
        borrow_global<ModuleStore>(@staking_addr).x_init_metadata
    }

    #[view]
    public fun get_sxinit_metadata(): Object<Metadata> acquires ModuleStore {
        // Assumes sxINIT is always pool 0
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        assert!(vector::length(&m_store.cabal_stake_token_metadata) > 0, EINVALID_INDEX);
        m_store.cabal_stake_token_metadata[0]
    }

    #[view]
    public fun get_cabal_token_metadata(pool_index: u64): Object<Metadata> acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        assert!(vector::length(&m_store.cabal_stake_token_metadata) > 0, EINVALID_INDEX);
        m_store.cabal_stake_token_metadata[pool_index]
    }

    #[view]
    public fun get_xinit_pool_staked_amount(): u64 acquires ModuleStore {
        // Assumes sxINIT pool is always pool 0
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        assert!(vector::length(&m_store.staked_amounts) > 0, EINVALID_INDEX);
        m_store.staked_amounts[0]
    }

    #[view]
    public fun get_lp_pool_staked_amount(pool_index: u64): u64 acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        assert!(vector::length(&m_store.staked_amounts) > 0, EINVALID_INDEX);
        m_store.staked_amounts[pool_index]
    }

    #[view]
    public fun get_xinit_pool_unbonding_period(): u64 acquires ModuleStore {
        // Assumes sxINIT pool is always pool 0
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        assert!(vector::length(&m_store.unbond_period) > 0, EINVALID_INDEX);
        m_store.unbond_period[0]
    }

    #[view]
    public fun get_xinit_total_supply(): u128 acquires ModuleStore {
        let meta = get_xinit_metadata();
        option::get_with_default(&fungible_asset::supply(meta), 0)
    }

    #[view]
    public fun get_sxinit_total_supply(): u128 acquires ModuleStore {
        let meta = get_sxinit_metadata();
        option::get_with_default(&fungible_asset::supply(meta), 0)
    }

    #[view]
    public fun get_cabal_token_total_supply(pool_index: u64): u128 acquires ModuleStore {
        let meta = get_cabal_token_metadata(pool_index);
        option::get_with_default(&fungible_asset::supply(meta), 0)
    }

    #[view]
    public fun get_pool_router_total_init(): u64 {
        let init_metadata = coin::metadata(@initia_std, string::utf8(b"uinit"));
        pool_router::get_total_stakes(init_metadata)
    }

    #[view]
    public fun get_lp_pool_unstaked_pending_amount(pool_index: u64): u64 acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        assert!(vector::length(&m_store.unstaked_pending_amounts) > 0, EINVALID_INDEX);
        m_store.unstaked_pending_amounts[pool_index]
    }
    // --- Friend Functions for Testing ---

    #[test_only]
    public fun unpack_unbonding_entry_response(response: UnbondingEntryResponse): (Object<Metadata>, u64, u64) {
        (response.metadata, response.amount, response.release_time)
    }

    #[test_only]
    public fun mock_deposit_init_for_xinit(account: &signer, deposit_amount: u64) acquires ModuleStore {
        emergency::assert_no_paused();
        assert!(deposit_amount > 0, error::invalid_argument(EINVALID_COIN_AMOUNT));
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        let coin_metadata = coin::metadata(@initia_std, string::utf8(b"uinit"));

        // calculate mint xinit
        let init_amount = pool_router::get_total_stakes(coin_metadata);

        let x_init_amount = option::extract(&mut fungible_asset::supply(m_store.x_init_metadata));
        let mint_x_init_amount = if (x_init_amount == 0) {
            deposit_amount
        } else {
            let ratio = bigdecimal::from_ratio_u64(deposit_amount, init_amount);
            // Round up because of trunaction
            (bigdecimal::mul_by_u128_ceil(ratio, x_init_amount) as u64)
        };
        assert!(mint_x_init_amount > 0, error::invalid_argument(EINVALID_STAKE_AMOUNT));

        // withdraw init to stake
        let fa = primary_fungible_store::withdraw(
            account,
            coin_metadata,
            deposit_amount
        );
    
        pool_router::mock_add_stake(fa);
            
        // mint xINIT to user
        coin::mint_to(&m_store.x_init_caps.mint_cap, signer::address_of(account), mint_x_init_amount);
    }

    // Mocks the staking process including the async callback for testing purposes
    #[test_only]
    public fun mock_stake(account: &signer, staking_type: u64, stake_amount: u64) acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        let account_address = signer::address_of(account);

        // 0 for INIT, 1 for Cabal LP
        let is_stake_xinit = m_store.stake_token_metadata[staking_type] == m_store.x_init_metadata;

        stake_asset(account, staking_type, stake_amount);     

        if (is_stake_xinit) {
            process_xinit_stake(&package::get_assets_store_signer(), account_address, staking_type, stake_amount);
        } else {
            mock_process_lp_stake(&package::get_assets_store_signer(), account_address, staking_type, stake_amount);
        }
    }

    #[test_only]
    public fun mock_process_lp_stake(
        account: &signer,
        staker_addr: address,
        staking_type: u64,
        stake_amount: u64,
    ) acquires ModuleStore {
        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);
        let assets_extend_addr = package::get_assets_store_address();
        assert!(signer::address_of(account) == assets_extend_addr, error::permission_denied(EUNAUTHORIZED));

        mock_compound_lp_pool_rewards(m_store, staking_type);

        // calculate mint cabal lp token amount
        let lp_amount = m_store.staked_amounts[staking_type];
        let cabal_lp_amount = option::extract(
            &mut fungible_asset::supply(m_store.cabal_stake_token_metadata[staking_type])
        );
        let mint_cabal_lp_amount = if (cabal_lp_amount == 0) {
            stake_amount
        } else {
            let ratio = bigdecimal::from_ratio_u64(stake_amount, lp_amount);
            (bigdecimal::mul_by_u128_truncate(ratio, cabal_lp_amount) as u64)
        };
        assert!(mint_cabal_lp_amount > 0, error::invalid_argument(EINVALID_STAKE_AMOUNT));

        // staking to mstaking
        let stake_fa = primary_fungible_store::withdraw(
            &package::get_assets_store_signer(),
            m_store.stake_token_metadata[staking_type],
            stake_amount
        );
        pool_router::mock_add_stake(stake_fa);
        m_store.staked_amounts[staking_type] = m_store.staked_amounts[staking_type] + stake_amount;
        // mint cabal staking token to user
        cabal_token::mint_to(&m_store.cabal_stake_token_caps[staking_type].mint_cap, staker_addr, mint_cabal_lp_amount);
    }

    #[test_only]
    fun mock_compound_lp_pool_rewards(m_store: &mut ModuleStore, pool_index: u64): u64 {
        let reward_fa = pool_router::withdraw_rewards(m_store.stake_token_metadata[pool_index]);
        let reward_amount = fungible_asset::amount(&reward_fa);

        if (reward_amount > 0) {
            let lp = mock_deposit_to_dex(reward_fa, m_store.stake_token_metadata[pool_index]);
            let reward_lp = fungible_asset::amount(&lp);

            pool_router::add_stake(lp);

            m_store.stake_reward_amounts[pool_index] = m_store.stake_reward_amounts[pool_index] + reward_lp;
            m_store.staked_amounts[pool_index] = m_store.staked_amounts[pool_index] + reward_lp;
            return reward_lp;
        } else {
            fungible_asset::destroy_zero(reward_fa);
        };
        0
    }

    #[test_only]
    fun mock_deposit_to_dex(deposit_fa: FungibleAsset, lp_metadata: Object<Metadata>): FungibleAsset {
        let initial_signer = account::create_signer_for_test(@initia_std);
        let amount = fungible_asset::amount(&deposit_fa);
        primary_fungible_store::deposit(@initia_std, deposit_fa);
        primary_fungible_store::withdraw(&initial_signer, lp_metadata, amount)
    }

     // Mocks the unstaking process
    #[test_only]
    public fun mock_unstake(account: &signer, unstaking_type: u64, unstaking_amount: u64) acquires ModuleStore, CabalStore, LockExempt {
        let m_store = borrow_global<ModuleStore>(@staking_addr);
        let account_address = signer::address_of(account);

        // Check if we're dealing with xINIT or LP tokens
        let is_unstake_xinit = m_store.stake_token_metadata[unstaking_type] == m_store.x_init_metadata;
        //debug::print(&is_unstake_xinit);
        // Make sure the cabal store exists for the account
        ensure_cabal_store_exists(account);
        

        // call this first, burn after (reading lol)
        if (is_unstake_xinit) {
            process_xinit_unstake(&package::get_assets_store_signer(), account_address, unstaking_type, unstaking_amount);
        } else {
            mock_process_lp_unstake(&package::get_assets_store_signer(), account_address, unstaking_type, unstaking_amount);
        };

        // Call the regular unstake function first to handle the token burn
        initiate_unstake(account, unstaking_type, unstaking_amount);

        
    }

    #[test_only]
    fun mock_process_lp_unstake(account: &signer, staker_addr: address, unstaking_type: u64, unstake_amount: u64) acquires ModuleStore, CabalStore {
        let m_store = borrow_global_mut<ModuleStore>(@staking_addr);
        let extend_addr = package::get_assets_store_address();
        assert!(signer::address_of(account) == extend_addr, error::permission_denied(EUNAUTHORIZED));

        let reward_amount = mock_compound_lp_pool_rewards(m_store, unstaking_type);

        // calculate claim lp token amount
        let lp_amount = pool_router::get_total_stakes(m_store.stake_token_metadata[unstaking_type]);
        let cabal_lp_amount = option::extract(&mut fungible_asset::supply(m_store.cabal_stake_token_metadata[unstaking_type]));
        let ratio = bigdecimal::from_ratio_u128(unstake_amount as u128, cabal_lp_amount);
        let unbonding_amount = bigdecimal::mul_by_u64_truncate(ratio, lp_amount);

        m_store.staked_amounts[unstaking_type] = m_store.staked_amounts[unstaking_type] - unbonding_amount;
        // Changes rolled back
        // // skip lock period if user is in the whitelist
        // if (vector::contains(
        //     &borrow_global<LockExempt>(package::resource_account_address()).addresses,
        //     &staker_addr)
        // ) {
        //     primary_fungible_store::transfer(
        //         &package::get_assets_store_signer(),
        //         m_store.stake_token_metadata[unstaking_type],
        //         staker_addr,
        //         unbonding_amount
        //     )
        // } else {
        m_store.unstaked_pending_amounts[unstaking_type] = m_store.unstaked_pending_amounts[unstaking_type] + unbonding_amount;

        // deposit unbonding entry
        let (_, block_time) = block::get_block_info();
        let cabal_store = borrow_global_mut<CabalStore>(staker_addr);
        vector::push_back(&mut cabal_store.unbonding_entries, UnbondingEntry {
            pool_index: unstaking_type,
            metadata: m_store.stake_token_metadata[unstaking_type],
            amount: unbonding_amount,
            release_time: block_time + m_store.unbond_period[unstaking_type],
        });
        //}

    }
}
