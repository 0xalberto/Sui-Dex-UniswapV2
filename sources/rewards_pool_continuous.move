module sui_dex::rewards_pool_continuous {
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::balance::{Self, Balance};
    use sui_dex::suidex_token::{SUIDEX_TOKEN};
    
    // --- errors ---
    const E_INSUFFICIENT_BALANCE: u64 = 1;
    const E_MIN_LOCK_TIME: u64 = 2;
    const E_MAX_LOCK_TIME: u64 = 3;
    const E_NOT_OWNER: u64 = 4;
    const E_ZERO_TOTAL_POWER: u64 = 14;

    // --- structs ---

    public struct RewardsPool has key, store {
        id: UID,
        rewards_balance: Balance<SUIDEX_TOKEN>,
        reward_per_token_stored: u128,
        user_reward_per_token_paid: Table<address, u128>,
        last_update_time: u64,
        reward_rate: u128,
        reward_duration: u64,
        reward_period_finish: u64,
        rewards: Table<address, u64>,
        total_stake: u128,
        stakes: Table<address, u64>,
    }

    #[allow(unused_variable)]
    public fun add_rewards(pool: &mut RewardsPool, balance: Balance<SUIDEX_TOKEN>, clock: &Clock) {
        // Update the rewards for the pool
        update_reward(@0x0, pool, clock);
        
        // Get the balance amount
        let asset_amount = balance::value(&balance);
        let updated_amount = balance::join(&mut pool.rewards_balance, balance);
        // Deposit the asset into the rewards pool
        // transfer::public_transfer<SUIDEX_TOKEN>(updated_balance, @0x1);
        // Get the current time
        let current_time = clock::timestamp_ms(clock);
        
        // Borrow mutable reference to the rewards pool
        let pool_ref = pool;
        
        // Calculate the pending reward
        let pending_reward = if (pool_ref.reward_period_finish > current_time) {
            pool_ref.reward_rate * ((pool_ref.reward_period_finish - current_time) as u128)
        } else {
            0
        };
        
        // Update the reward rate and period finish
        pool_ref.reward_rate = (pending_reward + (asset_amount as u128) * 100000000) / (pool_ref.reward_duration as u128);
        pool_ref.reward_period_finish = current_time + pool_ref.reward_duration;
        pool_ref.last_update_time = current_time;
    }

    public fun claim_rewards(user_address: address, pool: &mut RewardsPool, clock: &Clock) : Balance<SUIDEX_TOKEN> {
        update_reward(user_address, pool, clock);
        let pool_ref = pool;
        let default_reward_value = 0;
        let user_reward_amount = default_reward_value + *table::borrow(&pool_ref.rewards, user_address);
        assert!(user_reward_amount > 0, E_MAX_LOCK_TIME);
        table::remove<address, u64>(&mut pool_ref.rewards, user_address);
        let user_rewards_blance = balance::split(&mut pool.rewards_balance, user_reward_amount);
        user_rewards_blance
    }

    fun claimable_internal(user_address: address, pool_ref: &mut RewardsPool, clock: &Clock) : u64 {
        let _default_stake_value = 0;
        let _default_reward_value = 0;
        let scale_factor = 100000000;
        assert!(scale_factor != 0, E_ZERO_TOTAL_POWER);
        let _user_rewards = 0;

        if (!table::contains(&pool_ref.stakes, user_address)) {
            table::add(&mut pool_ref.stakes, user_address, 0);
        };

        if (!table::contains(&pool_ref.user_reward_per_token_paid, user_address)) {
            table::add(&mut pool_ref.user_reward_per_token_paid, user_address, 0);
        };

        if (!table::contains(&pool_ref.rewards, user_address)) {
            table::add(&mut pool_ref.rewards, user_address, 0);
        };

        (((((*table::borrow(&pool_ref.stakes, user_address) as u128) as u256) * ((reward_per_token_internal(pool_ref, clock) - *table::borrow(&pool_ref.user_reward_per_token_paid, user_address)) as u256) / (scale_factor as u256)) as u128) as u64) + *table::borrow(&pool_ref.rewards, user_address)
    }

    public fun claimable_rewards(user_address: address, pool: &mut RewardsPool, clock: &Clock) : u64 {
        claimable_internal(user_address, pool, clock)
    }

    public fun create(duration: u64, ctx: &mut TxContext): RewardsPool {
        assert!(duration > 0, E_NOT_OWNER);
        let new_rewards_pool = RewardsPool {
            id: object::new(ctx),
            rewards_balance: balance::zero<SUIDEX_TOKEN>(),
            reward_per_token_stored    : 0,
            user_reward_per_token_paid : table::new<address, u128>(ctx),
            last_update_time           : 0,
            reward_rate                : 0,
            reward_duration            : duration,
            reward_period_finish       : 0,
            rewards                    : table::new<address, u64>(ctx),
            total_stake                : 0,
            stakes                     : table::new<address, u64>(ctx),
        };
        transfer::share_object(new_rewards_pool);
        let new_rewards_pool = RewardsPool {
            id: object::new(ctx),
            rewards_balance: balance::zero<SUIDEX_TOKEN>(),
            reward_per_token_stored    : 0,
            user_reward_per_token_paid : table::new<address, u128>(ctx),
            last_update_time           : 0,
            reward_rate                : 0,
            reward_duration            : duration,
            reward_period_finish       : 0,
            rewards                    : table::new<address, u64>(ctx),
            total_stake                : 0,
            stakes                     : table::new<address, u64>(ctx),
        };
        new_rewards_pool
    }

    public fun current_reward_period_finish(pool: &RewardsPool) : u64 {
        pool.reward_period_finish
    }

    public fun reward_per_token(pool: &RewardsPool, clock: &Clock) : u128 {
        reward_per_token_internal(pool, clock)
    }

    fun reward_per_token_internal(pool_ref: &RewardsPool, clock: &Clock) : u128 {
        let stored_reward = pool_ref.reward_per_token_stored;
        let mut adjusted_reward = stored_reward;
        let total_stake_amount = pool_ref.total_stake;
        if (total_stake_amount > 0) {
            assert!(total_stake_amount != 0, E_ZERO_TOTAL_POWER);
            adjusted_reward = stored_reward + (((((std::u64::min(clock::timestamp_ms(clock), pool_ref.reward_period_finish) - pool_ref.last_update_time) as u128) as u256) * (pool_ref.reward_rate as u256) / (total_stake_amount as u256)) as u128);
        };
        adjusted_reward
    }

    public fun reward_rate(pool: &RewardsPool) : u128 {
        pool.reward_rate / 100000000
    }


    public fun stake(user_address: address, pool: &mut RewardsPool, stake_amount: u64, clock: &Clock) {
        update_reward(user_address, pool, clock);
        let pool_ref = pool;
        let user_stake_amount = table::borrow_mut<address, u64>(&mut pool_ref.stakes, user_address);
        *user_stake_amount = *user_stake_amount + stake_amount;
        pool_ref.total_stake = pool_ref.total_stake + (stake_amount as u128);
    }

    public fun stake_balance(user_address: address, pool: &mut RewardsPool): u64 {
        *table::borrow<address, u64>(&pool.stakes, user_address)
    }

    public fun total_stake(pool: &RewardsPool) : u128 {
        pool.total_stake
    }

    public fun total_unclaimed_rewards(pool: &RewardsPool) : u64 {
        balance::value(&pool.rewards_balance)
    }

    public fun unstake(user_address: address, pool: &mut RewardsPool, stake_amount: u64, clock: &Clock) {
        update_reward(user_address, pool, clock);
        let pool_ref = pool;
        assert!(table::contains<address, u64>(&pool_ref.stakes, user_address), E_MIN_LOCK_TIME);
        let user_stake_amount = table::borrow_mut<address, u64>(&mut pool_ref.stakes, user_address);
        assert!(stake_amount > 0 && stake_amount <= *user_stake_amount, E_INSUFFICIENT_BALANCE);
        *user_stake_amount = *user_stake_amount - stake_amount;
        pool_ref.total_stake = pool_ref.total_stake - (stake_amount as u128);
        if (*user_stake_amount == 0) {
            table::remove<address, u64>(&mut pool_ref.stakes, user_address);
            table::remove<address, u128>(&mut pool_ref.user_reward_per_token_paid, user_address);
        };
    }

    public fun update_reward(user_address: address, pool: &mut RewardsPool, clock: &Clock) {
        // Borrow mutable reference to the rewards pool
        let pool_ref = pool;
        
        // Update the reward per token stored
        pool_ref.reward_per_token_stored = reward_per_token_internal(pool_ref,  clock);
        
        // Update the last update time
        pool_ref.last_update_time = std::u64::min(clock::timestamp_ms(clock), pool_ref.reward_period_finish);
        
        // Get the claimable amount for the user
        if(user_address != @0x0) {
            let claimable_amount = claimable_internal(user_address, pool_ref, clock);
            // If there is a claimable amount, update the rewards table
            if (claimable_amount > 0) {
                table::remove(&mut pool_ref.rewards, user_address);
                table::add(&mut pool_ref.rewards, user_address, claimable_amount);
            };
            
            // Update the user reward per token paid
            table::remove(&mut pool_ref.user_reward_per_token_paid, user_address);
            table::add(&mut pool_ref.user_reward_per_token_paid, user_address, pool_ref.reward_per_token_stored);
        }
    }

    #[test_only]
    public fun add_rewards_test(pool: &mut RewardsPool, balance: Balance<SUIDEX_TOKEN>, clock: &Clock) {
        add_rewards(pool, balance, clock);
    }

    #[test_only]
    public fun create_test(duration: u64, ctx: &mut TxContext): RewardsPool { 
        create(duration, ctx)
    }

    #[test_only]
    public fun stake_test(user_address: address, pool: &mut RewardsPool, stake_amount: u64, clock: &Clock) {
        stake(user_address, pool, stake_amount, clock);
    }

    #[test_only]
    public fun claim_rewards_test(user_address: address, pool: &mut RewardsPool, clock: &Clock) : Balance<SUIDEX_TOKEN> {
        claim_rewards(user_address, pool, clock)
    }

    #[test_only]
    public fun unstake_test(user_address: address, pool: &mut RewardsPool, stake_amount: u64, clock: &Clock) {
        unstake(user_address, pool, stake_amount, clock);
    }
}