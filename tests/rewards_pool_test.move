#[test_only]
module sui_dex::rewards_pool_test {
    use sui::test_scenario::{Self as ts, next_tx, Scenario};
    use sui::coin::{Self, Coin, CoinMetadata};
    use sui::clock;
    
    // --- modules ---
    use sui_dex::rewards_pool::{Self, RewardsPool};
    use sui_dex::sui::{Self, SUI};
    use sui_dex::epoch;

    //params
    const MS_IN_WEEK: u64 = 604800000; // milliseconds in a week
    
    // --- addresses ---
    const OWNER: address = @0xab;
    
    fun setup(scenario: &mut Scenario) {
        // Initialize all modules
        sui::init_for_testing_sui(ts::ctx(scenario));

        next_tx(scenario, OWNER);
        let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
        let mut reward_tokens_list = vector::empty<ID>();
        vector::push_back(&mut reward_tokens_list, object::id(&base_metadata));
        rewards_pool::create<SUI>(reward_tokens_list, ts::ctx(scenario));

        ts::return_immutable(base_metadata);
    }

    #[test]
    fun test_create(): RewardsPool<SUI> {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;

        next_tx(scenario, OWNER);
        setup(scenario);
    
        next_tx(scenario, OWNER);
        let rewards_pool = ts::take_shared<RewardsPool<SUI>>(scenario);
        let reward_stores_tokens = rewards_pool::reward_stores_tokens_for_testing(&rewards_pool);
        assert!(vector::length<ID>(&reward_stores_tokens) == 1, 1);
        
        ts::end(scenario_val);
        rewards_pool
    }

    #[test]
    fun test_add_rewards(): RewardsPool<SUI> {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        
        next_tx(scenario, OWNER);
        setup(scenario);
    
        next_tx(scenario, OWNER);
        let mut rewards_pool = ts::take_shared<RewardsPool<SUI>>(scenario);
        let amount = 100000;
        let base_coin = coin::mint_for_testing<SUI>(amount, ts::ctx(scenario));
        let mut add_rewards = vector::empty<Coin<SUI>>();
        vector::push_back(&mut add_rewards, base_coin);
        let mut clock = clock::create_for_testing(ts::ctx(scenario));
        clock.increment_for_testing(MS_IN_WEEK);
        let current_epoch = epoch::now(&clock);
        let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
        let mut add_rewards_metadata = vector::empty<ID>();
        vector::push_back(&mut add_rewards_metadata, object::id(&base_metadata));
        rewards_pool::add_rewards(&mut rewards_pool, add_rewards_metadata, add_rewards, current_epoch, ts::ctx(scenario));

        assert!(rewards_pool::reward_store_amount_for_testing(&rewards_pool, 0) == amount, 2);
        
        clock::destroy_for_testing(clock);
        ts::return_immutable(base_metadata);
        ts::end(scenario_val);
        rewards_pool
    }

    #[test]
    fun test_increase_decrease_rewards(): RewardsPool<SUI> {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        
        next_tx(scenario, OWNER);
        setup(scenario);
    
        next_tx(scenario, OWNER);
        let mut rewards_pool = ts::take_shared<RewardsPool<SUI>>(scenario);
        let amount = 10000;
        let base_coin = coin::mint_for_testing<SUI>(amount, ts::ctx(scenario));
        let mut add_rewards = vector::empty<Coin<SUI>>();
        vector::push_back(&mut add_rewards, base_coin);
        let mut clock = clock::create_for_testing(ts::ctx(scenario));
        clock.increment_for_testing(MS_IN_WEEK);
        let current_epoch = epoch::now(&clock);
        let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
        let mut add_rewards_metadata = vector::empty<ID>();
        vector::push_back(&mut add_rewards_metadata, object::id(&base_metadata));
        rewards_pool::add_rewards(&mut rewards_pool, add_rewards_metadata, add_rewards, current_epoch, ts::ctx(scenario));
        assert!(rewards_pool::reward_store_amount_for_testing(&rewards_pool, 0) == amount, 3);

        let new_shares = rewards_pool::increase_allocation(OWNER, &mut rewards_pool, amount, &clock, ts::ctx(scenario));
        assert!(new_shares == amount, 4);
        let next_shares = rewards_pool::decrease_allocation(OWNER, &mut rewards_pool, amount / 2, &clock, ts::ctx(scenario));
        assert!(next_shares == amount / 2, 5);

        clock::destroy_for_testing(clock);
        ts::return_immutable(base_metadata);
        ts::end(scenario_val);
        rewards_pool
    }

