module staking_addr::utils {

    use std::string;
    use initia_std::bigdecimal;
    use initia_std::bigdecimal::BigDecimal;

    use initia_std::coin;
    use initia_std::fungible_asset::Metadata;
    use initia_std::json::{marshal, unmarshal};
    use initia_std::math64;
    use initia_std::object::Object;
    use initia_std::oracle;
    use initia_std::query::query_stargate;

    #[test_only]
    use std::string::String;
    #[test_only]
    use initia_std::block;
    #[test_only]
    use initia_std::coin::{BurnCapability, FreezeCapability, MintCapability};

    public fun query<Request: drop, Response: drop>(
        path: vector<u8>, data: Request
    ): Response {
        let response = query_stargate(path, marshal(&data));
        unmarshal<Response>(response)
    }

    public fun get_init_metadata(): Object<Metadata> {
        coin::metadata(@initia_std, string::utf8(b"uinit"))
    }

    // helper function to get the value of a token relative to usd using the Oracle
    public fun get_token_value_in_usd(coin_metadata: Object<Metadata>, amount: u64): BigDecimal {
        let price = get_token_price_in_usd(coin_metadata);
        let coin_decimals = coin::decimals(coin_metadata);
        let amount_f = bigdecimal::from_ratio_u64(amount, math64::pow(10, coin_decimals as u64));
        bigdecimal::mul(price, amount_f)
    }

    // helper function to get the price of a token relative to usd using the Oracle
    public fun get_token_price_in_usd(coin_metadata: Object<Metadata>): BigDecimal {
        let pair = coin::symbol(coin_metadata);
        string::append_utf8(&mut pair, b"/usd");
        let (price, _, decimals) = oracle::get_price(pair);
        bigdecimal::from_ratio_u256(price, math64::pow(10, decimals) as u256)
    }

    #[test_only]
    public fun increase_block(height_diff: u64, time_diff: u64) {
        let (curr_height, curr_time) = block::get_block_info();
        block::set_block_info(curr_height + height_diff, curr_time + time_diff);
    }

    #[test_only]
    public fun initialize_coin_for_testing(
        account: &signer, symbol: String
    ): (BurnCapability, FreezeCapability, MintCapability) {
        let (mint_cap, burn_cap, freeze_cap, _) =
            coin::initialize_and_generate_extend_ref(
                account,
                std::option::none(),
                string::utf8(b""),
                symbol,
                6,
                string::utf8(b""),
                string::utf8(b"")
            );

        return (burn_cap, freeze_cap, mint_cap)
    }

    #[test_only]
    public fun test_with_slack(value: u64, target: u64, slack_bps: u64){
        assert!(value * 1000 <= target * (1000 + slack_bps), 10001);
        assert!(value * 1000 >= target * (1000 - slack_bps), 10002);
    }
}