#[test_only]
module sui_dex::vote_manager_test {
    use sui::test_scenario::{Self as ts, next_tx};
    use sui::clock;
    use sui::coin::{Self, CoinMetadata};
    use sui::table::{Self, Table};
    use sui::vec_map;
    use sui::coin::{Coin};
    use sui::test_utils;
    use std::debug;
    use sui::balance;
    use std::string;

    use sui_dex::vote_manager::{Self, AdministrativeData, VeTokenVoteAccounting, GaugeVoteAccounting};
    use sui_dex::voting_escrow::{Self, VeSuiDexCollection, VeSuiDexToken};
    use sui_dex::suidex_token::{Self, SUIDEX_TOKEN, SuiDexManager};
    use sui_dex::liquidity_pool::{Self, LiquidityPool, LiquidityPoolConfigs};
    use sui_dex::token_whitelist::{Self, TokenWhitelist, TokenWhitelistAdminCap, RewardTokenWhitelistPerPool};
    use sui_dex::coin_wrapper::{Self, WrapperStore, WrapperStoreCap};
    use sui_dex::minter::{Self, MinterConfig};
    use sui_dex::gauge::{Self, Gauge};
    use sui_dex::rewards_pool::{Self, RewardsPool};
    use sui_dex::rewards_pool_continuous;
    use sui_dex::epoch;
    use sui_dex::sui::{Self, SUI};
    use sui_dex::usdt::{Self, USDT};
    use sui_dex::eth::{Self, ETH};

    const OWNER: address = @0xab;
    const USER: address = @0xcd;
    const REWARDS_RECIPIENT: address = @0x123;
    const LOCK_AMOUNT: u64 = 1000;
    const LOCK_DURATION: u64 = 52;
    const POOL_AMOUNT: u64 = 100000;
    
    fun setup() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;

        vote_manager::init_for_testing(ts::ctx(scenario));
        voting_escrow::init_for_testing(ts::ctx(scenario));
        suidex_token::init_for_testing(ts::ctx(scenario));
        liquidity_pool::init_for_testing(ts::ctx(scenario));
        usdt::init_for_testing_usdt(ts::ctx(scenario));
        sui::init_for_testing_sui(ts::ctx(scenario));
        eth::init_for_testing_eth(ts::ctx(scenario));
        token_whitelist::init_for_testing(ts::ctx(scenario));
        coin_wrapper::init_for_testing(ts::ctx(scenario)); 

