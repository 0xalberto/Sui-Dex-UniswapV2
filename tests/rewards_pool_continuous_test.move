#[test_only]
module sui_dex::rewards_pool_continuous_tests {
    use sui::test_scenario::{Self as ts, next_tx};
    use sui::coin;
    use sui::clock;
    use std::debug;
    use sui::balance;
    use sui_dex::suidex_token::{SUIDEX_TOKEN};
    use sui_dex::rewards_pool_continuous::{Self, RewardsPool};
    use sui::test_utils;

    // --- addresses ---
    const OWNER : address = @0xab;
    const MS_IN_WEEK: u64 = 604800000; // milliseconds in a week

    fun setup() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;

        let rewards_pool = rewards_pool_continuous::create(604800000 * 5, scenario.ctx());
        transfer::public_transfer(rewards_pool, @0x01);
        ts::end(scenario_val);
    }

    #[test]
    public fun add_rewards_test() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        next_tx(scenario, OWNER);
        {
            let _mint_amount = 1000;
            let mut rewards_pool = ts::take_shared<RewardsPool>(scenario);
            let rewards_token = coin::mint_for_testing<SUIDEX_TOKEN>(_mint_amount, ts::ctx(scenario));
            let rewards_balance = coin::into_balance<SUIDEX_TOKEN>(rewards_token);
            let clock = clock::create_for_testing(ts::ctx(scenario));

            rewards_pool_continuous::add_rewards_test(&mut rewards_pool, rewards_balance, &clock);

            assert!(rewards_pool_continuous::total_unclaimed_rewards(&rewards_pool) == 1000, 2);
            // debug::print(&rewards_pool);

            clock.destroy_for_testing();
            ts::return_shared(rewards_pool);
        };

        ts::end(scenario_val);
    }

    #[test]
    public fun stake_test() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        next_tx(scenario, OWNER);
        {

            let _mint_amount = 1000;
            let mut rewards_pool = ts::take_shared<RewardsPool>(scenario);
            let rewards_token = coin::mint_for_testing<SUIDEX_TOKEN>(_mint_amount, ts::ctx(scenario));
            let rewards_balance = coin::into_balance<SUIDEX_TOKEN>(rewards_token);
            let mut clock = clock::create_for_testing(ts::ctx(scenario));
            let test_addr = @0x123;
            clock.increment_for_testing(MS_IN_WEEK);

            rewards_pool_continuous::add_rewards_test(&mut rewards_pool, rewards_balance, &clock);

            assert!(rewards_pool_continuous::total_unclaimed_rewards(&rewards_pool) == 1000, 2);            

            clock.increment_for_testing(MS_IN_WEEK);

            rewards_pool_continuous::stake_test(test_addr, &mut rewards_pool, 1000, &clock);

            assert!(rewards_pool_continuous::total_stake(&rewards_pool) == 1000, 1);

            clock.increment_for_testing(MS_IN_WEEK);
            assert!(rewards_pool_continuous::claimable_rewards(test_addr,&mut rewards_pool, &clock) == 199, 1);

            clock.destroy_for_testing();
            ts::return_shared(rewards_pool);
        };
        ts::end(scenario_val);
    }
    
    #[test]
    public fun unstake_test() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        next_tx(scenario, OWNER);
        {
            let mut rewards_pool = ts::take_shared<RewardsPool>(scenario);
            let clock = clock::create_for_testing(ts::ctx(scenario));
            let test_addr = @0x123;

            rewards_pool_continuous::stake_test(test_addr, &mut rewards_pool, 1000, &clock);
            rewards_pool_continuous::unstake_test(test_addr, &mut rewards_pool, 1000, &clock);

            assert!(rewards_pool_continuous::total_stake(&rewards_pool) == 0, 1);
            assert!(rewards_pool_continuous::claimable_rewards(test_addr,&mut rewards_pool, &clock) == 0, 1);

            clock.destroy_for_testing();
            ts::return_shared(rewards_pool);
        };
        ts::end(scenario_val);
    }

    #[test]
    public fun claim_rewards_test() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        next_tx(scenario, OWNER);
        {
            let _mint_amount = 1000;
            let mut rewards_pool = ts::take_shared<RewardsPool>(scenario);
            let rewards_token = coin::mint_for_testing<SUIDEX_TOKEN>(_mint_amount, ts::ctx(scenario));
            let rewards_balance = coin::into_balance<SUIDEX_TOKEN>(rewards_token);
            let mut clock = clock::create_for_testing(ts::ctx(scenario));
            let test_addr = @0x123;
            clock.increment_for_testing(MS_IN_WEEK);

            rewards_pool_continuous::add_rewards_test(&mut rewards_pool, rewards_balance, &clock);

            assert!(rewards_pool_continuous::total_unclaimed_rewards(&rewards_pool) == 1000, 2);            

            clock.increment_for_testing(MS_IN_WEEK);

            rewards_pool_continuous::stake_test(test_addr, &mut rewards_pool, 1000, &clock);

            assert!(rewards_pool_continuous::total_stake(&rewards_pool) == 1000, 1);

            clock.increment_for_testing(MS_IN_WEEK);

            rewards_pool_continuous::stake_test(test_addr, &mut rewards_pool, 1000, &clock);
            assert!(rewards_pool_continuous::total_stake(&rewards_pool) == 2000, 1);
            
            clock.increment_for_testing(MS_IN_WEEK);

            assert!(rewards_pool_continuous::claimable_rewards(test_addr,&mut rewards_pool, &clock) == 398, 1);

            let rewards_balance = rewards_pool_continuous::claim_rewards_test(test_addr, &mut rewards_pool, &clock);

            assert!(rewards_pool_continuous::claimable_rewards(test_addr,&mut rewards_pool, &clock) == 0, 1);
            assert!(balance::value<SUIDEX_TOKEN>(&rewards_balance) == 398, 1);

                        rewards_pool_continuous::stake_test(test_addr, &mut rewards_pool, 1000, &clock);
            assert!(rewards_pool_continuous::total_stake(&rewards_pool) == 3000, 1);
            
            clock.increment_for_testing(MS_IN_WEEK);

            assert!(rewards_pool_continuous::claimable_rewards(test_addr,&mut rewards_pool, &clock) == 199, 1);

            let rewards_balance_second = rewards_pool_continuous::claim_rewards_test(test_addr, &mut rewards_pool, &clock);

            assert!(rewards_pool_continuous::claimable_rewards(test_addr,&mut rewards_pool, &clock) == 0, 1);
            assert!(balance::value<SUIDEX_TOKEN>(&rewards_balance_second) == 199, 1);
            
            test_utils::destroy(rewards_balance);
            test_utils::destroy(rewards_balance_second);
            clock.destroy_for_testing();

            ts::return_shared(rewards_pool);
        };
        ts::end(scenario_val);
    }
}