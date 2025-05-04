#[test_only]
module sui_dex::router_test {
    use sui::test_scenario::{Self as ts, next_tx, Scenario};
    use sui::test_utils;
    use sui::coin::{Self, CoinMetadata};
    use sui::clock;
    use std::debug;
    use sui_dex::router;
    use sui_dex::gauge::{Self, Gauge};
    use sui_dex::liquidity_pool::{Self, LiquidityPoolConfigs, LiquidityPool, FeesAccounting, WhitelistedLPers};
    use sui_dex::coin_wrapper::{Self, WrapperStore, WrapperStoreCap, COIN_WRAPPER};
    use sui_dex::vote_manager::{Self, AdministrativeData};
    use sui_dex::token_whitelist::{Self, RewardTokenWhitelistPerPool, TokenWhitelistAdminCap};
    use sui_dex::sui::{Self, SUI};
    use sui_dex::usdt::{Self, USDT};

    const OWNER: address = @0xab;

    fun setup(scenario: &mut Scenario) {
        // Initialize all modules
        sui::init_for_testing_sui(ts::ctx(scenario));
        usdt::init_for_testing_usdt(ts::ctx(scenario));
        liquidity_pool::init_for_testing(ts::ctx(scenario));
        coin_wrapper::init_for_testing(ts::ctx(scenario));
        vote_manager::init_for_testing(ts::ctx(scenario));
        token_whitelist::init_for_testing(ts::ctx(scenario));
        next_tx(scenario, OWNER);
        let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
        let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);
        ts::return_immutable(base_metadata);
        ts::return_immutable(quote_metadata);
    }

    #[test]
    fun test_add_liquidity_and_stake_entry() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        setup(scenario);
        let clock = clock::create_for_testing(ts::ctx(scenario));

        next_tx(scenario, OWNER);
        let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
        let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);
        let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
        let mut store = ts::take_shared<WrapperStore>(scenario);
        let cap = ts::take_from_sender<WrapperStoreCap>(scenario);
        let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
        coin_wrapper::register_coin_for_testing<USDT>(
            &cap,
            &mut store,
            ts::ctx(scenario)
        );
        coin_wrapper::register_coin_for_testing<SUI>(
            &cap,
            &mut store,
            ts::ctx(scenario)
        );

        liquidity_pool::create<USDT, SUI>(
            &quote_metadata,
            &base_metadata,
            &mut configs,
            false,
            ts::ctx(scenario)
        );

        next_tx(scenario, OWNER);

        vote_manager::create_gauge<USDT, SUI>(
            &mut admin_data,
            &mut configs,
            &quote_metadata,
            &base_metadata,
            false,
            ts::ctx(scenario)
        );

        next_tx(scenario, OWNER);
        {
            let mut gauge = ts::take_shared<Gauge<USDT, SUI>>(scenario);
            let mut fees_accounting = ts::take_shared<FeesAccounting>(scenario);
            let mut whitelist = ts::take_shared<WhitelistedLPers>(scenario);
            let amount = 100000;
            let base_coin = coin::mint_for_testing<SUI>(amount, ts::ctx(scenario));
            let quote_coin = coin::mint_for_testing<USDT>(amount, ts::ctx(scenario));
            let base_wrapped_coin = coin_wrapper::wrap<SUI>(&mut store, base_coin, ts::ctx(scenario));
            let quote_wrapped_coin = coin_wrapper::wrap<USDT>(&mut store, quote_coin, ts::ctx(scenario));
            router::add_liquidity_and_stake_entry<USDT, SUI>(
                &mut gauge,
                &whitelist,
                &quote_metadata,
                &base_metadata,
                false,
                amount,
                amount,
                &mut store,
                &mut fees_accounting,
                &clock,
                ts::ctx(scenario)
            );

            transfer::public_transfer(base_wrapped_coin, @0xcafe);
            transfer::public_transfer(quote_wrapped_coin, @0xcafe);
            ts::return_shared(whitelist);
            ts::return_shared(fees_accounting);
            ts::return_shared(gauge);
        };

        let all_pools = liquidity_pool::all_pool_ids(&configs);
        assert!(vector::length(&all_pools) == 1, 0);

        ts::return_immutable(base_metadata);
        ts::return_immutable(quote_metadata);
        ts::return_shared(configs);
        ts::return_shared(store);
        ts::return_to_sender(scenario, cap);
        ts::return_shared(admin_data);
        clock.destroy_for_testing();
        ts::end(scenario_val);
    }

    #[test]
    fun test_add_liquidity_and_stake_both_coins_entry() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        setup(scenario);
        let clock = clock::create_for_testing(ts::ctx(scenario));

        next_tx(scenario, OWNER);
        let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
        let mut store = ts::take_shared<WrapperStore>(scenario);
        let cap = ts::take_from_sender<WrapperStoreCap>(scenario);
        let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
        coin_wrapper::register_coin_for_testing<USDT>(
            &cap,
            &mut store,
            ts::ctx(scenario)
        );
        coin_wrapper::register_coin_for_testing<SUI>(
            &cap,
            &mut store,
            ts::ctx(scenario)
        );
        let base_metadata = coin_wrapper::get_wrapper<SUI>(&store);
        let quote_metadata = coin_wrapper::get_wrapper<USDT>(&store);

        liquidity_pool::create<COIN_WRAPPER, COIN_WRAPPER>(
            quote_metadata,
            base_metadata,
            &mut configs,
            false,
            ts::ctx(scenario)
        );

        next_tx(scenario, OWNER);
        vote_manager::create_gauge<COIN_WRAPPER, COIN_WRAPPER>(
            &mut admin_data,
            &mut configs,
            quote_metadata,
            base_metadata,
            false,
            ts::ctx(scenario)
        );

        next_tx(scenario, OWNER);
        {
            let mut gauge = ts::take_shared<Gauge<COIN_WRAPPER, COIN_WRAPPER>>(scenario);
            let mut fees_accounting = ts::take_shared<FeesAccounting>(scenario);
            let amount = 100000;
            let mut base_coin = coin::mint_for_testing<SUI>(amount, ts::ctx(scenario));
            let mut quote_coin = coin::mint_for_testing<USDT>(amount, ts::ctx(scenario));
            
            let pool = gauge::liquidity_pool(&mut gauge);
            let base_metadata1 = coin_wrapper::get_wrapper<SUI>(&store);
            let quote_metadata1 = coin_wrapper::get_wrapper<USDT>(&store);
            let (optimal_a, optimal_b) = router::get_optimal_amounts_for_testing<COIN_WRAPPER, COIN_WRAPPER>(
                pool,
                quote_metadata1,
                base_metadata1,
                amount,
                amount
            );

            let new_base_coin = coin::split(&mut base_coin, optimal_a, ts::ctx(scenario));
            let new_quote_coin = coin::split(&mut quote_coin, optimal_b, ts::ctx(scenario));
            let base_coin_opt = coin_wrapper::wrap<SUI>(&mut store, new_base_coin, ts::ctx(scenario));
            let quote_coin_opt = coin_wrapper::wrap<USDT>(&mut store, new_quote_coin, ts::ctx(scenario));
            assert!(coin::value(&base_coin_opt) == optimal_a, 2);
            assert!(coin::value(&quote_coin_opt) == optimal_b, 3);
            let base_metadata2 = coin_wrapper::get_wrapper<SUI>(&store);
            let quote_metadata2 = coin_wrapper::get_wrapper<USDT>(&store);
            let whitelist = ts::take_shared<WhitelistedLPers>(scenario);
            gauge::stake(
                &mut gauge,
                liquidity_pool::mint_lp(
                    pool, 
                    &mut fees_accounting, 
                    &whitelist,
                    quote_metadata2,
                    base_metadata2,
                    base_coin_opt,
                    quote_coin_opt,
                    false,
                    ts::ctx(scenario)
                ),
                ts::ctx(scenario),
                &clock
            );
                
            transfer::public_transfer(base_coin, @0xcafe);
            transfer::public_transfer(quote_coin, @0xcafe);
            ts::return_shared(fees_accounting);
            ts::return_shared(gauge);
            ts::return_shared(whitelist);
        };

        let all_pools = liquidity_pool::all_pool_ids(&configs);
        assert!(vector::length(&all_pools) == 1, 0);

        ts::return_shared(configs);
        ts::return_shared(store);
        ts::return_to_sender(scenario, cap);
        ts::return_shared(admin_data);
        clock.destroy_for_testing();
        ts::end(scenario_val);
    }

    #[test]
    fun test_add_liquidity_and_stake_coin_entry() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        setup(scenario);
        let clock = clock::create_for_testing(ts::ctx(scenario));

        next_tx(scenario, OWNER);
        let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
        let mut store = ts::take_shared<WrapperStore>(scenario);
        let cap = ts::take_from_sender<WrapperStoreCap>(scenario);
        let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
        coin_wrapper::register_coin_for_testing<USDT>(
            &cap,
            &mut store,
            ts::ctx(scenario)
        );
        coin_wrapper::register_coin_for_testing<SUI>(
            &cap,
            &mut store,
            ts::ctx(scenario)
        );
        let base_metadata = coin_wrapper::get_wrapper<SUI>(&store);
        let quote_metadata = coin_wrapper::get_wrapper<USDT>(&store);

        liquidity_pool::create<COIN_WRAPPER, COIN_WRAPPER>(
            quote_metadata,
            base_metadata,
            &mut configs,
            false,
            ts::ctx(scenario)
        );

        next_tx(scenario, OWNER);
        vote_manager::create_gauge<COIN_WRAPPER, COIN_WRAPPER>(
            &mut admin_data,
            &mut configs,
            quote_metadata,
            base_metadata,
            false,
            ts::ctx(scenario)
        );

        next_tx(scenario, OWNER);
        {
            let mut gauge = ts::take_shared<Gauge<COIN_WRAPPER, COIN_WRAPPER>>(scenario);
            let mut fees_accounting = ts::take_shared<FeesAccounting>(scenario);
            let amount = 100000;
            let mut base_coin = coin::mint_for_testing<SUI>(amount, ts::ctx(scenario));
            let mut quote_coin = coin::mint_for_testing<USDT>(amount, ts::ctx(scenario));
            
            let pool = gauge::liquidity_pool(&mut gauge);
            let base_metadata1 = coin_wrapper::get_wrapper<SUI>(&store);
            let quote_metadata1 = coin_wrapper::get_wrapper<USDT>(&store);
            let (optimal_a, optimal_b) = router::get_optimal_amounts_for_testing<COIN_WRAPPER, COIN_WRAPPER>(
                pool,
                quote_metadata1,
                base_metadata1,
                amount,
                amount
            );

            let new_base_coin = coin::split(&mut base_coin, optimal_a, ts::ctx(scenario));
            let new_quote_coin = coin::split(&mut quote_coin, optimal_b, ts::ctx(scenario));
            let base_coin_opt = coin_wrapper::wrap<SUI>(&mut store, new_base_coin, ts::ctx(scenario));
            let quote_coin_opt = coin_wrapper::wrap<USDT>(&mut store, new_quote_coin, ts::ctx(scenario));
            assert!(coin::value(&base_coin_opt) == optimal_a, 2);
            assert!(coin::value(&quote_coin_opt) == optimal_b, 3);
            let base_metadata2 = coin_wrapper::get_wrapper<SUI>(&store);
            let quote_metadata2 = coin_wrapper::get_wrapper<USDT>(&store);
            let whitelist = ts::take_shared<WhitelistedLPers>(scenario);
            gauge::stake(
                &mut gauge,
                liquidity_pool::mint_lp(
                    pool, 
                    &mut fees_accounting, 
                    &whitelist,
                    quote_metadata2,
                    base_metadata2,
                    base_coin_opt,
                    quote_coin_opt,
                    false,
                    ts::ctx(scenario)
                ),
                ts::ctx(scenario),
                &clock
            );
                
            transfer::public_transfer(base_coin, @0xcafe);
            transfer::public_transfer(quote_coin, @0xcafe);
            ts::return_shared(whitelist);
            ts::return_shared(fees_accounting);
            ts::return_shared(gauge);
        };

        let all_pools = liquidity_pool::all_pool_ids(&configs);
        assert!(vector::length(&all_pools) == 1, 0);

        ts::return_shared(configs);
        ts::return_shared(store);
        ts::return_to_sender(scenario, cap);
        ts::return_shared(admin_data);
        clock.destroy_for_testing();
        ts::end(scenario_val);
    }

    #[test]
    fun test_swap_coin_for_coin_entry() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        setup(scenario);
        let clock = clock::create_for_testing(ts::ctx(scenario));

        next_tx(scenario, OWNER);
        let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
        let mut store = ts::take_shared<WrapperStore>(scenario);
        let cap = ts::take_from_sender<WrapperStoreCap>(scenario);
        let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
        coin_wrapper::register_coin_for_testing<USDT>(
            &cap,
            &mut store,
            ts::ctx(scenario)
        );
        coin_wrapper::register_coin_for_testing<SUI>(
            &cap,
            &mut store,
            ts::ctx(scenario)
        );
        let amount = 100000;
        let base_coin = coin::mint_for_testing<SUI>(amount, ts::ctx(scenario));
        let quote_coin = coin::mint_for_testing<USDT>(amount, ts::ctx(scenario));
        let base_wrapped_coin = coin_wrapper::wrap<SUI>(&mut store, base_coin, ts::ctx(scenario));
        let quote_wrapped_coin = coin_wrapper::wrap<USDT>(&mut store, quote_coin, ts::ctx(scenario));
        let base_metadata = coin_wrapper::get_wrapper<SUI>(&store);
        let quote_metadata = coin_wrapper::get_wrapper<USDT>(&store);
        
        next_tx(scenario, OWNER);
        
        liquidity_pool::create<COIN_WRAPPER, COIN_WRAPPER>(
            quote_metadata, 
            base_metadata, 
            &mut configs, 
            false,
            ts::ctx(scenario)
        );

        next_tx(scenario, OWNER);
        {
            // let mut gauge = ts::take_shared<Gauge<COIN_WRAPPER, COIN_WRAPPER>>(scenario);
            let mut fees_accounting = ts::take_shared<FeesAccounting>(scenario);
            let pool = liquidity_pool::liquidity_pool_mut(
                &mut configs,
                quote_metadata,
                base_metadata,
                false
            );
            let whitelist = ts::take_shared<WhitelistedLPers>(scenario);
            liquidity_pool::mint_lp(
                pool,
                &mut fees_accounting,
                &whitelist,
                quote_metadata,
                base_metadata,
                base_wrapped_coin,
                quote_wrapped_coin,
                false,
                ts::ctx(scenario)
            );
            let quote_coin_copy = coin_wrapper::unwrap_for_testing<USDT>(&mut store);
            let quote_wrapped_coin_copy = coin_wrapper::wrap<USDT>(&mut store, quote_coin_copy, ts::ctx(scenario));
            let recipient = @0x1234;
            let base_metadata_copy = coin_wrapper::get_wrapper<SUI>(&store);
            let quote_metadata_copy = coin_wrapper::get_wrapper<USDT>(&store);
            let deposited_coin = router::swap_coin_for_coin(
                quote_wrapped_coin_copy,
                10000,
                &mut configs,
                &mut fees_accounting,
                quote_metadata_copy,
                base_metadata_copy,
                false,
                ts::ctx(scenario)
            );
            assert!(coin::value(&deposited_coin) >= 10000, 2);
            router::exact_deposit(recipient, deposited_coin);
            ts::return_shared(fees_accounting);
            ts::return_shared(whitelist);
            // ts::return_shared(gauge);
        };

        let all_pools = liquidity_pool::all_pool_ids(&configs);
        assert!(vector::length(&all_pools) == 1, 0);

        ts::return_shared(configs);
        ts::return_shared(store);
        ts::return_to_sender(scenario, cap);
        ts::return_shared(admin_data);
        clock.destroy_for_testing();
        ts::end(scenario_val);
    }

    #[test]
    fun test_swap_entry() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        setup(scenario);
        let clock = clock::create_for_testing(ts::ctx(scenario));

        next_tx(scenario, OWNER);
        let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
        let mut store = ts::take_shared<WrapperStore>(scenario);
        let cap = ts::take_from_sender<WrapperStoreCap>(scenario);
        let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
        coin_wrapper::register_coin_for_testing<USDT>(
            &cap,
            &mut store,
            ts::ctx(scenario)
        );
        coin_wrapper::register_coin_for_testing<SUI>(
            &cap,
            &mut store,
            ts::ctx(scenario)
        );
        let amount = 100000;
        let base_coin = coin::mint_for_testing<SUI>(amount, ts::ctx(scenario));
        let quote_coin = coin::mint_for_testing<USDT>(amount, ts::ctx(scenario));
        let base_wrapped_coin = coin_wrapper::wrap<SUI>(&mut store, base_coin, ts::ctx(scenario));
        let quote_wrapped_coin = coin_wrapper::wrap<USDT>(&mut store, quote_coin, ts::ctx(scenario));
        let base_metadata = coin_wrapper::get_wrapper<SUI>(&store);
        let quote_metadata = coin_wrapper::get_wrapper<USDT>(&store);
        
        next_tx(scenario, OWNER);
        
        let pool_id = liquidity_pool::create<COIN_WRAPPER, COIN_WRAPPER>(
            quote_metadata, 
            base_metadata, 
            &mut configs, 
            false,
            ts::ctx(scenario)
        );
        let pool = liquidity_pool::liquidity_pool_mut(
            &mut configs,
            quote_metadata,
            base_metadata,
            false
        );

        next_tx(scenario, OWNER);
        {
            let mut fees_accounting = ts::take_shared<FeesAccounting>(scenario);
            let whitelist = ts::take_shared<WhitelistedLPers>(scenario);
            liquidity_pool::mint_lp(
                pool,
                &mut fees_accounting,
                &whitelist,
                quote_metadata,
                base_metadata,
                quote_wrapped_coin,
                base_wrapped_coin,
                false,
                ts::ctx(scenario)
            );
            let recipient = @0x1234;
            let quote_new_coin = coin_wrapper::unwrap_for_testing<USDT>(
                &mut store
            );

            let mut quote_new_wrapped_coin = coin_wrapper::wrap<USDT>(
                &mut store,
                quote_new_coin,
                ts::ctx(scenario)
            );

            let new_quote_wrapped_coin = coin::split(
                &mut quote_new_wrapped_coin,
                10000,
                ts::ctx(scenario)
            );

            let base_metadata_copy = coin_wrapper::get_wrapper<SUI>(&store);
            let quote_metadata_copy = coin_wrapper::get_wrapper<USDT>(&store);
            let deposited_coin = router::swap(
                new_quote_wrapped_coin,
                1000,
                &mut configs,
                &mut fees_accounting,
                quote_metadata_copy,
                base_metadata_copy,
                false,
                ts::ctx(scenario)
            );
            assert!(coin::value(&deposited_coin) >= 1000, 2);
            router::exact_deposit(
                recipient, 
                deposited_coin
            );
            ts::return_shared(fees_accounting);
            ts::return_shared(whitelist);
            transfer::public_transfer(quote_new_wrapped_coin, @0xcafe);
        };

        let all_pools = liquidity_pool::all_pool_ids(&configs);
        assert!(vector::length(&all_pools) == 1, 0);
        assert!(vector::contains(&all_pools, &pool_id), 1);

        ts::return_shared(configs);
        ts::return_shared(store);
        ts::return_to_sender(scenario, cap);
        ts::return_shared(admin_data);
        clock.destroy_for_testing();
        ts::end(scenario_val);
    }

    #[test]
    fun test_swap_route_entry() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        setup(scenario);
        let clock = clock::create_for_testing(ts::ctx(scenario));

        next_tx(scenario, OWNER);
        let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
        let mut store = ts::take_shared<WrapperStore>(scenario);
        let cap = ts::take_from_sender<WrapperStoreCap>(scenario);
        let admin_data = ts::take_shared<AdministrativeData>(scenario);
        coin_wrapper::register_coin_for_testing<USDT>(
            &cap,
            &mut store,
            ts::ctx(scenario)
        );
        coin_wrapper::register_coin_for_testing<SUI>(
            &cap,
            &mut store,
            ts::ctx(scenario)
        );
        let amount = 100000;
        // let base_coin = coin::mint_for_testing<SUI>(amount, ts::ctx(scenario));
        // let quote_coin = coin::mint_for_testing<USDT>(amount, ts::ctx(scenario));
        // let base_wrapped_coin = coin_wrapper::wrap<SUI>(&mut store, base_coin, ts::ctx(scenario));
        // let quote_wrapped_coin = coin_wrapper::wrap<USDT>(&mut store, quote_coin, ts::ctx(scenario));
        let base_metadata = coin_wrapper::get_wrapper<SUI>(&store);
        let quote_metadata = coin_wrapper::get_wrapper<USDT>(&store);
        
        next_tx(scenario, OWNER);
        
        let pool_id = liquidity_pool::create<COIN_WRAPPER, COIN_WRAPPER>(
            quote_metadata, 
            base_metadata, 
            &mut configs, 
            false,
            ts::ctx(scenario)
        );

        let pool = liquidity_pool::liquidity_pool_mut(
            &mut configs,
            quote_metadata,
            base_metadata,
            false
        );

        // next_tx(scenario, OWNER);
        // {
        //     let mut fees_accounting = ts::take_shared<FeesAccounting>(scenario);
        //     liquidity_pool::mint_lp(
        //         pool,
        //         &mut fees_accounting,
        //         quote_metadata,
        //         base_metadata,
        //         quote_wrapped_coin,
        //         base_wrapped_coin,
        //         false,
        //         ts::ctx(scenario)
        //     );
        //     let recipient = @0x1234;
        //     let quote_new_coin = coin_wrapper::unwrap_for_testing<USDT>(
        //         &mut store
        //     );

        //     let mut quote_new_wrapped_coin = coin_wrapper::wrap<USDT>(
        //         &mut store,
        //         quote_new_coin,
        //         ts::ctx(scenario)
        //     );

        //     let new_quote_wrapped_coin = coin::split(
        //         &mut quote_new_wrapped_coin,
        //         10000,
        //         ts::ctx(scenario)
        //     );
        //     let base_metadata_copy = coin_wrapper::get_wrapper<SUI>(&store);
        //     let quote_metadata_copy = coin_wrapper::get_wrapper<USDT>(&store);
        //     let deposited_coin = router::swap(
        //         new_quote_wrapped_coin,
        //         1000,
        //         &mut configs,
        //         &mut fees_accounting,
        //         quote_metadata_copy,
        //         base_metadata_copy,
        //         false,
        //         ts::ctx(scenario)
        //     );
        //     assert!(coin::value(&deposited_coin) >= 1000, 2);
        //     router::exact_deposit(
        //         recipient, 
        //         deposited_coin
        //     );
        //     ts::return_shared(fees_accounting);
        //     transfer::public_transfer(quote_new_wrapped_coin, @0xcafe);
        // };

        let all_pools = liquidity_pool::all_pool_ids(&configs);
        assert!(vector::length(&all_pools) == 1, 0);
        assert!(vector::contains(&all_pools, &pool_id), 1);

        ts::return_shared(configs);
        ts::return_shared(store);
        ts::return_to_sender(scenario, cap);
        ts::return_shared(admin_data);
        clock.destroy_for_testing();
        ts::end(scenario_val);
    }

    #[test]
    fun test_create_pool() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        setup(scenario);
        let clock = clock::create_for_testing(ts::ctx(scenario));

        next_tx(scenario, OWNER);
        let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
        let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
        let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);
        let mut store = ts::take_shared<WrapperStore>(scenario);
        let cap = ts::take_from_sender<WrapperStoreCap>(scenario);
        let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
        let admin_cap = ts::take_from_sender<TokenWhitelistAdminCap>(scenario);
        let mut pool_whitelist = ts::take_shared<RewardTokenWhitelistPerPool>(scenario);
        coin_wrapper::register_coin_for_testing<USDT>(
            &cap,
            &mut store,
            ts::ctx(scenario)
        );
        coin_wrapper::register_coin_for_testing<SUI>(
            &cap,
            &mut store,
            ts::ctx(scenario)
        );

        next_tx(scenario, OWNER);
        
        router::create_pool(
            &mut admin_data,
            &quote_metadata,
            &base_metadata,
            &mut configs,
            &admin_cap,
            &mut pool_whitelist,
            &store,
            false,
            ts::ctx(scenario)
        );

        next_tx(scenario, OWNER);
        let all_pools = liquidity_pool::all_pool_ids(&configs);
        assert!(vector::length(&all_pools) == 1, 0);
        assert!(
            token_whitelist::whitelist_length(
                &pool_whitelist, 
                object::id_to_address(vector::borrow(&all_pools, 0))
            ) == 1, 3
        );

        ts::return_shared(configs);
        ts::return_immutable(base_metadata);
        ts::return_immutable(quote_metadata);
        ts::return_shared(store);
        ts::return_to_sender(scenario, cap);
        ts::return_to_sender(scenario, admin_cap);
        ts::return_shared(admin_data);
        ts::return_shared(pool_whitelist);
        clock.destroy_for_testing();
        ts::end(scenario_val);
    }

    #[test]
    fun test_create_pool_both_coins() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        setup(scenario);
        let clock = clock::create_for_testing(ts::ctx(scenario));

        next_tx(scenario, OWNER);
        let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
        let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
        let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);
        let mut store = ts::take_shared<WrapperStore>(scenario);
        let cap = ts::take_from_sender<WrapperStoreCap>(scenario);
        let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
        let admin_cap = ts::take_from_sender<TokenWhitelistAdminCap>(scenario);
        let mut pool_whitelist = ts::take_shared<RewardTokenWhitelistPerPool>(scenario);
        coin_wrapper::register_coin_for_testing<USDT>(
            &cap,
            &mut store,
            ts::ctx(scenario)
        );
        coin_wrapper::register_coin_for_testing<SUI>(
            &cap,
            &mut store,
            ts::ctx(scenario)
        );

        next_tx(scenario, OWNER);
        
        router::create_pool_both_coins<USDT, SUI>(
            &mut admin_data,
            &mut configs,
            &admin_cap,
            &mut pool_whitelist,
            &store,
            false,
            ts::ctx(scenario)
        );
        
        next_tx(scenario, OWNER);
        let all_pools = liquidity_pool::all_pool_ids(&configs);
        assert!(vector::length(&all_pools) == 1, 0);
        assert!(
            token_whitelist::whitelist_length(
                &pool_whitelist, 
                object::id_to_address(vector::borrow(&all_pools, 0))
            ) == 3, 1
        );

        ts::return_shared(configs);
        ts::return_immutable(base_metadata);
        ts::return_immutable(quote_metadata);
        ts::return_shared(store);
        ts::return_to_sender(scenario, cap);
        ts::return_to_sender(scenario, admin_cap);
        ts::return_shared(admin_data);
        ts::return_shared(pool_whitelist);
        clock.destroy_for_testing();
        ts::end(scenario_val);
    }

     #[test]
    fun test_create_pool_coin() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        setup(scenario);
        let clock = clock::create_for_testing(ts::ctx(scenario));

        next_tx(scenario, OWNER);
        let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
        let mut store = ts::take_shared<WrapperStore>(scenario);
        let cap = ts::take_from_sender<WrapperStoreCap>(scenario);
        let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
        let admin_cap = ts::take_from_sender<TokenWhitelistAdminCap>(scenario);
        let mut pool_whitelist = ts::take_shared<RewardTokenWhitelistPerPool>(scenario);
        coin_wrapper::register_coin_for_testing<USDT>(
            &cap,
            &mut store,
            ts::ctx(scenario)
        );
        coin_wrapper::register_coin_for_testing<SUI>(
            &cap,
            &mut store,
            ts::ctx(scenario)
        );
        let base_metadata = coin_wrapper::get_wrapper<SUI>(&store);
        let quote_metadata = coin_wrapper::get_wrapper<USDT>(&store);

        next_tx(scenario, OWNER);
        
        router::create_pool_coin<SUI>(
            &mut admin_data,
            &mut configs,
            quote_metadata,
            &admin_cap,
            &mut pool_whitelist,
            &store,
            false,
            ts::ctx(scenario)
        );
        
        next_tx(scenario, OWNER);
        let all_pools = liquidity_pool::all_pool_ids(&configs);
        assert!(vector::length(&all_pools) == 1, 0);
        assert!(
            token_whitelist::whitelist_length(
                &pool_whitelist, 
                object::id_to_address(vector::borrow(&all_pools, 0))
            ) == 3, 1
        );

        ts::return_shared(configs);
        ts::return_shared(store);
        ts::return_to_sender(scenario, cap);
        ts::return_to_sender(scenario, admin_cap);
        ts::return_shared(admin_data);
        ts::return_shared(pool_whitelist);
        clock.destroy_for_testing();
        ts::end(scenario_val);
    }

    #[test]
    fun test_unstake_and_remove_liquidity_both_coins_entry() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        setup(scenario);
        let clock = clock::create_for_testing(ts::ctx(scenario));

        next_tx(scenario, OWNER);
        let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
        let mut store = ts::take_shared<WrapperStore>(scenario);
        let cap = ts::take_from_sender<WrapperStoreCap>(scenario);
        let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
        coin_wrapper::register_coin_for_testing<USDT>(
            &cap,
            &mut store,
            ts::ctx(scenario)
        );
        coin_wrapper::register_coin_for_testing<SUI>(
            &cap,
            &mut store,
            ts::ctx(scenario)
        );
        let base_metadata = coin_wrapper::get_wrapper<SUI>(&store);
        let quote_metadata = coin_wrapper::get_wrapper<USDT>(&store);
        next_tx(scenario, OWNER);
        
        liquidity_pool::create<COIN_WRAPPER, COIN_WRAPPER>(
            quote_metadata,
            base_metadata,
            &mut configs,
            false,
            ts::ctx(scenario)
        );

        vote_manager::create_gauge<COIN_WRAPPER, COIN_WRAPPER>(
            &mut admin_data,
            &mut configs,
            quote_metadata,
            base_metadata,
            false,
            ts::ctx(scenario)
        );

        next_tx(scenario, OWNER);
        {
            let mut fees_accounting = ts::take_shared<FeesAccounting>(scenario);
            let mut gauge = ts::take_shared<Gauge<COIN_WRAPPER, COIN_WRAPPER>>(scenario);
            let pool = gauge::liquidity_pool(&mut gauge);
            let amount = 100000;
            let mut base_coin = coin::mint_for_testing<SUI>(amount, ts::ctx(scenario));
            let mut quote_coin = coin::mint_for_testing<USDT>(amount, ts::ctx(scenario));
          
            let base_metadata1 = coin_wrapper::get_wrapper<SUI>(&store);
            let quote_metadata1 = coin_wrapper::get_wrapper<USDT>(&store);
            let (optimal_a, optimal_b) = router::get_optimal_amounts_for_testing<COIN_WRAPPER, COIN_WRAPPER>(
                pool,
                quote_metadata1,
                base_metadata1,
                100000,
                100000
            );

            let new_base_coin = coin::split(&mut base_coin, optimal_a, ts::ctx(scenario));
            let new_quote_coin = coin::split(&mut quote_coin, optimal_b, ts::ctx(scenario));
            let base_coin_opt = coin_wrapper::wrap<SUI>(&mut store, new_base_coin, ts::ctx(scenario));
            let quote_coin_opt = coin_wrapper::wrap<USDT>(&mut store, new_quote_coin, ts::ctx(scenario));
            assert!(coin::value(&base_coin_opt) == optimal_a, 2);
            assert!(coin::value(&quote_coin_opt) == optimal_b, 3);
            let base_metadata2 = coin_wrapper::get_wrapper<SUI>(&store);
            let quote_metadata2 = coin_wrapper::get_wrapper<USDT>(&store);
            let whitelist = ts::take_shared<WhitelistedLPers>(scenario);
            gauge::stake(
                &mut gauge,
                liquidity_pool::mint_lp(
                    pool, 
                    &mut fees_accounting, 
                    &whitelist,
                    quote_metadata2,
                    base_metadata2,
                    base_coin_opt,
                    quote_coin_opt,
                    false,
                    ts::ctx(scenario)
                ),
                ts::ctx(scenario),
                &clock
            );
            ts::return_shared(whitelist);
            ts::return_shared(gauge);

            next_tx(scenario, OWNER);
            let mut gauge1 = ts::take_shared<Gauge<COIN_WRAPPER, COIN_WRAPPER>>(scenario);
            
            let all_pools = liquidity_pool::all_pool_ids(&configs);
            assert!(vector::length(&all_pools) == 1, 4);

            router::unstake_and_remove_liquidity_both_coins_entry(
                &mut gauge1,
                5000,
                2500,
                2500,
                @0x1234,
                &clock,
                ts::ctx(scenario)
            );
            ts::return_shared(gauge1);

            next_tx(scenario, OWNER);
            let mut gauge2 = ts::take_shared<Gauge<COIN_WRAPPER, COIN_WRAPPER>>(scenario);
            let pool1 = gauge::liquidity_pool(&mut gauge2);
            let (coin_in, coin_out) = liquidity_pool::liquidity_amounts<COIN_WRAPPER, COIN_WRAPPER>(
                pool1,
                5000
            );
            assert!(coin_in == 2500, 1);
            assert!(coin_out == 2500, 2);
            transfer::public_transfer(base_coin, @0xcafe);
            transfer::public_transfer(quote_coin, @0xcafe);
            ts::return_shared(fees_accounting);
            ts::return_shared(gauge2);
        };

        ts::return_shared(configs);
        ts::return_shared(store);
        ts::return_to_sender(scenario, cap);
        ts::return_shared(admin_data);
        clock.destroy_for_testing();
        ts::end(scenario_val);
    }
}