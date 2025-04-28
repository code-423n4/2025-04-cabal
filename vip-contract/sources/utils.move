module vip::utils {
    use std::error;
    use std::option::{Self, Option};
    use std::signer;
    use std::string::String;
    use std::vector;

    use initia_std::address::to_sdk;
    use initia_std::coin;
    use initia_std::bigdecimal::{Self, BigDecimal};
    use initia_std::fungible_asset::Metadata;
    use initia_std::json::{marshal, unmarshal};
    use initia_std::object::Object;
    use initia_std::simple_map::{Self, SimpleMap};
    use initia_std::table::{Self, Table};
    use initia_std::query::query_stargate;

    const EUNAUTHORIZED: u64 = 1;

    public inline fun walk_mut<K: copy + drop, V>(
        mut_table: &mut Table<K, V>,
        start: Option<K>,
        end: Option<K>,
        order: u8,
        f: |K, &mut V| bool
    ) {
        let iter = table::iter_mut(mut_table, start, end, order);
        loop {
            if (!table::prepare_mut<K, V>(iter)) { break };
            let (key, value) = table::next_mut<K, V>(iter);
            let stop = f(key, value);
            if (stop) { break }
        }
    }

    public inline fun walk<K: copy + drop, V>(
        table: &Table<K, V>,
        start: Option<K>,
        end: Option<K>,
        order: u8,
        f: |K, &V| bool
    ) {
        let iter = table::iter(table, start, end, order);
        loop {
            if (!table::prepare<K, V>(iter)) { break };
            let (key, value) = table::next<K, V>(iter);
            let stop = f(key, value);
            if (stop) { break }
        }
    }

    public fun check_chain_permission(chain: &signer) {
        let addr = signer::address_of(chain);
        assert!(
            addr == @initia_std || addr == @vip,
            error::permission_denied(EUNAUTHORIZED)
        );
    }

    public fun mul_div_u64(a: u64, b: u64, c: u64): u64 {
        ((a as u128) * (b as u128) / (c as u128) as u64)
    }

    public fun mul_div_u128(a: u128, b: u128, c: u128): u128 {
        ((a as u256) * (b as u256) / (c as u256) as u128)
    }

    // stargate queries
    struct DelegatorDelegationsRequest has drop {
        delegator_addr: String,
        pagination: Option<PageRequest>
    }

    struct DelegatorDelegationsResponse has drop {
        delegation_responses: vector<DelegationResponse>,
        pagination: Option<PageResponse>
    }

    struct PoolRequest has drop {}

    struct PoolResponse has drop {
        pool: Pool
    }

    #[deprecated]
    // depreacated, use `get_customized_voting_power` instead
    public fun get_voting_power(delegator_addr: String): u64 {
        get_customized_voting_power(
            initia_std::address::from_sdk(delegator_addr),
            |_metadata, voting_power| { voting_power }
        )
    }

    public fun unpack_delegation_response(
        delegation_response: &DelegationResponse
    ): (Delegation, vector<Coin>) {
        (delegation_response.delegation, delegation_response.balance)
    }

    public fun unpack_coin(coin: &Coin): (String, u64) {
        (coin.denom, coin.amount)
    }

    public inline fun get_customized_voting_power(
        delegator_addr: address, f: |Object<Metadata>, u64| u64
    ): u64 {
        let delegator_addr = to_sdk(delegator_addr);
        let delegations = get_delegations(delegator_addr);

        // denom => voting power map
        let weight_map = get_weight_map();
        // denom => delegate amount map
        let delegate_amount_map = simple_map::new<String, u64>();
        // initialize
        vector::for_each_ref(
            &simple_map::keys(&weight_map),
            |denom| {
                simple_map::add(&mut delegate_amount_map, *denom, 0);
            }
        );

        // get total delegated amounts
        vector::for_each_ref(
            &delegations,
            |delegation| {
                let (_, balance) = unpack_delegation_response(delegation);
                vector::for_each_ref(
                    &balance,
                    |coin| {
                        let (denom, amount) = unpack_coin(coin);
                        let amount_before =
                            simple_map::borrow_mut(&mut delegate_amount_map, &denom);
                        *amount_before = *amount_before + amount;
                    }
                );
            }
        );

        // get total voting power
        let total_voting_power = 0;
        vector::for_each_ref(
            &simple_map::keys(&weight_map),
            |denom| {
                let metadata = coin::denom_to_metadata(*denom);
                let amount = *simple_map::borrow(&delegate_amount_map, denom);
                let weight = simple_map::borrow(&weight_map, denom);
                let voting_power = bigdecimal::mul_by_u64_truncate(*weight, amount);
                total_voting_power = total_voting_power + f(metadata, voting_power);
            }
        );

        total_voting_power
    }

    public fun get_weight_map(): SimpleMap<String, BigDecimal> {
        let PoolResponse { pool } = get_pool();
        let weight_map = simple_map::new<String, BigDecimal>();
        vector::for_each_ref(
            &pool.voting_power_weights,
            |weight| {
                let DecCoin { denom, amount } = *weight;
                simple_map::add(&mut weight_map, denom, amount);
            }
        );
        weight_map
    }

    public fun get_delegations(delegator_addr: String): vector<DelegationResponse> {
        let delegation_responses: vector<DelegationResponse> = vector[];
        let pagination = PageRequest {
            key: option::none(),
            offset: option::none(),
            limit: option::none(),
            count_total: option::none(),
            reverse: option::none()
        };

        let path = b"/initia.mstaking.v1.Query/DelegatorDelegations";

        loop {
            let request = DelegatorDelegationsRequest {
                delegator_addr,
                pagination: option::some(pagination)
            };
            let response =
                query<DelegatorDelegationsRequest, DelegatorDelegationsResponse>(
                    path, request
                );
            vector::append(
                &mut delegation_responses,
                response.delegation_responses
            );

            if (option::is_none(&response.pagination)) { break };

            let pagination_res = option::borrow(&response.pagination);

            if (option::is_none(&pagination_res.next_key)) { break };

            pagination.key = pagination_res.next_key;
        };

        delegation_responses
    }

    fun get_pool(): PoolResponse {
        let path = b"/initia.mstaking.v1.Query/Pool";
        query<PoolRequest, PoolResponse>(path, PoolRequest {})
    }

    fun query<Request: drop, Response: drop>(
        path: vector<u8>, data: Request
    ): Response {
        let response = query_stargate(path, marshal(&data));
        unmarshal<Response>(response)
    }

    // cosmos types
    struct Pool has drop {
        not_bonded_tokens: vector<Coin>,
        bonded_tokens: vector<Coin>,
        voting_power_weights: vector<DecCoin>
    }

    struct PageRequest has copy, drop {
        key: Option<String>,
        offset: Option<u64>,
        limit: Option<u64>,
        count_total: Option<bool>,
        reverse: Option<bool>
    }

    struct PageResponse has drop {
        next_key: Option<String>,
        total: Option<u64>
    }

    struct DelegationResponse has copy, drop {
        delegation: Delegation,
        balance: vector<Coin>
    }

    struct Delegation has copy, drop {
        delegator_address: String,
        validator_address: String,
        shares: vector<DecCoin>
    }

    struct Coin has copy, drop {
        denom: String,
        amount: u64
    }

    struct DecCoin has copy, drop {
        denom: String,
        amount: BigDecimal
    }

    #[test_only]
    use initia_std::block;

    #[test_only]
    public fun increase_block(height_diff: u64, time_diff: u64) {
        let (curr_height, curr_time) = block::get_block_info();
        block::set_block_info(curr_height + height_diff, curr_time + time_diff);
    }
}