        ts::end(scenario_val);
    }

    #[test]
    fun test_basic_vote() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let mut clock = clock::create_for_testing(ts::ctx(scenario));

        // create liquidity pool
        next_tx(scenario, OWNER); 
        {
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            liquidity_pool::create<SUI, USDT>(
                &base_metadata,
                &quote_metadata,
                &mut configs,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        // create ve token for voting
        next_tx(scenario, USER);
        {
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let treasury_cap = suidex_token::get_treasury_cap(&mut manager);
            let lock_coin = suidex_token::mint(treasury_cap, LOCK_AMOUNT, ts::ctx(scenario));
            
            let ve_token = voting_escrow::create_lock(
                lock_coin,
                LOCK_DURATION,
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );
            transfer::public_transfer(ve_token, USER);

            ts::return_shared(manager);
            ts::return_shared(collection);
        };

        // create gauge
        next_tx(scenario, OWNER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            assert!(liquidity_pool::verify_pool_exists(&configs, &base_metadata, &quote_metadata, false), 1);

            vote_manager::create_gauge<SUI, USDT>(
                &mut admin_data,
                &mut configs,
                &base_metadata,
                &quote_metadata, 
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(admin_data);
            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        next_tx(scenario, OWNER);
        {
            minter::init_for_testing(ts::ctx(scenario), &clock);
        };

        // Advance clock to next epoch before voting
        clock::increment_for_testing(&mut clock, 604800000); 

        //vote
        next_tx(scenario, USER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);
            
            let mut gauge_vote_accounting = ts::take_shared<GaugeVoteAccounting>(scenario);
            let mut ve_token_accounting = ts::take_shared<VeTokenVoteAccounting>(scenario);
            let ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            let mut rewards_pool = ts::take_shared<RewardsPool<SUI>>(scenario);
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let mut minter = ts::take_shared<MinterConfig>(scenario);

            // Get pool and gauge
            let mut gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let pool_id = object::id(gauge::liquidity_pool<SUI, USDT>(&mut gauge)); 
            
            assert!(vote_manager::verify_pool_gauge_mapping(&admin_data, pool_id), 0);
            
            // submit vote with full weight
            vote_manager::vote<SUI, USDT>(
                &ve_token,
                pool_id,
                100, // full weight
                &mut admin_data,
                &mut gauge_vote_accounting,
                &mut gauge,
                &mut rewards_pool,
                &mut manager,
                &mut collection,
                &mut minter,
                &mut ve_token_accounting,
                &clock,
                ts::ctx(scenario)
            );
            
            // verify tokens votes were recorded
            let (votes, last_voted) = vote_manager::token_votes(&ve_token, &ve_token_accounting);
            assert!(last_voted == epoch::now(&clock), 1); // vote epoch recorded
            assert!(!vec_map::is_empty(&votes), 2); // votes map not empty
            
            // verify gauge received the votes
            let (current_votes, total_votes) = vote_manager::current_votes(pool_id, &admin_data, &gauge_vote_accounting);
            assert!(current_votes == (voting_escrow::get_voting_power(&ve_token, &clock) as u128), 3); // Full weight applied
            assert!(total_votes == current_votes, 4); // only one vote exists
            
            ts::return_to_sender(scenario, ve_token);
            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
            ts::return_shared(gauge);
            ts::return_shared(manager);
            ts::return_shared(minter);
            ts::return_shared(collection);
            ts::return_shared(rewards_pool);
            ts::return_shared(admin_data);
            ts::return_shared(gauge_vote_accounting);
            ts::return_shared(ve_token_accounting);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }

    #[test]
    fun test_vote_power_allocation() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let mut clock = clock::create_for_testing(ts::ctx(scenario));

        // create multiple pools
        next_tx(scenario, OWNER);
        {
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata_sui = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata_usdt = ts::take_immutable<CoinMetadata<USDT>>(scenario);
            let quote_metadata_eth = ts::take_immutable<CoinMetadata<ETH>>(scenario);

            liquidity_pool::create<SUI, USDT>(
                &base_metadata_sui,
                &quote_metadata_usdt,
                &mut configs,
                false,
                ts::ctx(scenario)
            );

            // Create second pool
            liquidity_pool::create<SUI, ETH>(
                &base_metadata_sui,
                &quote_metadata_eth,
                &mut configs,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(configs);
            ts::return_immutable(base_metadata_sui);
            ts::return_immutable(quote_metadata_usdt);
            ts::return_immutable(quote_metadata_eth);
        };

        // Create ve token with known amount
        next_tx(scenario, USER);
        {
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let treasury_cap = suidex_token::get_treasury_cap(&mut manager);
            let lock_coin = suidex_token::mint(treasury_cap, LOCK_AMOUNT, ts::ctx(scenario));
            
            let ve_token = voting_escrow::create_lock(
                lock_coin,
                LOCK_DURATION,
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );
            transfer::public_transfer(ve_token, USER);

            ts::return_shared(manager);
            ts::return_shared(collection);
        };

        next_tx(scenario, OWNER);
        {
            minter::init_for_testing(ts::ctx(scenario), &clock);
        };

        // create gauges for both pools
        next_tx(scenario, OWNER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);
            let quote_metadata_eth = ts::take_immutable<CoinMetadata<ETH>>(scenario);
            
            // create gauges      
            vote_manager::create_gauge<SUI, USDT>(
                &mut admin_data,
                &mut configs,
                &base_metadata,
                &quote_metadata, 
                false,
                ts::ctx(scenario)
            );
            
            ts::return_shared(admin_data);
            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
            ts::return_immutable(quote_metadata_eth);
        };

        next_tx(scenario, OWNER); 
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata_eth = ts::take_immutable<CoinMetadata<ETH>>(scenario);
            
            vote_manager::create_gauge<ETH, SUI>(
                &mut admin_data,
                &mut configs,
                &quote_metadata_eth, 
                &base_metadata,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(admin_data);
            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata_eth);
        };

        // Increment clock for voting
        clock::increment_for_testing(&mut clock, 604800000 * 2);

        // Vote for SUI/USDT pool
        next_tx(scenario, USER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut gauge_vote_accounting = ts::take_shared<GaugeVoteAccounting>(scenario);
            let mut ve_token_accounting = ts::take_shared<VeTokenVoteAccounting>(scenario);
            let ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            let mut rewards_pool = ts::take_shared<RewardsPool<SUI>>(scenario);
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let mut minter = ts::take_shared<MinterConfig>(scenario);
            let mut gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);

            let pool = gauge::liquidity_pool(&mut gauge);
            let pool_id = object::id(pool);
            
            vote_manager::vote<SUI, USDT>(
                &ve_token,
                pool_id,
                100,
                &mut admin_data,
                &mut gauge_vote_accounting,
                &mut gauge,
                &mut rewards_pool,
                &mut manager,
                &mut collection,
                &mut minter,
                &mut ve_token_accounting,
                &clock,
                ts::ctx(scenario)
            );

            // vote was recorded for correct token & pool
            let (votes_map, last_voted) = vote_manager::token_votes(&ve_token, &ve_token_accounting);
            assert!(last_voted == epoch::now(&clock), 1); // Vote epoch recorded
            assert!(vec_map::contains(&votes_map, &pool_id), 2); // Pool vote exists 

            // gauge received correct voting power
            let (votes_for_gauge, total_votes) = vote_manager::current_votes(pool_id, &admin_data, &gauge_vote_accounting);
            let expected_power = voting_escrow::get_voting_power(&ve_token, &clock);
            assert!(votes_for_gauge == (expected_power as u128), 3); // Full voting power applied
            assert!(total_votes == votes_for_gauge, 4); // Total matches single gauge's votes

            ts::return_shared(admin_data);
            ts::return_shared(rewards_pool);
            ts::return_shared(manager);
            ts::return_shared(collection);
            ts::return_shared(minter);
            ts::return_shared(gauge);
            ts::return_shared(gauge_vote_accounting);
            ts::return_shared(ve_token_accounting);
            ts::return_to_sender(scenario, ve_token);
        };

        // Increment clock between votes
        clock::increment_for_testing(&mut clock, 604800000);

        // Vote for ETH/SUI pool 
        next_tx(scenario, USER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut gauge_vote_accounting = ts::take_shared<GaugeVoteAccounting>(scenario);
            let mut ve_token_accounting = ts::take_shared<VeTokenVoteAccounting>(scenario);
            let ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            let mut rewards_pool = ts::take_shared<RewardsPool<ETH>>(scenario);
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let mut minter = ts::take_shared<MinterConfig>(scenario);
            let mut gauge = ts::take_shared<Gauge<ETH, SUI>>(scenario);

            let pool = gauge::liquidity_pool(&mut gauge);
            let pool_id = object::id(pool);
            
            vote_manager::vote<ETH, SUI>(
                &ve_token,
                pool_id,
                30,
                &mut admin_data,
                &mut gauge_vote_accounting,
                &mut gauge,
                &mut rewards_pool,
                &mut manager,
                &mut collection,
                &mut minter,
                &mut ve_token_accounting,
                &clock,
                ts::ctx(scenario)
            );

            let (gauge_votes, total_votes) = vote_manager::current_votes(pool_id, &admin_data, &gauge_vote_accounting);
            
            assert!(gauge_votes == 141, 3);
            assert!(total_votes == 621, 4);

            ts::return_shared(admin_data);
            ts::return_shared(rewards_pool);
            ts::return_shared(manager);
            ts::return_shared(collection);
            ts::return_shared(minter);
            ts::return_shared(gauge);
            ts::return_shared(gauge_vote_accounting);
            ts::return_shared(ve_token_accounting);
            ts::return_to_sender(scenario, ve_token);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }

    #[test]
    fun test_vote_across_epochs() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let mut clock = clock::create_for_testing(ts::ctx(scenario));

        // Create liquidity pool - keep this part the same
        next_tx(scenario, OWNER); 
        {
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            liquidity_pool::create<SUI, USDT>(
                &base_metadata,
                &quote_metadata,
                &mut configs,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        next_tx(scenario, USER);
        {
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let treasury_cap = suidex_token::get_treasury_cap(&mut manager);
            let lock_coin = suidex_token::mint(treasury_cap, LOCK_AMOUNT, ts::ctx(scenario));
            
            let ve_token = voting_escrow::create_lock(
                lock_coin,
                LOCK_DURATION,
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );
            transfer::public_transfer(ve_token, USER);

            ts::return_shared(manager);
            ts::return_shared(collection);
        };

        next_tx(scenario, OWNER);
        {
            minter::init_for_testing(ts::ctx(scenario), &clock);
        };

        // create gauge
        next_tx(scenario, OWNER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            vote_manager::create_gauge<SUI, USDT>(
                &mut admin_data,
                &mut configs,
                &base_metadata,
                &quote_metadata,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(admin_data);
            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        clock::increment_for_testing(&mut clock, 604800000);

        // first vote
        next_tx(scenario, USER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let pool = gauge::liquidity_pool(&mut gauge);
            let pool_id = object::id(pool);
            let mut gauge_vote_accounting = ts::take_shared<GaugeVoteAccounting>(scenario);
            let mut ve_token_accounting = ts::take_shared<VeTokenVoteAccounting>(scenario);
            let ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            let mut rewards_pool = ts::take_shared<RewardsPool<SUI>>(scenario);
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let mut minter = ts::take_shared<MinterConfig>(scenario);

            let voting_power_before = voting_escrow::get_voting_power(&ve_token, &clock);

            // vote with weight 100
            vote_manager::vote<SUI, USDT>(
                &ve_token,
                pool_id,
                100,
                &mut admin_data,
                &mut gauge_vote_accounting,
                &mut gauge,
                &mut rewards_pool,
                &mut manager,
                &mut collection,
                &mut minter,
                &mut ve_token_accounting,
                &clock,
                ts::ctx(scenario)
            );

            // verify first vote
            let (votes, _) = vote_manager::token_votes(&ve_token, &ve_token_accounting);
            let pool_votes = *vec_map::get(&votes, &pool_id);
            assert!(pool_votes == voting_power_before, 1);

            ts::return_to_sender(scenario, ve_token);
            ts::return_shared(gauge);
            ts::return_shared(admin_data);
            ts::return_shared(rewards_pool);
            ts::return_shared(manager);
            ts::return_shared(collection);
            ts::return_shared(minter);
            ts::return_shared(gauge_vote_accounting);
            ts::return_shared(ve_token_accounting);
        };

        // advance epoch
        clock::increment_for_testing(&mut clock, 604800000);

        // second vote
        next_tx(scenario, USER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let pool = gauge::liquidity_pool(&mut gauge);
            let pool_id = object::id(pool);
            let mut gauge_vote_accounting = ts::take_shared<GaugeVoteAccounting>(scenario);
            let mut ve_token_accounting = ts::take_shared<VeTokenVoteAccounting>(scenario);
            let ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            let mut rewards_pool = ts::take_shared<RewardsPool<SUI>>(scenario);
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let mut minter = ts::take_shared<MinterConfig>(scenario);

            let can_vote = vote_manager::can_vote(&ve_token, &ve_token_accounting, &clock);
            assert!(can_vote, 2);

            // vote with weight 50
            vote_manager::vote<SUI, USDT>(
                &ve_token,
                pool_id,
                50, // Half weight
                &mut admin_data,
                &mut gauge_vote_accounting,
                &mut gauge,
                &mut rewards_pool,
                &mut manager,
                &mut collection,
                &mut minter,
                &mut ve_token_accounting,
                &clock,
                ts::ctx(scenario)
            );

            // verify second vote
            let (votes, last_voted) = vote_manager::token_votes(&ve_token, &ve_token_accounting);
            assert!(last_voted == epoch::now(&clock), 3);
            assert!(!vec_map::is_empty(&votes), 4);

            ts::return_to_sender(scenario, ve_token);
            ts::return_shared(gauge);
            ts::return_shared(admin_data);
            ts::return_shared(rewards_pool);
            ts::return_shared(manager);
            ts::return_shared(collection);
            ts::return_shared(minter);
            ts::return_shared(gauge_vote_accounting);
            ts::return_shared(ve_token_accounting);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }

    #[test]
    fun test_basic_incentive() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let clock = clock::create_for_testing(ts::ctx(scenario));

        // Create liquidity pool
        next_tx(scenario, OWNER);
        {
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            liquidity_pool::create<SUI, USDT>(
                &base_metadata,
                &quote_metadata,
                &mut configs,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        next_tx(scenario, OWNER);
        {
            minter::init_for_testing(ts::ctx(scenario), &clock);
        };

        // create the gauge
        next_tx(scenario, OWNER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            vote_manager::create_gauge<SUI, USDT>(
                &mut admin_data,
                &mut configs,
                &base_metadata,
                &quote_metadata,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(admin_data);
            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        // whitelist reward token
        next_tx(scenario, OWNER);
        {
            let admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut whitelist = ts::take_shared<TokenWhitelist>(scenario);
            let mut pool_whitelist = ts::take_shared<RewardTokenWhitelistPerPool>(scenario);
            let mut wrapper_store = ts::take_shared<WrapperStore>(scenario);
            let admin_cap = ts::take_from_sender<TokenWhitelistAdminCap>(scenario);
            let wrapper_cap = ts::take_from_sender<WrapperStoreCap>(scenario);
            let mut gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let pool = gauge::liquidity_pool(&mut gauge);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            vote_manager::whitelist_coin<SUI>(
                &admin_data,
                &admin_cap,
                &mut whitelist,
                &mut wrapper_store,
                &wrapper_cap,
                coin_wrapper::create_witness(),
                ts::ctx(scenario)
            );

            vote_manager::whitelist_coin<USDT>(
                &admin_data,
                &admin_cap,
                &mut whitelist,
                &mut wrapper_store,
                &wrapper_cap,
                coin_wrapper::create_witness(),
                ts::ctx(scenario)
            );

            // Set default rewards
            vote_manager::whitelist_default_reward_pool(
                pool,
                &base_metadata,
                &quote_metadata,
                &admin_cap,
                &mut pool_whitelist,
                &wrapper_store
            );

            ts::return_shared(admin_data);
            ts::return_shared(whitelist);
            ts::return_shared(pool_whitelist);
            ts::return_shared(wrapper_store);
            ts::return_shared(gauge);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
            ts::return_to_sender(scenario, admin_cap);
            ts::return_to_sender(scenario, wrapper_cap);
        };

        next_tx(scenario, OWNER);
        {
            minter::init_for_testing(ts::ctx(scenario), &clock);
        };

        // Add incentive rewards
        next_tx(scenario, USER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut gauge_vote_accounting = ts::take_shared<GaugeVoteAccounting>(scenario);
            let mut gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let mut rewards_pool = ts::take_shared<RewardsPool<SUI>>(scenario);
            let whitelist = ts::take_shared<RewardTokenWhitelistPerPool>(scenario);
            let wrapper_store = ts::take_shared<WrapperStore>(scenario);
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let mut minter = ts::take_shared<MinterConfig>(scenario);
            
            let reward_coin_1 = coin::mint_for_testing<SUI>(1000, ts::ctx(scenario));
            let reward_coin_2 = coin::mint_for_testing<SUI>(300, ts::ctx(scenario));
            let mut rewards = vector::empty<Coin<SUI>>();

            vector::push_back(&mut rewards, reward_coin_1);
            vector::push_back(&mut rewards, reward_coin_2);

            vote_manager::incentivize<SUI, USDT>(
                rewards,
                &mut rewards_pool,
                &mut admin_data,
                &mut gauge,
                &mut gauge_vote_accounting,
                &mut manager,
                &mut collection,
                &mut minter,
                &whitelist,
                &wrapper_store,
                &clock,
                ts::ctx(scenario)
            );

            // verify rewards were added correctly
            let (_reward_tokens, reward_amounts) = rewards_pool::total_rewards(&rewards_pool, epoch::now(&clock) + 1);
            assert!(vector::length(&reward_amounts) == 2, 1); // check we have two reward
            assert!(*vector::borrow(&reward_amounts, 0) + *vector::borrow(&reward_amounts, 1) == 1300, 2); // check the amount is 1300

            ts::return_shared(admin_data);
            ts::return_shared(gauge_vote_accounting);
            
            
            ts::return_shared(rewards_pool);
            ts::return_shared(whitelist);
            ts::return_shared(gauge);
            ts::return_shared(wrapper_store);
            ts::return_shared(manager);
            ts::return_shared(collection);
            ts::return_shared(minter);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }

    #[test]
    fun test_incentive_coin() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let clock = clock::create_for_testing(ts::ctx(scenario));

        // Create liquidity pool
        next_tx(scenario, OWNER);
        {
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            liquidity_pool::create<SUI, USDT>(
                &base_metadata,
                &quote_metadata,
                &mut configs,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        // Create gauge
        next_tx(scenario, OWNER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            vote_manager::create_gauge<SUI, USDT>(
                &mut admin_data,
                &mut configs,
                &base_metadata,
                &quote_metadata,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(admin_data);
            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        // Whitelist reward token
        next_tx(scenario, OWNER);
        {
            let admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut whitelist = ts::take_shared<TokenWhitelist>(scenario);
            let mut pool_whitelist = ts::take_shared<RewardTokenWhitelistPerPool>(scenario);
            let mut wrapper_store = ts::take_shared<WrapperStore>(scenario);
            let admin_cap = ts::take_from_sender<TokenWhitelistAdminCap>(scenario);
            let wrapper_cap = ts::take_from_sender<WrapperStoreCap>(scenario);
            let mut gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let pool = gauge::liquidity_pool(&mut gauge);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            vote_manager::whitelist_coin<SUI>(
                &admin_data,
                &admin_cap,
                &mut whitelist,
                &mut wrapper_store,
                &wrapper_cap,
                coin_wrapper::create_witness(),
                ts::ctx(scenario)
            );

            vote_manager::whitelist_coin<USDT>(
                &admin_data,
                &admin_cap,
                &mut whitelist,
                &mut wrapper_store,
                &wrapper_cap,
                coin_wrapper::create_witness(),
                ts::ctx(scenario)
            );

            // Set default rewards
            vote_manager::whitelist_default_reward_pool<SUI, USDT>(
                pool,
                &base_metadata,
                &quote_metadata,
                &admin_cap,
                &mut pool_whitelist,
                &wrapper_store
            );

            ts::return_shared(admin_data);
            ts::return_shared(whitelist);
            ts::return_shared(pool_whitelist);
            ts::return_shared(wrapper_store);
            ts::return_shared(gauge);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
            ts::return_to_sender(scenario, admin_cap);
            ts::return_to_sender(scenario, wrapper_cap);
        };

        // Initialize minter
        next_tx(scenario, OWNER);
        {
            minter::init_for_testing(ts::ctx(scenario), &clock);
        };

        // Add incentive rewards
        next_tx(scenario, USER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut gauge_vote_accounting = ts::take_shared<GaugeVoteAccounting>(scenario);
            let mut gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let mut rewards_pool = ts::take_shared<RewardsPool<SUI>>(scenario);
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let mut minter = ts::take_shared<MinterConfig>(scenario);
            let whitelist = ts::take_shared<RewardTokenWhitelistPerPool>(scenario);
            let mut wrapper_store = ts::take_shared<WrapperStore>(scenario);

            let reward_coin = coin::mint_for_testing<SUI>(1000, ts::ctx(scenario));

            vote_manager::incentivize_coin<SUI, USDT, SUI>(
                &mut rewards_pool,
                &mut admin_data,
                &mut gauge,
                &mut gauge_vote_accounting,
                &mut manager,
                &mut collection,
                &mut minter,
                &whitelist,
                &mut wrapper_store,
                reward_coin,
                &clock,
                ts::ctx(scenario)
            );

            // Verify rewards were added correctly
            let (_reward_tokens, reward_amounts) = rewards_pool::total_rewards(&rewards_pool, epoch::now(&clock) + 1);
            assert!(vector::length(&reward_amounts) == 1, 1); // Check we have one reward
            assert!(*vector::borrow(&reward_amounts, 0) == 1000, 2); // Check amount is 1000

            ts::return_shared(admin_data);
            ts::return_shared(gauge_vote_accounting);
            ts::return_shared(gauge);
            ts::return_shared(rewards_pool);
            ts::return_shared(whitelist);
            ts::return_shared(wrapper_store);
            ts::return_shared(manager);
            ts::return_shared(collection);
            ts::return_shared(minter);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }

    #[test]
    fun test_rescue_stuck_rewards() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let mut clock = clock::create_for_testing(ts::ctx(scenario));

        // Create liquidity pool
        next_tx(scenario, OWNER);
        {
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            liquidity_pool::create<SUI, USDT>(
                &base_metadata,
                &quote_metadata,
                &mut configs,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        // create the gauge
        next_tx(scenario, OWNER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            vote_manager::create_gauge<SUI, USDT>(
                &mut admin_data,
                &mut configs,
                &base_metadata,
                &quote_metadata,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(admin_data);
            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        // whitelist reward token
        next_tx(scenario, OWNER);
        {
            let admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut whitelist = ts::take_shared<TokenWhitelist>(scenario);
            let mut pool_whitelist = ts::take_shared<RewardTokenWhitelistPerPool>(scenario);
            let mut wrapper_store = ts::take_shared<WrapperStore>(scenario);
            let admin_cap = ts::take_from_sender<TokenWhitelistAdminCap>(scenario);
            let wrapper_cap = ts::take_from_sender<WrapperStoreCap>(scenario);
            let mut gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let pool = gauge::liquidity_pool(&mut gauge);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            vote_manager::whitelist_coin<USDT>(
                &admin_data,
                &admin_cap,
                &mut whitelist,
                &mut wrapper_store,
                &wrapper_cap,
                coin_wrapper::create_witness(),
                ts::ctx(scenario)
            );

            // set default rewards
            vote_manager::whitelist_default_reward_pool(
                pool,
                &base_metadata,
                &quote_metadata,
                &admin_cap,
                &mut pool_whitelist,
                &wrapper_store
            );

            ts::return_shared(admin_data);
            ts::return_shared(whitelist);
            ts::return_shared(pool_whitelist);
            ts::return_shared(wrapper_store);
            ts::return_shared(gauge);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
            ts::return_to_sender(scenario, admin_cap);
            ts::return_to_sender(scenario, wrapper_cap);
        };

        next_tx(scenario, OWNER);
        {
            minter::init_for_testing(ts::ctx(scenario), &clock);
        };

        // Create a veNFT for testing
        next_tx(scenario, USER);
        {
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let treasury_cap = suidex_token::get_treasury_cap(&mut manager);
            let lock_coin = suidex_token::mint(treasury_cap, LOCK_AMOUNT, ts::ctx(scenario));
            
            let ve_token = voting_escrow::create_lock(
                lock_coin,
                LOCK_DURATION,
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );
            transfer::public_transfer(ve_token, USER);

            ts::return_shared(manager);
            ts::return_shared(collection);
        };

        next_tx(scenario, OWNER);
        {
            let mut rewards_pool = ts::take_shared<RewardsPool<SUI>>(scenario);
            
            let current_epoch = epoch::now(&clock);
            
            // Create rewards
            let reward_coin = coin::mint_for_testing<SUI>(1000, ts::ctx(scenario));
            let add_rewards = vector::singleton(reward_coin);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let add_rewards_metadata = vector::singleton(object::id(&base_metadata));
            
            // First add rewards for the current epoch
            rewards_pool::add_rewards(
                &mut rewards_pool,
                add_rewards_metadata,
                add_rewards,
                current_epoch,
                ts::ctx(scenario)
            );

            ts::return_immutable(base_metadata);
            ts::return_shared(rewards_pool);
        };

        next_tx(scenario, USER); 
        {
            let admin_data = ts::take_shared<AdministrativeData>(scenario);
            let gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let pool = gauge::liquidity_pool_ref(&gauge);
            let pool_id = object::id(pool);

            let fees_pool_id = vote_manager::fees_pool(&admin_data, pool_id);
            let mut fees_pool = ts::take_shared_by_id<RewardsPool<SUI>>(scenario, fees_pool_id);
            
            let current_epoch = epoch::now(&clock);
            
            rewards_pool::increase_allocation(
                USER,
                &mut fees_pool,
                1000,
                &clock,
                ts::ctx(scenario) 
            );

            let (shares, _) = rewards_pool::claimer_shares(
                USER,
                &fees_pool,
                current_epoch
            );
            assert!(shares == 1000, 0);

            ts::return_shared(fees_pool);
            ts::return_shared(gauge);
            ts::return_shared(admin_data);
        };

        next_tx(scenario, USER); 
        {
            let admin_data = ts::take_shared<AdministrativeData>(scenario);
            let gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let pool = gauge::liquidity_pool_ref(&gauge);
            let pool_id = object::id(pool);

            let incentive_pool_id = vote_manager::incentive_pool(&admin_data, pool_id);            
            let mut incentive_pool = ts::take_shared_by_id<RewardsPool<SUI>>(scenario, incentive_pool_id);

            let current_epoch = epoch::now(&clock);
            
            rewards_pool::increase_allocation(
                USER,
                &mut incentive_pool,
                500,
                &clock,
                ts::ctx(scenario) 
            );

            let (shares, _) = rewards_pool::claimer_shares(
                USER,
                &incentive_pool,
                current_epoch
            );
            assert!(shares == 500, 0);

            ts::return_shared(incentive_pool);
            ts::return_shared(gauge);
            ts::return_shared(admin_data);
        };

        // advance the clock for rewards to be claimable
        clock::increment_for_testing(&mut clock, 604800000);

        // Add some rewards that will get "stuck"
        next_tx(scenario, USER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut gauge_vote_accounting = ts::take_shared<GaugeVoteAccounting>(scenario);
            let mut gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let whitelist = ts::take_shared<RewardTokenWhitelistPerPool>(scenario);
            let mut wrapper_store = ts::take_shared<WrapperStore>(scenario);
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let mut minter = ts::take_shared<MinterConfig>(scenario);

            let pool = gauge::liquidity_pool_ref(&gauge);
            let pool_id = object::id(pool);
            let pool_ids = vector::singleton(pool_id);

            // get the fee and incentive pool IDs
            let fees_pool_id = vote_manager::fees_pool(&admin_data, pool_id);
            let incentive_pool_id = vote_manager::incentive_pool(&admin_data, pool_id);
            
            // take the pools from shared storage
            let mut fees_pool = ts::take_shared_by_id<RewardsPool<SUI>>(scenario, fees_pool_id);           
            let mut incentive_pool = ts::take_shared_by_id<RewardsPool<SUI>>(scenario, incentive_pool_id);


            vote_manager::rescue_stuck_rewards(
                pool_ids,
                &mut fees_pool,
                &mut incentive_pool,
                &mut admin_data,
                &mut gauge,
                &mut gauge_vote_accounting,
                &mut manager,
                &mut collection,
                &mut minter,
                &whitelist,
                &mut wrapper_store,
                1, // epoch_count
                USER,
                &clock,
                ts::ctx(scenario)
            );

            // Verify rewards were rescued
            let (_reward_tokens, reward_amounts) = rewards_pool::total_rewards(&incentive_pool, epoch::now(&clock) + 1);
            assert!(vector::length(&reward_amounts) > 0, 1); // Check we have rewards
            assert!(*vector::borrow(&reward_amounts, 0) == 1000, 2); // Check amount matches

            ts::return_shared(admin_data);
            ts::return_shared(gauge_vote_accounting);
            ts::return_shared(gauge);
            ts::return_shared(fees_pool);
            ts::return_shared(incentive_pool);
            ts::return_shared(whitelist);
            ts::return_shared(wrapper_store);
            ts::return_shared(manager);
            ts::return_shared(collection);
            ts::return_shared(minter);
        };

        // more checks
        next_tx(scenario, USER);
        {
            let admin_data = ts::take_shared<AdministrativeData>(scenario);
            let gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let pool = gauge::liquidity_pool_ref(&gauge);
            let pool_id = object::id(pool);
            
            // get pools
            let fees_pool_id = vote_manager::fees_pool(&admin_data, pool_id);
            let incentive_pool_id = vote_manager::incentive_pool(&admin_data, pool_id);
            
            let fees_pool = ts::take_shared_by_id<RewardsPool<SUI>>(scenario, fees_pool_id);           
            let incentive_pool = ts::take_shared_by_id<RewardsPool<SUI>>(scenario, incentive_pool_id);

            let (_reward_tokens, reward_amounts) = rewards_pool::total_rewards(&incentive_pool, epoch::now(&clock) + 1);
            assert!(vector::length(&reward_amounts) > 0, 3); // Check we have rewards
            assert!(*vector::borrow(&reward_amounts, 0) == 1000, 4); // Check amount matches

            // verify pending distribution epoch was updated
            assert!(vote_manager::pending_distribution_epoch(&admin_data) == epoch::now(&clock), 5);

            // verify pools match the gauge
            assert!(fees_pool_id == object::id(&fees_pool), 6);
            assert!(incentive_pool_id == object::id(&incentive_pool), 7);

            ts::return_shared(admin_data);
            ts::return_shared(gauge);
            ts::return_shared(fees_pool);
            ts::return_shared(incentive_pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }

    #[test]
    fun test_emissions() {
    setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let mut clock = clock::create_for_testing(ts::ctx(scenario));

        // Create liquidity pools
        next_tx(scenario, OWNER);
        {
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata_usdt = ts::take_immutable<CoinMetadata<USDT>>(scenario);
            let quote_metadata_eth = ts::take_immutable<CoinMetadata<ETH>>(scenario);

            liquidity_pool::create<SUI, USDT>(
                &base_metadata,
                &quote_metadata_usdt,
                &mut configs,
                false,
                ts::ctx(scenario)
            );

            liquidity_pool::create<SUI, ETH>(
                &base_metadata,
                &quote_metadata_eth,
                &mut configs,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata_usdt);
            ts::return_immutable(quote_metadata_eth);
        };

        // create gauges and make them active
        next_tx(scenario, OWNER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);
            let quote_metadata_eth = ts::take_immutable<CoinMetadata<ETH>>(scenario);

            vote_manager::create_gauge<SUI, USDT>(
                &mut admin_data,
                &mut configs,
                &base_metadata,
                &quote_metadata,
                false,
                ts::ctx(scenario)
            );

            vote_manager::create_gauge<ETH, SUI>(
                &mut admin_data,
                &mut configs,
                &quote_metadata_eth,
                &base_metadata,
                false,
                ts::ctx(scenario)
            );
            
            ts::return_shared(admin_data);
            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
            ts::return_immutable(quote_metadata_eth);
        };

        next_tx(scenario, OWNER);
        {
            minter::init_for_testing(ts::ctx(scenario), &clock);
        };

        // Create VeToken for USER
        next_tx(scenario, USER);
        {
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let treasury_cap = suidex_token::get_treasury_cap(&mut manager);
            let lock_coin = suidex_token::mint(treasury_cap, LOCK_AMOUNT, ts::ctx(scenario));
            
            let ve_token = voting_escrow::create_lock(
                lock_coin,
                LOCK_DURATION,
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );
            transfer::public_transfer(ve_token, USER);

            ts::return_shared(manager);
            ts::return_shared(collection);
        };

        // advance clock to next epoch
        clock::increment_for_testing(&mut clock, 604800000);

        // vote with veToken
        next_tx(scenario, USER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut gauge_vote_accounting = ts::take_shared<GaugeVoteAccounting>(scenario);
            let mut ve_token_accounting = ts::take_shared<VeTokenVoteAccounting>(scenario);
            let mut rewards_pool = ts::take_shared<RewardsPool<SUI>>(scenario);
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let mut minter = ts::take_shared<MinterConfig>(scenario);
            let ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            
            let mut gauge_sui = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let pool_sui_id = object::id(gauge::liquidity_pool(&mut gauge_sui));
            
            vote_manager::vote<SUI, USDT>(
                &ve_token,
                pool_sui_id,
                100, // 100% weight
                &mut admin_data,
                &mut gauge_vote_accounting,  
                &mut gauge_sui,
                &mut rewards_pool,
                &mut manager,
                &mut collection,
                &mut minter,
                &mut ve_token_accounting,
                &clock,
                ts::ctx(scenario)
            );

            ts::return_shared(admin_data);
            ts::return_shared(gauge_vote_accounting);
            ts::return_shared(ve_token_accounting);
            ts::return_to_sender(scenario, ve_token);
            ts::return_shared(rewards_pool);
            ts::return_shared(manager);
            ts::return_shared(collection);
            ts::return_shared(minter);
            ts::return_shared(gauge_sui);
        };

        // stake
        next_tx(scenario, USER);
        {
            let mut gauge_sui = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let mut gauge_eth = ts::take_shared<Gauge<ETH, SUI>>(scenario);

            gauge::stake(&mut gauge_sui, POOL_AMOUNT, ts::ctx(scenario), &clock);
            gauge::stake(&mut gauge_eth, POOL_AMOUNT, ts::ctx(scenario), &clock);
            
            gauge::stake_balance(USER, &mut gauge_sui);
            gauge::stake_balance(USER, &mut gauge_eth);

            ts::return_shared(gauge_sui);
            ts::return_shared(gauge_eth);
        };

        // add rewards
        next_tx(scenario, OWNER);
        {
            let mut gauge_sui = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let mut gauge_eth = ts::take_shared<Gauge<ETH, SUI>>(scenario);
            let admin_data = ts::take_shared<AdministrativeData>(scenario);
            
            let reward_balance1 = balance::create_for_testing(1000);
            let reward_balance2 = balance::create_for_testing(500);
            
            gauge::add_rewards(&mut gauge_sui, reward_balance1, &clock);
            gauge::add_rewards(&mut gauge_eth, reward_balance2, &clock);
            
            ts::return_shared(admin_data);
            ts::return_shared(gauge_sui);
            ts::return_shared(gauge_eth);
        };

        clock::increment_for_testing(&mut clock, 604800000);  // One week

        // check claimable emissions
        next_tx(scenario, USER);
        {
            let admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut gauge_sui = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let pool_sui = gauge::liquidity_pool(&mut gauge_sui);
            let pool_sui_id = object::id(pool_sui);

            gauge::stake_balance(USER, &mut gauge_sui);
            
            let claimable = vote_manager::claimable_emissions(
                USER,
                &admin_data,
                pool_sui_id,
                &mut gauge_sui,
                &clock
            );
            
            assert!(claimable >= 999 && claimable <= 1000, 1);
            
            ts::return_shared(admin_data);
            ts::return_shared(gauge_sui);
        };

        // Check claimable emissions for ETH pool
        next_tx(scenario, USER);
        {
            let admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut gauge_eth = ts::take_shared<Gauge<ETH, SUI>>(scenario);
            let pool_eth = gauge::liquidity_pool_ref(&gauge_eth);
            let pool_eth_id = object::id(pool_eth);
            
            let claimable = vote_manager::claimable_emissions(
                USER,
                &admin_data,
                pool_eth_id,
                &mut gauge_eth,
                &clock
            );
            
            assert!(claimable >= 499 && claimable <= 500, 1);
            
            ts::return_shared(admin_data);
            ts::return_shared(gauge_eth);
        };

        // Claim emissions from USDT pool
        next_tx(scenario, USER);
        {
            let admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut gauge_sui = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let pool_sui = gauge::liquidity_pool_ref(&gauge_sui);
            let pool_sui_id = object::id(pool_sui);
            
            vote_manager::claimable_emissions(
                USER,
                &admin_data,
                pool_sui_id,
                &mut gauge_sui,
                &clock
            );
            
            vote_manager::claim_emissions_entry(
                pool_sui_id,
                &admin_data,
                &mut gauge_sui,
                &clock,
                ts::ctx(scenario)
            );
            
            // verify emissions were claimed
            let claimable_after = vote_manager::claimable_emissions(
                USER,
                &admin_data,
                pool_sui_id,
                &mut gauge_sui,
                &clock
            );
            
            assert!(claimable_after == 0, 3); // should be 0 after claiming
            
            ts::return_shared(admin_data);
            ts::return_shared(gauge_sui);
        };

        // Claim emissions from ETH pool
        next_tx(scenario, USER);
        {
            let admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut gauge_eth = ts::take_shared<Gauge<ETH, SUI>>(scenario);
            let pool_eth = gauge::liquidity_pool_ref(&gauge_eth);
            let pool_eth_id = object::id(pool_eth);
            
            vote_manager::claim_emissions_entry(
                pool_eth_id,
                &admin_data,
                &mut gauge_eth,
                &clock,
                ts::ctx(scenario)
            );
            
            // verify emissions were claimed
            let claimable_after = vote_manager::claimable_emissions(
                USER,
                &admin_data,
                pool_eth_id,
                &mut gauge_eth,
                &clock
            );
            assert!(claimable_after == 0, 4); // should be 0 after claiming
            
            ts::return_shared(admin_data);
            ts::return_shared(gauge_eth);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }

    #[test]
    fun test_merge_ve_tokens() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let mut clock = clock::create_for_testing(ts::ctx(scenario));

        // create two liquidity pools
        next_tx(scenario, OWNER); 
        {
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata_usdt = ts::take_immutable<CoinMetadata<USDT>>(scenario);
            let quote_metadata_eth = ts::take_immutable<CoinMetadata<ETH>>(scenario);

            liquidity_pool::create<SUI, USDT>(
                &base_metadata,
                &quote_metadata_usdt,
                &mut configs,
                false,
                ts::ctx(scenario)
            );

            liquidity_pool::create<SUI, ETH>(
                &base_metadata,
                &quote_metadata_eth,
                &mut configs,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata_usdt);
            ts::return_immutable(quote_metadata_eth);
        };

        // create first gauge SUI/USDT
        next_tx(scenario, OWNER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata_usdt = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            vote_manager::create_gauge<SUI, USDT>(
                &mut admin_data,
                &mut configs,
                &base_metadata,
                &quote_metadata_usdt,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(admin_data);
            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata_usdt);
        };

        // create second gauge SUI/ETH
        next_tx(scenario, OWNER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata_eth = ts::take_immutable<CoinMetadata<ETH>>(scenario);

            vote_manager::create_gauge<ETH, SUI>(
                &mut admin_data,
                &mut configs,
                &quote_metadata_eth,
                &base_metadata,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(admin_data);
            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata_eth);
        };

        // Create two veTokens for USER
        next_tx(scenario, USER);
        {
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let treasury_cap = suidex_token::get_treasury_cap(&mut manager);
            
            // First token with 1000 amount
            let lock_coin1 = suidex_token::mint(treasury_cap, 1000, ts::ctx(scenario));
            let ve_token1 = voting_escrow::create_lock(
                lock_coin1,
                52, // weeks
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );
            
            // Second token with 500 amount
            let lock_coin2 = suidex_token::mint(treasury_cap, 500, ts::ctx(scenario));
            let ve_token2 = voting_escrow::create_lock(
                lock_coin2,
                104, // weeks
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );
            
            transfer::public_transfer(ve_token1, USER);
            transfer::public_transfer(ve_token2, USER);

            ts::return_shared(manager);
            ts::return_shared(collection);
        };

        next_tx(scenario, OWNER);
        {
            minter::init_for_testing(ts::ctx(scenario), &clock);
        };

        // Advance clock to next epoch
        clock::increment_for_testing(&mut clock, 604800000);

        // Vote with first token for SUI/USDT pool
        next_tx(scenario, USER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut gauge_vote_accounting = ts::take_shared<GaugeVoteAccounting>(scenario);
            let mut ve_token_accounting = ts::take_shared<VeTokenVoteAccounting>(scenario);
            let mut gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let mut rewards_pool = ts::take_shared<RewardsPool<SUI>>(scenario);
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let mut minter = ts::take_shared<MinterConfig>(scenario);
            
            let ve_token1 = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            
            let pool_id = object::id(gauge::liquidity_pool(&mut gauge));

            vote_manager::vote<SUI, USDT>(
                &ve_token1,
                pool_id,
                100, // full weight
                &mut admin_data,
                &mut gauge_vote_accounting,
                &mut gauge,
                &mut rewards_pool,
                &mut manager,
                &mut collection,
                &mut minter,
                &mut ve_token_accounting,
                &clock,
                ts::ctx(scenario)
            );

            ts::return_to_sender(scenario, ve_token1);
            ts::return_shared(admin_data);
            ts::return_shared(gauge_vote_accounting);
            ts::return_shared(ve_token_accounting);
            ts::return_shared(gauge);
            ts::return_shared(rewards_pool);
            ts::return_shared(manager);
            ts::return_shared(collection);
            ts::return_shared(minter);
        };

        // advance clock to next epoch
        clock::increment_for_testing(&mut clock, 604800000);

        // vote with second token for SUI/ETH pool
        next_tx(scenario, USER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut gauge_vote_accounting = ts::take_shared<GaugeVoteAccounting>(scenario);
            let mut ve_token_accounting = ts::take_shared<VeTokenVoteAccounting>(scenario);
            let mut gauge = ts::take_shared<Gauge<ETH, SUI>>(scenario);
            let mut rewards_pool = ts::take_shared<RewardsPool<ETH>>(scenario);
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let mut minter = ts::take_shared<MinterConfig>(scenario);
            
            let ve_token2 = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            
            let pool_id = object::id(gauge::liquidity_pool(&mut gauge));

            vote_manager::vote<ETH, SUI>(
                &ve_token2,
                pool_id,
                100,
                &mut admin_data,
                &mut gauge_vote_accounting,
                &mut gauge,
                &mut rewards_pool,
                &mut manager,
                &mut collection,
                &mut minter,
                &mut ve_token_accounting,
                &clock,
                ts::ctx(scenario)
            );

            ts::return_to_sender(scenario, ve_token2);
            ts::return_shared(admin_data);
            ts::return_shared(gauge_vote_accounting);
            ts::return_shared(ve_token_accounting);
            ts::return_shared(gauge);
            ts::return_shared(rewards_pool);
            ts::return_shared(manager);
            ts::return_shared(collection);
            ts::return_shared(minter);
        };

        // merge attempt, claim any pending rebases
        next_tx(scenario, USER);
        {
            let mut ve_token1 = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            let mut ve_token2 = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let mut manager = ts::take_shared<SuiDexManager>(scenario);

            // claim rebases for both tokens
            vote_manager::claim_rebase(
                USER,
                &mut ve_token1,
                &mut collection,
                &mut manager,
                &clock,
                ts::ctx(scenario)
            );

            vote_manager::claim_rebase(
                USER,
                &mut ve_token2,
                &mut collection,
                &mut manager,
                &clock,
                ts::ctx(scenario)
            );

            ts::return_to_sender(scenario, ve_token1);
            ts::return_to_sender(scenario, ve_token2);
            ts::return_shared(collection);
            ts::return_shared(manager);
        };

        // advance clock to next epoch so we can merge
        clock::increment_for_testing(&mut clock, 604800000);

        // merge the tokens
        next_tx(scenario, USER);
        {
            let mut ve_token_accounting = ts::take_shared<VeTokenVoteAccounting>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let source_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);  // token2
            let mut target_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario); // token1

            vote_manager::merge_ve_tokens(
                &mut ve_token_accounting,
                source_token,
                &mut target_token,
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );

            // verify the merged token
            let (votes, _) = vote_manager::token_votes(&target_token, &ve_token_accounting);
            assert!(!vec_map::is_empty(&votes), 1); // should have votes
            
            // verify voting power
            let merged_power = voting_escrow::get_voting_power(&target_token, &clock);
            assert!(merged_power > 1000, 2); // should be greater than original token1's power
            
            ts::return_to_sender(scenario, target_token);
            ts::return_shared(ve_token_accounting);
            ts::return_shared(collection);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = vote_manager::E_ALREADY_VOTED_THIS_EPOCH)]
    fun test_reset_same_epoch_fails() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let clock = clock::create_for_testing(ts::ctx(scenario));

        // Create liquidity pool
        next_tx(scenario, OWNER); 
        {
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            liquidity_pool::create<SUI, USDT>(
                &base_metadata,
                &quote_metadata,
                &mut configs,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        // Create gauge
        next_tx(scenario, OWNER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            vote_manager::create_gauge<SUI, USDT>(
                &mut admin_data,
                &mut configs,
                &base_metadata,
                &quote_metadata,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(admin_data);
            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        // create veToken
        next_tx(scenario, USER);
        {
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let treasury_cap = suidex_token::get_treasury_cap(&mut manager);
            let lock_coin = suidex_token::mint(treasury_cap, LOCK_AMOUNT, ts::ctx(scenario));
            
            let ve_token = voting_escrow::create_lock(
                lock_coin,
                LOCK_DURATION,
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );
            transfer::public_transfer(ve_token, USER);

            ts::return_shared(manager);
            ts::return_shared(collection);
        };

        next_tx(scenario, OWNER);
        {
            minter::init_for_testing(ts::ctx(scenario), &clock);
        };

        // vote with the token
        next_tx(scenario, USER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut gauge_vote_accounting = ts::take_shared<GaugeVoteAccounting>(scenario);
            let mut ve_token_accounting = ts::take_shared<VeTokenVoteAccounting>(scenario);
            let ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            let mut rewards_pool = ts::take_shared<RewardsPool<SUI>>(scenario);
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let mut minter = ts::take_shared<MinterConfig>(scenario);
            let mut gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);

            let pool_id = object::id(gauge::liquidity_pool(&mut gauge));
            
            vote_manager::vote<SUI, USDT>(
                &ve_token,
                pool_id,
                100,
                &mut admin_data,
                &mut gauge_vote_accounting,
                &mut gauge,
                &mut rewards_pool,
                &mut manager,
                &mut collection,
                &mut minter,
                &mut ve_token_accounting,
                &clock,
                ts::ctx(scenario)
            );

            ts::return_to_sender(scenario, ve_token);
            ts::return_shared(admin_data);
            ts::return_shared(gauge_vote_accounting);
            ts::return_shared(ve_token_accounting);
            ts::return_shared(gauge);
            ts::return_shared(rewards_pool);
            ts::return_shared(manager);
            ts::return_shared(collection);
            ts::return_shared(minter);
        };

        // try to reset in same epoch - this should fail
        next_tx(scenario, USER);
        {
            let ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            let mut ve_token_accounting = ts::take_shared<VeTokenVoteAccounting>(scenario);

            vote_manager::reset(
                &ve_token,
                &mut ve_token_accounting,
                &clock,
                ts::ctx(scenario)
            );

            ts::return_to_sender(scenario, ve_token);
            ts::return_shared(ve_token_accounting);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }

    #[test]
    fun test_reset_success() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let mut clock = clock::create_for_testing(ts::ctx(scenario));

        // create liquidity pool
        next_tx(scenario, OWNER); 
        {
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            liquidity_pool::create<SUI, USDT>(
                &base_metadata,
                &quote_metadata,
                &mut configs,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        // create gauge
        next_tx(scenario, OWNER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            vote_manager::create_gauge<SUI, USDT>(
                &mut admin_data,
                &mut configs,
                &base_metadata,
                &quote_metadata,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(admin_data);
            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        // create veToken
        next_tx(scenario, USER);
        {
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let treasury_cap = suidex_token::get_treasury_cap(&mut manager);
            let lock_coin = suidex_token::mint(treasury_cap, LOCK_AMOUNT, ts::ctx(scenario));
            
            let ve_token = voting_escrow::create_lock(
                lock_coin,
                LOCK_DURATION,
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );
            transfer::public_transfer(ve_token, USER);

            ts::return_shared(manager);
            ts::return_shared(collection);
        };

        next_tx(scenario, OWNER);
        {
            minter::init_for_testing(ts::ctx(scenario), &clock);
        };

        clock::increment_for_testing(&mut clock, 604800000);
            
        // vote with the token
        next_tx(scenario, USER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut gauge_vote_accounting = ts::take_shared<GaugeVoteAccounting>(scenario);
            let mut ve_token_accounting = ts::take_shared<VeTokenVoteAccounting>(scenario);
            let ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            let mut rewards_pool = ts::take_shared<RewardsPool<SUI>>(scenario);
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let mut minter = ts::take_shared<MinterConfig>(scenario);
            let mut gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);

            let pool_id = object::id(gauge::liquidity_pool(&mut gauge));
            
            vote_manager::vote<SUI, USDT>(
                &ve_token,
                pool_id,
                100,
                &mut admin_data,
                &mut gauge_vote_accounting,
                &mut gauge,
                &mut rewards_pool,
                &mut manager,
                &mut collection,
                &mut minter,
                &mut ve_token_accounting,
                &clock,
                ts::ctx(scenario)
            );

            // Verify initial vote state
            let (votes, last_voted) = vote_manager::token_votes(&ve_token, &ve_token_accounting);
            assert!(!vec_map::is_empty(&votes), 1);
            assert!(last_voted == epoch::now(&clock), 2);

            ts::return_to_sender(scenario, ve_token);
            ts::return_shared(admin_data);
            ts::return_shared(gauge_vote_accounting);
            ts::return_shared(ve_token_accounting);
            ts::return_shared(gauge);
            ts::return_shared(rewards_pool);
            ts::return_shared(manager);
            ts::return_shared(collection);
            ts::return_shared(minter);
        };

        // Advance epoch to allow reset
        clock::increment_for_testing(&mut clock, 604800000);

        // Reset votes
        next_tx(scenario, USER);
        {
            let ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            let mut ve_token_accounting = ts::take_shared<VeTokenVoteAccounting>(scenario);

            vote_manager::reset(
                &ve_token,
                &mut ve_token_accounting,
                &clock,
                ts::ctx(scenario)
            );

            // verify votes were reset
            let (votes, last_voted) = vote_manager::token_votes(&ve_token, &ve_token_accounting);
            assert!(vec_map::is_empty(&votes), 3); // votes should be cleared
            assert!(last_voted == epoch::now(&clock), 4); // Last voted should be updated

            ts::return_to_sender(scenario, ve_token);
            ts::return_shared(ve_token_accounting);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = vote_manager::E_ALREADY_VOTED_THIS_EPOCH)]
    fun test_poke_same_epoch_fails() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let clock = clock::create_for_testing(ts::ctx(scenario));

        // create liquidity pool
        next_tx(scenario, OWNER); 
        {
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            liquidity_pool::create<SUI, USDT>(
                &base_metadata,
                &quote_metadata,
                &mut configs,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        // vreate gauge
        next_tx(scenario, OWNER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            vote_manager::create_gauge<SUI, USDT>(
                &mut admin_data,
                &mut configs,
                &base_metadata,
                &quote_metadata,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(admin_data);
            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        // create veToken
        next_tx(scenario, USER);
        {
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let treasury_cap = suidex_token::get_treasury_cap(&mut manager);
            let lock_coin = suidex_token::mint(treasury_cap, LOCK_AMOUNT, ts::ctx(scenario));
            
            let ve_token = voting_escrow::create_lock(
                lock_coin,
                LOCK_DURATION,
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );
            transfer::public_transfer(ve_token, USER);

            ts::return_shared(manager);
            ts::return_shared(collection);
        };

        next_tx(scenario, OWNER);
        {
            minter::init_for_testing(ts::ctx(scenario), &clock);
        };

        // initial vote
        next_tx(scenario, USER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut gauge_vote_accounting = ts::take_shared<GaugeVoteAccounting>(scenario);
            let mut ve_token_accounting = ts::take_shared<VeTokenVoteAccounting>(scenario);
            let ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            let mut rewards_pool = ts::take_shared<RewardsPool<SUI>>(scenario);
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let mut minter = ts::take_shared<MinterConfig>(scenario);
            let mut gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);

            let pool_id = object::id(gauge::liquidity_pool(&mut gauge));
            
            vote_manager::vote<SUI, USDT>(
                &ve_token,
                pool_id,
                100,
                &mut admin_data,
                &mut gauge_vote_accounting,
                &mut gauge,
                &mut rewards_pool,
                &mut manager,
                &mut collection,
                &mut minter,
                &mut ve_token_accounting,
                &clock,
                ts::ctx(scenario)
            );

            ts::return_to_sender(scenario, ve_token);
            ts::return_shared(admin_data);
            ts::return_shared(gauge_vote_accounting);
            ts::return_shared(ve_token_accounting);
            ts::return_shared(gauge);
            ts::return_shared(rewards_pool);
            ts::return_shared(manager);
            ts::return_shared(collection);
            ts::return_shared(minter);
        };

        // try to poke in same epoch - this should fail
        next_tx(scenario, USER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut gauge_vote_accounting = ts::take_shared<GaugeVoteAccounting>(scenario);
            let mut ve_token_accounting = ts::take_shared<VeTokenVoteAccounting>(scenario);
            let ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            let mut rewards_pool = ts::take_shared<RewardsPool<SUI>>(scenario);
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let mut minter = ts::take_shared<MinterConfig>(scenario);
            let mut gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let pool_id = object::id(gauge::liquidity_pool(&mut gauge));

            vote_manager::poke<SUI, USDT>(
                &ve_token,
                pool_id,
                &mut admin_data,
                &mut gauge_vote_accounting,
                &mut gauge,
                &mut rewards_pool,
                &mut manager,
                &mut collection,
                &mut minter,
                &mut ve_token_accounting,
                &clock,
                ts::ctx(scenario)
            );

            ts::return_to_sender(scenario, ve_token);
            ts::return_shared(admin_data);
            ts::return_shared(gauge_vote_accounting);
            ts::return_shared(ve_token_accounting);
            ts::return_shared(gauge);
            ts::return_shared(rewards_pool);
            ts::return_shared(manager);
            ts::return_shared(collection);
            ts::return_shared(minter);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }

    #[test]
    fun test_poke_success() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let mut clock = clock::create_for_testing(ts::ctx(scenario));

        // create liquidity pool
        next_tx(scenario, OWNER); 
        {
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            liquidity_pool::create<SUI, USDT>(
                &base_metadata,
                &quote_metadata,
                &mut configs,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        // create gauge
        next_tx(scenario, OWNER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            vote_manager::create_gauge<SUI, USDT>(
                &mut admin_data,
                &mut configs,
                &base_metadata,
                &quote_metadata,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(admin_data);
            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        // create veToken
        next_tx(scenario, USER);
        {
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let treasury_cap = suidex_token::get_treasury_cap(&mut manager);
            let lock_coin = suidex_token::mint(treasury_cap, LOCK_AMOUNT, ts::ctx(scenario));
            
            let ve_token = voting_escrow::create_lock(
                lock_coin,
                LOCK_DURATION,
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );
            transfer::public_transfer(ve_token, USER);

            ts::return_shared(manager);
            ts::return_shared(collection);
        };

        next_tx(scenario, OWNER);
        {
            minter::init_for_testing(ts::ctx(scenario), &clock);
        };

        clock::increment_for_testing(&mut clock, 604800000);

        // initial vote
        next_tx(scenario, USER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut gauge_vote_accounting = ts::take_shared<GaugeVoteAccounting>(scenario);
            let mut ve_token_accounting = ts::take_shared<VeTokenVoteAccounting>(scenario);
            let ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            let mut rewards_pool = ts::take_shared<RewardsPool<SUI>>(scenario);
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let mut minter = ts::take_shared<MinterConfig>(scenario);
            let mut gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);

            let pool_id = object::id(gauge::liquidity_pool(&mut gauge));
            
            vote_manager::vote<SUI, USDT>(
                &ve_token,
                pool_id,
                100,
                &mut admin_data,
                &mut gauge_vote_accounting,
                &mut gauge,
                &mut rewards_pool,
                &mut manager,
                &mut collection,
                &mut minter,
                &mut ve_token_accounting,
                &clock,
                ts::ctx(scenario)
            );

            // Store initial vote state
            let (votes, last_voted) = vote_manager::token_votes(&ve_token, &ve_token_accounting);
            assert!(!vec_map::is_empty(&votes), 1);
            assert!(last_voted == epoch::now(&clock), 2);

            ts::return_to_sender(scenario, ve_token);
            ts::return_shared(admin_data);
            ts::return_shared(gauge_vote_accounting);
            ts::return_shared(ve_token_accounting);
            ts::return_shared(gauge);
            ts::return_shared(rewards_pool);
            ts::return_shared(manager);
            ts::return_shared(collection);
            ts::return_shared(minter);
        };

        // Advance epoch
        clock::increment_for_testing(&mut clock, 604800000);

        // Poke votes - should succeed
        next_tx(scenario, USER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut gauge_vote_accounting = ts::take_shared<GaugeVoteAccounting>(scenario);
            let mut ve_token_accounting = ts::take_shared<VeTokenVoteAccounting>(scenario);
            let ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            let mut rewards_pool = ts::take_shared<RewardsPool<SUI>>(scenario);
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let mut minter = ts::take_shared<MinterConfig>(scenario);
            let mut gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let pool_id = object::id(gauge::liquidity_pool(&mut gauge));

            // Store state before poke
            let (votes_before, _) = vote_manager::token_votes(&ve_token, &ve_token_accounting);
            let vote_power_before = *vec_map::get(&votes_before, &pool_id);

            vote_manager::poke<SUI, USDT>(
                &ve_token,
                pool_id,
                &mut admin_data,
                &mut gauge_vote_accounting,
                &mut gauge,
                &mut rewards_pool,
                &mut manager,
                &mut collection,
                &mut minter,
                &mut ve_token_accounting,
                &clock,
                ts::ctx(scenario)
            );

            // verify vote state after poke
            let (votes_after, last_voted) = vote_manager::token_votes(&ve_token, &ve_token_accounting);
            let vote_power_after = *vec_map::get(&votes_after, &pool_id);
            
            assert!(!vec_map::is_empty(&votes_after), 3); // Still has votes
            assert!(last_voted == epoch::now(&clock), 4); // Last voted updated
            assert!(vote_power_after >= vote_power_before, 5); // Vote power maintained/increased

            ts::return_to_sender(scenario, ve_token);
            ts::return_shared(admin_data);
            ts::return_shared(gauge_vote_accounting);
            ts::return_shared(ve_token_accounting);
            ts::return_shared(gauge);
            ts::return_shared(rewards_pool);
            ts::return_shared(manager);
            ts::return_shared(collection);
            ts::return_shared(minter);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = vote_manager::E_NOT_OPERATOR)]
    fun test_whitelist_token_reward_pool_wrong_operator() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let clock = clock::create_for_testing(ts::ctx(scenario));

        // create liquidity pool
        next_tx(scenario, OWNER); 
        {
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            liquidity_pool::create<SUI, USDT>(
                &base_metadata,
                &quote_metadata,
                &mut configs,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        // try to whitelist with non-operator account (USER)
        next_tx(scenario, USER);
        {
            let configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);
            let admin_data = ts::take_shared<AdministrativeData>(scenario);
            let pool = liquidity_pool::liquidity_pool<SUI, USDT>(&configs, &base_metadata, &quote_metadata, false);
            let admin_cap = ts::take_from_address<TokenWhitelistAdminCap>(scenario, OWNER);
            let mut pool_whitelist = ts::take_shared<RewardTokenWhitelistPerPool>(scenario);
            let mut tokens = vector::empty<string::String>();
            vector::push_back(&mut tokens, string::utf8(b"sui::sui::SUI"));

            vote_manager::whitelist_token_reward_pool_entry<SUI, USDT>(
                pool,
                tokens,
                &admin_cap,
                &mut pool_whitelist,
                &admin_data,
                true,
                ts::ctx(scenario)
            );

            ts::return_shared(admin_data);
            ts::return_shared(admin_cap);
            ts::return_shared(pool_whitelist);
            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }

    #[test]
    fun test_whitelist_token_reward_pool_success() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let clock = clock::create_for_testing(ts::ctx(scenario));

        // create liquidity pool
        next_tx(scenario, OWNER); 
        {
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            liquidity_pool::create<SUI, USDT>(
                &base_metadata,
                &quote_metadata,
                &mut configs,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        // whitelist tokens as operator (OWNER)
        next_tx(scenario, OWNER);
        {
            let configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);
            let admin_data = ts::take_shared<AdministrativeData>(scenario);
            let pool = liquidity_pool::liquidity_pool<SUI, USDT>(&configs, &base_metadata, &quote_metadata, false);
            let mut pool_whitelist = ts::take_shared<RewardTokenWhitelistPerPool>(scenario);
            let admin_cap = ts::take_from_sender<TokenWhitelistAdminCap>(scenario);
            let pool_addr = object::id_address(pool);
            
            let sui_token = string::utf8(b"sui::sui::SUI");
            let mut tokens = vector::empty<string::String>();
            vector::push_back(&mut tokens, sui_token);

            vote_manager::whitelist_token_reward_pool_entry<SUI, USDT>(
                pool,
                tokens,
                &admin_cap,
                &mut pool_whitelist,
                &admin_data,
                true,
                ts::ctx(scenario)
            );

            // Verify SUI is whitelisted
            assert!(token_whitelist::is_reward_token_whitelisted_on_pool(
                &pool_whitelist,
                &sui_token,
                pool_addr
            ), 1); // SUI should be whitelisted

            // now whitelist USDT
            let usdt_token = string::utf8(b"sui::usdt::USDT");
            let mut tokens2 = vector::empty<string::String>();
            vector::push_back(&mut tokens2, usdt_token);
            
            vote_manager::whitelist_token_reward_pool_entry<SUI, USDT>(
                pool,
                tokens2,
                &admin_cap,
                &mut pool_whitelist,
                &admin_data,
                true,
                ts::ctx(scenario)
            );

            // verify both tokens are whitelisted
            assert!(token_whitelist::is_reward_token_whitelisted_on_pool(
                &pool_whitelist,
                &sui_token,
                pool_addr
            ), 2); // SUI should still be whitelisted

            assert!(token_whitelist::is_reward_token_whitelisted_on_pool(
                &pool_whitelist,
                &usdt_token,
                pool_addr
            ), 3); // USDT should be whitelisted

            // Verify total whitelist length
            let whitelist_len = token_whitelist::whitelist_length(&pool_whitelist, pool_addr);
            assert!(whitelist_len == 2, 4); // Should have both tokens

            // Remove only USDT from whitelist
            let mut tokens3 = vector::empty<string::String>();
            vector::push_back(&mut tokens3, usdt_token);
            
            vote_manager::whitelist_token_reward_pool_entry<SUI, USDT>(
                pool,
                tokens3,
                &admin_cap,
                &mut pool_whitelist,
                &admin_data,
                false,  // remove USDT
                ts::ctx(scenario)
            );

            // Verify SUI still whitelisted but USDT removed
            assert!(token_whitelist::is_reward_token_whitelisted_on_pool(
                &pool_whitelist,
                &sui_token,
                pool_addr
            ), 5); // SUI should still be whitelisted

            assert!(!token_whitelist::is_reward_token_whitelisted_on_pool(
                &pool_whitelist,
                &usdt_token,
                pool_addr
            ), 6); // USDT should be removed

            // Verify updated length
            let whitelist_len_after = token_whitelist::whitelist_length(&pool_whitelist, pool_addr);
            assert!(whitelist_len_after == 1, 7); // Should only have SUI

            ts::return_to_sender(scenario, admin_cap);
            ts::return_shared(admin_data);
            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
            ts::return_shared(pool_whitelist);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }

    #[test]
    fun test_claim_rewards_invalid_coin() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let mut clock = clock::create_for_testing(ts::ctx(scenario));

        // create liquidity pool
        next_tx(scenario, OWNER); 
        {
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            liquidity_pool::create<SUI, USDT>(
                &base_metadata,
                &quote_metadata,
                &mut configs,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        // Get the pool IDs
        let fees_pool_id;
        let incentive_pool_id;
        let pool_id;

        // create gauge
        next_tx(scenario, OWNER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            vote_manager::create_gauge<SUI, USDT>(
                &mut admin_data,
                &mut configs,
                &base_metadata,
                &quote_metadata,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(admin_data);
            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        next_tx(scenario, OWNER); {
            let admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let lp = gauge::liquidity_pool(&mut gauge);
            pool_id = object::id(lp);
            
            // Get the rewards pool IDs
            fees_pool_id = vote_manager::fees_pool(&admin_data, pool_id);
            incentive_pool_id = vote_manager::incentive_pool(&admin_data, pool_id);

            ts::return_shared(gauge);
            ts::return_shared(admin_data);
        };

        // create veToken
        next_tx(scenario, USER);
        {
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let treasury_cap = suidex_token::get_treasury_cap(&mut manager);
            let lock_coin = suidex_token::mint(treasury_cap, LOCK_AMOUNT, ts::ctx(scenario));
            
            let ve_token = voting_escrow::create_lock(
                lock_coin,
                LOCK_DURATION,
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );
            transfer::public_transfer(ve_token, USER);

            ts::return_shared(manager);
            ts::return_shared(collection);
        };

        // Advance clock and setup rewards
        clock::increment_for_testing(&mut clock, 604800000);
        let current_epoch = epoch::now(&clock);

        next_tx(scenario, OWNER);
        {
            let mut fees_pool = ts::take_shared_by_id<RewardsPool<SUI>>(scenario, fees_pool_id);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);

            let mut metadata = vector::empty<ID>();
            vector::push_back(&mut metadata, object::id(&base_metadata));

            let base_coin = coin::mint_for_testing<SUI>(10000, ts::ctx(scenario));
            let mut rewards = vector::empty<Coin<SUI>>();
            vector::push_back(&mut rewards, base_coin);

            rewards_pool::add_rewards(&mut fees_pool, metadata, rewards, current_epoch, ts::ctx(scenario));
            let shares = rewards_pool::increase_allocation(USER, &mut fees_pool, 10000, &clock, ts::ctx(scenario));
            assert!(shares == 10000, 1);

            ts::return_shared(fees_pool);
            ts::return_immutable(base_metadata);
        };

        next_tx(scenario, OWNER);
        {
            let mut incentive_pool = ts::take_shared_by_id<RewardsPool<SUI>>(scenario, incentive_pool_id);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            
            let mut metadata = vector::empty<ID>();
            vector::push_back(&mut metadata, object::id(&base_metadata));

            let base_coin = coin::mint_for_testing<SUI>(10000, ts::ctx(scenario));
            let mut rewards = vector::empty<Coin<SUI>>();
            vector::push_back(&mut rewards, base_coin);

            rewards_pool::add_rewards(&mut incentive_pool, metadata, rewards, current_epoch, ts::ctx(scenario));
            let shares = rewards_pool::increase_allocation(USER, &mut incentive_pool, 10000, &clock, ts::ctx(scenario));
            assert!(shares == 10000, 2);

            ts::return_shared(incentive_pool);
            ts::return_immutable(base_metadata);
        };

        // Advance clock to next epoch
        clock::increment_for_testing(&mut clock, 604800000);

        // Claim rewards
        next_tx(scenario, USER);
        {
            let admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut wrapper_store = ts::take_shared<WrapperStore>(scenario);
            let mut fees_pool = ts::take_shared_by_id<RewardsPool<SUI>>(scenario, fees_pool_id);
            let mut incentive_pool = ts::take_shared_by_id<RewardsPool<SUI>>(scenario, incentive_pool_id);
            let ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            let gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);

            vote_manager::claim_rewards<
                SUI,  // BaseType
                USDT,
                ETH, 
                USDT, 
                vote_manager::NullCoin,   
                vote_manager::NullCoin, 
                vote_manager::NullCoin,
                vote_manager::NullCoin,
                vote_manager::NullCoin,
                vote_manager::NullCoin,
                vote_manager::NullCoin,
                vote_manager::NullCoin,
                vote_manager::NullCoin,
                vote_manager::NullCoin,
                vote_manager::NullCoin,
                vote_manager::NullCoin
            >(
                &ve_token,
                pool_id,
                current_epoch,
                &admin_data,
                &mut fees_pool,
                &mut incentive_pool,
                &mut wrapper_store,
                &clock,
                ts::ctx(scenario)
            );

            assert!(rewards_pool::reward_store_amount_for_testing(&fees_pool, 0) == 0, 3);
            assert!(rewards_pool::reward_store_amount_for_testing(&incentive_pool, 0) == 0, 4);

            let (_, fees_total) = rewards_pool::total_rewards(&fees_pool, current_epoch);
            let (_, incentive_total) = rewards_pool::total_rewards(&incentive_pool, current_epoch);
            assert!(vector::length(&fees_total) == 0, 5);
            assert!(vector::length(&incentive_total) == 0, 6);

            ts::return_to_sender(scenario, ve_token);
            ts::return_shared(admin_data);
            ts::return_shared(fees_pool);
            ts::return_shared(incentive_pool);
            ts::return_shared(wrapper_store);
            ts::return_shared(gauge);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }

    #[test]
    fun test_claimable_rewards() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let mut clock = clock::create_for_testing(ts::ctx(scenario));

        // Create liquidity pool
        next_tx(scenario, OWNER); 
        {
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            liquidity_pool::create<SUI, USDT>(
                &base_metadata,
                &quote_metadata,
                &mut configs,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        // Get the pool IDs
        let fees_pool_id;
        let incentive_pool_id;
        let pool_id;

        // create gauge
        next_tx(scenario, OWNER);
        {
            let mut admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut configs = ts::take_shared<LiquidityPoolConfigs>(scenario);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            vote_manager::create_gauge<SUI, USDT>(
                &mut admin_data,
                &mut configs,
                &base_metadata,
                &quote_metadata,
                false,
                ts::ctx(scenario)
            );

            ts::return_shared(admin_data);
            ts::return_shared(configs);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
        };

        next_tx(scenario, OWNER); {
            let admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let lp = gauge::liquidity_pool(&mut gauge);
            pool_id = object::id(lp);
            
            // get the rewards pool IDs
            fees_pool_id = vote_manager::fees_pool(&admin_data, pool_id);
            incentive_pool_id = vote_manager::incentive_pool(&admin_data, pool_id);

            ts::return_shared(gauge);
            ts::return_shared(admin_data);
        };

        next_tx(scenario, OWNER); {
            let admin_data = ts::take_shared<AdministrativeData>(scenario);
            let mut wrapper_store = ts::take_shared<WrapperStore>(scenario);
            let wrapper_cap = ts::take_from_sender<WrapperStoreCap>(scenario);
            
            // register SUI in the wrapper store
            coin_wrapper::register_coin<SUI>(
                &wrapper_cap, 
                coin_wrapper::create_witness(),
                &mut wrapper_store,
                ts::ctx(scenario)
            );

            ts::return_to_sender(scenario, wrapper_cap);
            ts::return_shared(admin_data);
            ts::return_shared(wrapper_store);
        };

        // add after registering coin but before adding rewards:
        next_tx(scenario, OWNER); {
            let admin_data = ts::take_shared<AdministrativeData>(scenario);
            let whitelist = ts::take_shared<TokenWhitelist>(scenario);
            let mut pool_whitelist = ts::take_shared<RewardTokenWhitelistPerPool>(scenario);
            let wrapper_store = ts::take_shared<WrapperStore>(scenario);
            let admin_cap = ts::take_from_sender<TokenWhitelistAdminCap>(scenario);
            let wrapper_cap = ts::take_from_sender<WrapperStoreCap>(scenario);
            let mut gauge = ts::take_shared<Gauge<SUI, USDT>>(scenario);
            let pool = gauge::liquidity_pool(&mut gauge);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            let quote_metadata = ts::take_immutable<CoinMetadata<USDT>>(scenario);

            // set default rewards
            vote_manager::whitelist_default_reward_pool(
                pool,
                &base_metadata,
                &quote_metadata,
                &admin_cap,
                &mut pool_whitelist,
                &wrapper_store
            );

            ts::return_shared(admin_data);
            ts::return_shared(whitelist);
            ts::return_shared(pool_whitelist);
            ts::return_shared(wrapper_store);
            ts::return_shared(gauge);
            ts::return_immutable(base_metadata);
            ts::return_immutable(quote_metadata);
            ts::return_to_sender(scenario, admin_cap);
            ts::return_to_sender(scenario, wrapper_cap);
        };

        // create veToken
        next_tx(scenario, USER);
        {
            let mut manager = ts::take_shared<SuiDexManager>(scenario);
            let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
            let treasury_cap = suidex_token::get_treasury_cap(&mut manager);
            let lock_coin = suidex_token::mint(treasury_cap, LOCK_AMOUNT, ts::ctx(scenario));
            
            let ve_token = voting_escrow::create_lock(
                lock_coin,
                LOCK_DURATION,
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );
            transfer::public_transfer(ve_token, USER);

            ts::return_shared(manager);
            ts::return_shared(collection);
        };

        // advance clock and setup rewards
        clock::increment_for_testing(&mut clock, 604800000);
        let current_epoch = epoch::now(&clock);

        // add rewards to fees pool
        next_tx(scenario, OWNER);
        {
            let mut fees_pool = ts::take_shared_by_id<RewardsPool<SUI>>(scenario, fees_pool_id);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);

            let mut metadata = vector::empty<ID>();
            vector::push_back(&mut metadata, object::id(&base_metadata));

            let fees_amount = 5000;
            let base_coin = coin::mint_for_testing<SUI>(fees_amount, ts::ctx(scenario));
            let mut rewards = vector::empty<Coin<SUI>>();
            vector::push_back(&mut rewards, base_coin);

            rewards_pool::add_rewards(&mut fees_pool, metadata, rewards, current_epoch, ts::ctx(scenario));
            let shares = rewards_pool::increase_allocation(USER, &mut fees_pool, fees_amount, &clock, ts::ctx(scenario));
            assert!(shares == fees_amount, 1);

            ts::return_shared(fees_pool);
            ts::return_immutable(base_metadata);
        };

        // add rewards to incentive pool
        next_tx(scenario, OWNER);
        {
            let mut incentive_pool = ts::take_shared_by_id<RewardsPool<SUI>>(scenario, incentive_pool_id);
            let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
            
            let mut metadata = vector::empty<ID>();
            vector::push_back(&mut metadata, object::id(&base_metadata));

            let incentive_amount = 3000;
            let base_coin = coin::mint_for_testing<SUI>(incentive_amount, ts::ctx(scenario));
            let mut rewards = vector::empty<Coin<SUI>>();
            vector::push_back(&mut rewards, base_coin);

            rewards_pool::add_rewards(&mut incentive_pool, metadata, rewards, current_epoch, ts::ctx(scenario));
            let shares = rewards_pool::increase_allocation(USER, &mut incentive_pool, incentive_amount, &clock, ts::ctx(scenario));
            assert!(shares == incentive_amount, 2);

            ts::return_shared(incentive_pool);
            ts::return_immutable(base_metadata);
        };

        // check claimable rewards
        next_tx(scenario, USER);
        {
            let wrapper_store = ts::take_shared<WrapperStore>(scenario);
            let fees_pool = ts::take_shared_by_id<RewardsPool<SUI>>(scenario, fees_pool_id);
            let incentive_pool = ts::take_shared_by_id<RewardsPool<SUI>>(scenario, incentive_pool_id);
            let ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);

            // claimable rewards
            let claimable = vote_manager::claimable_rewards(
                &ve_token,
                &fees_pool,
                &incentive_pool,
                &wrapper_store,
                &clock,
                current_epoch
            );

            let key = coin_wrapper::format_coin<SUI>();
            
            assert!(vec_map::contains(&claimable, &key), 3);        
            assert!(*vec_map::get(&claimable, &key) == 8000, 4);

            ts::return_to_sender(scenario, ve_token);
            ts::return_shared(fees_pool);
            ts::return_shared(incentive_pool);
            ts::return_shared(wrapper_store);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }
}