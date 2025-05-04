module sui_dex::rewards_pool {
    use sui::table::{Self, Table};
    use sui::balance::{Self, Balance};
    use sui::clock::Clock;
    use sui::coin::{Self, Coin};

    use sui_dex::epoch;

    // --- errors ---
    const E_SHAREHOLDER_NOT_FOUND: u64 = 1;
    const E_INSUFFICIENT_SHARES: u64 = 2;
    const E_POOL_TOTAL_COINS_OVERFLOW: u64 = 3;
    const E_POOL_TOTAL_SHARES_OVERFLOW: u64 = 4;
    const E_SHAREHOLDER_SHARES_OVERFLOW: u64 = 5;
    const E_INVALID_EPOCH: u64 = 6;
    const E_EXIT_NON_DEFAULT_REWARD_TOKENS: u64 = 7;
    const E_NOT_SHARE_PER_ADDRESS: u64 = 7;

    const MAX_U64: u64 = 18446744073709551615;
    const MAX_U128: u128 = 340282366920938463463374607431768211455;

    // --- structs ---
    // otw
    public struct REWARDS_POOL has drop {}

    public struct AdminCap has key {
        id: UID
    }

    public struct EpochRewards<phantom BaseType> has store {
        reward_tokens: vector<ID>,
        reward_tokens_amounts: vector<u64>,
        non_default_reward_tokens_count: u64,
        pool_total_coins: u64,
        pool_total_shares: u128,
        pool_shares: Table<address, u128>,
    }

    public struct RewardStore<phantom BaseType> has store {
        store: Balance<BaseType>,
    }

    public struct RewardsPool<phantom BaseType> has key, store {
        id: UID,
        epoch_rewards: Table<u64, EpochRewards<BaseType>>,
        reward_stores_tokens: vector<ID>,
        reward_stores: vector<RewardStore<BaseType>>,
        default_reward_tokens: vector<ID>,
    }

    public fun create<BaseType>(mut reward_tokens_list: vector<ID>, ctx: &mut TxContext): ID {
        let mut new_reward_tokens = vector::empty<ID>();
        let mut new_reward_stores = vector::empty<RewardStore<BaseType>>();
        let rewards_pool_id = object::new(ctx);

        vector::reverse<ID>(&mut reward_tokens_list);
        let mut reward_tokens_length = vector::length<ID>(&reward_tokens_list);
        while(reward_tokens_length > 0) {
            let reward_token = vector::pop_back<ID>(&mut reward_tokens_list);
            let reward_store = RewardStore<BaseType> {
                store: balance::zero<BaseType>(),
            };
            vector::push_back<ID>(&mut new_reward_tokens, reward_token);
            vector::push_back<RewardStore<BaseType>>(&mut new_reward_stores, reward_store);
            reward_tokens_length = reward_tokens_length - 1;
        };
        vector::destroy_empty<ID>(reward_tokens_list);
        let rewards_pool = RewardsPool<BaseType> {
            id: rewards_pool_id,
            epoch_rewards: table::new<u64, EpochRewards<BaseType>>(ctx),
            reward_stores_tokens: new_reward_tokens,
            reward_stores: new_reward_stores,
            default_reward_tokens: vector::empty<ID>(),
        };

        let pool_id = object::id(&rewards_pool);
        transfer::share_object(rewards_pool);
        pool_id
    }

    fun is_in_vector<T>(data_vector: &vector<T>, element: &T): (bool, u64) {
        let mut index = 0;
        while(index <= vector::length<T>(data_vector)) {
            let el = vector::borrow<T>(data_vector, index);
            if(el == element) {
                return (true, index)
            };
            index = index + 1;
        };
        (false, 0)
    }

    public fun add_rewards<BaseType>(rewards_pool: &mut RewardsPool<BaseType>, mut add_rewards_metadata: vector<ID>, mut add_rewards: vector<Coin<BaseType>>, epoch_id: u64, ctx: &mut TxContext) {
        let default_reward_tokens = &rewards_pool.default_reward_tokens;
        vector::reverse<ID>(&mut add_rewards_metadata);
        vector::reverse<Coin<BaseType>>(&mut add_rewards);
        let mut length = vector::length<Coin<BaseType>>(&add_rewards);
        while(length > 0) {
            if(coin::value(vector::borrow<Coin<BaseType>>(&add_rewards, vector::length<Coin<BaseType>>(&add_rewards) - 1)) == 0) {
                coin::destroy_zero(vector::pop_back<Coin<BaseType>>(&mut add_rewards));
            } else {
                let (epoch_rewards, reward_stores_tokens, reward_stores) = (
                    &mut rewards_pool.epoch_rewards,
                    &mut rewards_pool.reward_stores_tokens,
                    &mut rewards_pool.reward_stores,
                );
                if(!table::contains<u64, EpochRewards<BaseType>>(epoch_rewards, epoch_id)) {
                    let new_epoch_rewards = EpochRewards<BaseType> {
                        reward_tokens: vector::empty<ID>(),
                        reward_tokens_amounts: vector::empty<u64>(),
                        non_default_reward_tokens_count: 0,
                        pool_total_coins: 0,
                        pool_total_shares: 0,
                        pool_shares: table::new<address, u128>(ctx),
                    };
                    table::add<u64, EpochRewards<BaseType>>(epoch_rewards, epoch_id, new_epoch_rewards);
                };
                let epoch_reward_one = table::borrow_mut<u64, EpochRewards<BaseType>>(epoch_rewards, epoch_id);
                let reward_tokens = &mut epoch_reward_one.reward_tokens;
                let reward_tokens_amounts = &mut epoch_reward_one.reward_tokens_amounts;
                let add_metadata = vector::pop_back<ID>(&mut add_rewards_metadata);

                if(!vector::contains<ID>(reward_tokens, &add_metadata)) {
                    if(!vector::contains<ID>(default_reward_tokens, &add_metadata)) {
                        let non_default_reward_tokens_count = &mut epoch_reward_one.non_default_reward_tokens_count;
                        assert!(*non_default_reward_tokens_count < 15, E_EXIT_NON_DEFAULT_REWARD_TOKENS);
                        *non_default_reward_tokens_count = *non_default_reward_tokens_count + 1;
                    };
                    vector::push_back<ID>(reward_tokens, add_metadata);
                    vector::push_back<u64>(reward_tokens_amounts, 0);
                };

                if(!vector::contains<ID>(reward_stores_tokens, &add_metadata)) {
                    let reward_store = RewardStore {
                        store: balance::zero<BaseType>(),
                    };
                    vector::push_back<ID>(reward_stores_tokens, add_metadata);
                    vector::push_back<RewardStore<BaseType>>(reward_stores, reward_store);
                };
                let (_, mut pos) = is_in_vector<ID>(reward_stores_tokens, &add_metadata);
                let add_reward = vector::pop_back<Coin<BaseType>>(&mut add_rewards);
                let reward_store = vector::borrow_mut<RewardStore<BaseType>>(reward_stores, pos);
                let store = &mut reward_store.store;
                let add_reward_amount = coin::value(&add_reward);
                balance::join<BaseType>(store, coin::into_balance(add_reward));

                (_, pos) = is_in_vector<ID>(reward_tokens, &add_metadata);
                let total_amount = vector::borrow_mut(reward_tokens_amounts, pos);
                *total_amount = *total_amount + add_reward_amount;
            };
            length = length - 1;
        };
        vector::destroy_empty<Coin<BaseType>>(add_rewards);
        vector::destroy_empty<ID>(add_rewards_metadata);
    }

    public fun claim_rewards<BaseType>(user_address: address, rewards_pool: &mut RewardsPool<BaseType>, epoch_id: u64, clock: &Clock, ctx: &mut TxContext): vector<Coin<BaseType>> {
        assert!(epoch_id < epoch::now(clock), E_INVALID_EPOCH);
        let epoch_reward_one = table::borrow_mut<u64, EpochRewards<BaseType>>(&mut rewards_pool.epoch_rewards, epoch_id);
        let reward_tokens = &mut epoch_reward_one.reward_tokens;
        let reward_tokens_amounts = &mut epoch_reward_one.reward_tokens_amounts;
        let reward_stores_tokens = &rewards_pool.reward_stores_tokens;
        let reward_stores = &mut rewards_pool.reward_stores;
        let mut claimed_assets = vector::empty<Coin<BaseType>>();
        vector::reverse<ID>(reward_tokens);
        vector::reverse<u64>(reward_tokens_amounts);
        let mut reward_tokens_length = vector::length<u64>(reward_tokens_amounts);
        let shares = table::borrow<address, u128>(&epoch_reward_one.pool_shares, user_address);
        while(reward_tokens_length > 0) {
            let reward_token_amount = vector::pop_back<u64>(reward_tokens_amounts);
            let rewards_amount = reward_token_amount * (*shares as u64) / (epoch_reward_one.pool_total_shares as u64);
            let reward_token = vector::pop_back<ID>(reward_tokens);
            let (_, pos) = is_in_vector(reward_stores_tokens, &reward_token);
            let reward_store = vector::borrow_mut<RewardStore<BaseType>>(reward_stores, pos);
            let store = &reward_store.store;
            if(rewards_amount == 0) {
                vector::push_back<Coin<BaseType>>(&mut claimed_assets, coin::zero<BaseType>(ctx));
            } else {
                vector::push_back<Coin<BaseType>>(&mut claimed_assets, coin::take(&mut reward_store.store, balance::value(store), ctx));
            };
            reward_tokens_length = reward_tokens_length - 1;
        };
        
        let redeemed_coins;
        if(epoch_reward_one.pool_total_coins == 0 || epoch_reward_one.pool_total_shares == 0) {
            redeemed_coins = 0;
        } else {
            redeemed_coins = (*shares as u64) * epoch_reward_one.pool_total_coins / (epoch_reward_one.pool_total_shares as u64);
        };
        epoch_reward_one.pool_total_coins = epoch_reward_one.pool_total_coins - redeemed_coins;
        epoch_reward_one.pool_total_shares = epoch_reward_one.pool_total_shares - (*shares as u128);
        table::remove(&mut epoch_reward_one.pool_shares, user_address);
        claimed_assets
    }

    public fun default_reward_tokens<BaseType>(rewards_pool: &RewardsPool<BaseType>): &vector<ID> {
        &rewards_pool.default_reward_tokens
    }

    public fun claimer_shares<BaseType>(user_address: address, rewards_pool: &RewardsPool<BaseType>, epoch_id: u64): (u64, u64) {
        let epoch_reward = table::borrow<u64, EpochRewards<BaseType>>(&rewards_pool.epoch_rewards, epoch_id);
        (*table::borrow<address, u128>(&epoch_reward.pool_shares, user_address) as u64 , epoch_reward.pool_total_shares as u64)
    }

    public fun total_rewards<BaseType>(rewards_pool: &RewardsPool<BaseType>, epoch_id: u64): (vector<ID>, vector<u64>) {
        if(!table::contains<u64, EpochRewards<BaseType>>(&rewards_pool.epoch_rewards, epoch_id)) {
            return (vector::empty<ID>(), vector::empty<u64>())
        };
        (table::borrow<u64, EpochRewards<BaseType>>(&rewards_pool.epoch_rewards, epoch_id).reward_tokens, table::borrow<u64, EpochRewards<BaseType>>(&rewards_pool.epoch_rewards, epoch_id).reward_tokens_amounts)
    }

    public fun reward_tokens<BaseType>(rewards_pool: &RewardsPool<BaseType>, epoch_id: u64): vector<ID> {
        table::borrow<u64, EpochRewards<BaseType>>(&rewards_pool.epoch_rewards, epoch_id).reward_tokens
    }

    public fun decrease_allocation<BaseType>(user_address: address, rewards_pool: &mut RewardsPool<BaseType>, amount: u64, clock: &Clock, ctx: &mut TxContext): u64 {
        let current_epoch = epoch::now(clock);
        if(!table::contains<u64, EpochRewards<BaseType>>(&rewards_pool.epoch_rewards, current_epoch)) {
            let new_epoch_reward = EpochRewards {
                reward_tokens: vector::empty<ID>(),
                reward_tokens_amounts: vector::empty<u64>(),
                non_default_reward_tokens_count: 0,
                pool_total_coins: 0,
                pool_total_shares: 0,
                pool_shares: table::new<address, u128>(ctx),
            };
            table::add<u64, EpochRewards<BaseType>>(&mut rewards_pool.epoch_rewards, current_epoch, new_epoch_reward);
        };
        let epoch_reward = table::borrow_mut<u64, EpochRewards<BaseType>>(&mut rewards_pool.epoch_rewards, current_epoch);
        assert!(table::contains<address, u128>(&epoch_reward.pool_shares, user_address), E_SHAREHOLDER_NOT_FOUND);
        let shares = table::borrow_mut<address, u128>(&mut epoch_reward.pool_shares, user_address);
        assert!(*shares >= amount as u128, E_INSUFFICIENT_SHARES);
        if(amount == 0) return 0;
        let redeemed_coins;
        if(epoch_reward.pool_total_coins == 0 || epoch_reward.pool_total_shares == 0) {
            redeemed_coins = 0;
        } else {
            redeemed_coins = amount * epoch_reward.pool_total_coins / (epoch_reward.pool_total_shares as u64);
        };
        epoch_reward.pool_total_coins = epoch_reward.pool_total_coins - redeemed_coins;
        epoch_reward.pool_total_shares = epoch_reward.pool_total_shares - (amount as u128);
        *shares = *shares - (amount as u128);
        let remaining_shares = *shares;
        if (remaining_shares == 0) {
            table::remove(&mut epoch_reward.pool_shares, user_address);
        };
        redeemed_coins
    }

    public fun increase_allocation<BaseType>(user_address: address, rewards_pool: &mut RewardsPool<BaseType>, amount: u64, clock: &Clock, ctx: &mut TxContext): u64 {
        let current_epoch = epoch::now(clock);
        if(!table::contains<u64, EpochRewards<BaseType>>(&rewards_pool.epoch_rewards, current_epoch)) {
            let new_epoch_reward = EpochRewards {
                reward_tokens: vector::empty<ID>(),
                reward_tokens_amounts: vector::empty<u64>(),
                non_default_reward_tokens_count: 0,
                pool_total_coins: 0,
                pool_total_shares: 0,
                pool_shares: table::new<address, u128>(ctx),
            };
            table::add<u64, EpochRewards<BaseType>>(&mut rewards_pool.epoch_rewards, current_epoch, new_epoch_reward);
        };
        let epoch_reward = table::borrow_mut<u64, EpochRewards<BaseType>>(&mut rewards_pool.epoch_rewards, current_epoch);
        if(amount == 0) return 0;
        let new_shares;

        if(epoch_reward.pool_total_coins == 0 || epoch_reward.pool_total_shares == 0) {
            new_shares = amount;
        } else {
            new_shares = amount * (epoch_reward.pool_total_shares as u64) / epoch_reward.pool_total_coins;
        };
        assert!(MAX_U64 - epoch_reward.pool_total_coins >= amount, E_POOL_TOTAL_COINS_OVERFLOW);
        assert!(MAX_U128 - epoch_reward.pool_total_shares >= new_shares as u128, E_POOL_TOTAL_SHARES_OVERFLOW);
        epoch_reward.pool_total_coins = epoch_reward.pool_total_coins + amount;
        epoch_reward.pool_total_shares = epoch_reward.pool_total_shares + (new_shares as u128);

        if(table::contains<address, u128>(&epoch_reward.pool_shares, user_address)) {
            let shares = table::borrow_mut<address, u128>(&mut epoch_reward.pool_shares, user_address);
            assert!(MAX_U128 - *shares >= new_shares as u128, E_SHAREHOLDER_SHARES_OVERFLOW);
            *shares = *shares + (new_shares as u128);
        } else if(new_shares > 0) {
            table::add(&mut epoch_reward.pool_shares, user_address, new_shares as u128);
        };
        new_shares
    }

    public fun claimable_rewards<BaseType>(user_address: address, rewards_pool: &RewardsPool<BaseType>, epoch_id: u64, clock: &Clock): (vector<ID>, vector<u64>) {
        assert!(epoch_id <= epoch::now(clock), E_INVALID_EPOCH);
        let epoch_reward = table::borrow<u64, EpochRewards<BaseType>>(&rewards_pool.epoch_rewards, epoch_id);
        let mut claimable_rewards_amounts = vector::empty<u64>();
        let mut index = 0;
        let shares;
        assert!(table::contains<address, u128>(&epoch_reward.pool_shares, user_address), E_NOT_SHARE_PER_ADDRESS); 
        shares = table::borrow<address, u128>(&epoch_reward.pool_shares, user_address);
        while(index < vector::length<u64>(&epoch_reward.reward_tokens_amounts)) {
            let rewards = *vector::borrow<u64>(&epoch_reward.reward_tokens_amounts, index) * (*shares as u64) / (epoch_reward.pool_total_shares as u64);
            vector::push_back<u64>(&mut claimable_rewards_amounts, rewards);
            index = index + 1;
        };
        (reward_tokens(rewards_pool, epoch_id), claimable_rewards_amounts)
    }

    #[test_only]
    public fun reward_stores_tokens_for_testing<BaseType>(rewards_pool: &RewardsPool<BaseType>): vector<ID> {
       rewards_pool.reward_stores_tokens
    }

    #[test_only]
    public fun reward_store_amount_for_testing<BaseType>(rewards_pool: &RewardsPool<BaseType>, index: u64): u64 {
       balance::value(&vector::borrow(&rewards_pool.reward_stores, index).store)
    }

}