    #[test]
    fun test_claim_rewards(): (RewardsPool<SUI>, vector<Coin<SUI>>) {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        
        next_tx(scenario, OWNER);
        setup(scenario);
    
        next_tx(scenario, OWNER);
        let mut rewards_pool = ts::take_shared<RewardsPool<SUI>>(scenario);
        let amount = 10000;
        let base_coin = coin::mint_for_testing<SUI>(amount, ts::ctx(scenario));
        let mut add_rewards = vector::empty<Coin<SUI>>();
        vector::push_back(&mut add_rewards, base_coin);
        let mut clock = clock::create_for_testing(ts::ctx(scenario));
        clock.increment_for_testing(MS_IN_WEEK);
        let current_epoch = epoch::now(&clock);
        let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
        let mut add_rewards_metadata = vector::empty<ID>();
        vector::push_back(&mut add_rewards_metadata, object::id(&base_metadata));
        rewards_pool::add_rewards(&mut rewards_pool, add_rewards_metadata, add_rewards, current_epoch, ts::ctx(scenario));
        assert!(rewards_pool::reward_store_amount_for_testing(&rewards_pool, 0) == amount, 3);

        let new_shares = rewards_pool::increase_allocation(OWNER, &mut rewards_pool, amount, &clock, ts::ctx(scenario));
        assert!(new_shares == amount, 4);
        let next_shares = rewards_pool::decrease_allocation(OWNER, &mut rewards_pool, amount / 2, &clock, ts::ctx(scenario));
        assert!(next_shares == amount / 2, 5);

        clock::increment_for_testing(&mut clock, MS_IN_WEEK);
        let claimed_rewards = rewards_pool::claim_rewards(OWNER, &mut rewards_pool, current_epoch, &clock, ts::ctx(scenario));
        let claimed_reward_amount = coin::value(vector::borrow(&claimed_rewards, 0));
        assert!(claimed_reward_amount == amount, 6);

        clock::destroy_for_testing(clock);
        ts::return_immutable(base_metadata);
        ts::end(scenario_val);
        (rewards_pool, claimed_rewards)
    }

    #[test]
    fun test_claimable_rewards(): RewardsPool<SUI> {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        
        next_tx(scenario, OWNER);
        setup(scenario);
    
        next_tx(scenario, OWNER);
        let mut rewards_pool = ts::take_shared<RewardsPool<SUI>>(scenario);
        let amount = 100000;
        let base_coin = coin::mint_for_testing<SUI>(amount, ts::ctx(scenario));
        let mut add_rewards = vector::empty<Coin<SUI>>();
        vector::push_back(&mut add_rewards, base_coin);
        let mut clock = clock::create_for_testing(ts::ctx(scenario));
        clock.increment_for_testing(MS_IN_WEEK);
        let current_epoch = epoch::now(&clock);
        let base_metadata = ts::take_immutable<CoinMetadata<SUI>>(scenario);
        let mut add_rewards_metadata = vector::empty<ID>();
        vector::push_back(&mut add_rewards_metadata, object::id(&base_metadata));
        rewards_pool::add_rewards(&mut rewards_pool, add_rewards_metadata, add_rewards, current_epoch, ts::ctx(scenario));
        assert!(rewards_pool::reward_store_amount_for_testing(&rewards_pool, 0) == amount, 7);
        
        let new_shares = rewards_pool::increase_allocation(OWNER, &mut rewards_pool, amount, &clock, ts::ctx(scenario));
        assert!(new_shares == amount, 8);

        let (_, claimable_rewards_amounts) = rewards_pool::claimable_rewards<SUI>(OWNER, &rewards_pool, current_epoch, &clock);
        assert!(vector::borrow(&claimable_rewards_amounts, 0) == amount, 9);

        clock::destroy_for_testing(clock);
        ts::return_immutable(base_metadata);
        ts::end(scenario_val);
        rewards_pool
    }
}