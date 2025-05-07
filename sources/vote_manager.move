module sui_dex::vote_manager {
    use std::ascii::String;
    use std::string;
    use sui::table::{Self, Table};
    use sui::table_vec::{TableVec};
    use sui::vec_map::{Self, VecMap};
    use sui::coin::{Self, Coin, CoinMetadata};
    use sui::dynamic_object_field;
    use sui::clock::Clock;
    use sui::bag::{Self, Bag};
    use sui::object_bag::{Self, ObjectBag};
    use sui::object_table::{Self, ObjectTable};
    use std::debug;

    use sui_dex::voting_escrow::{Self, VeSuiDexToken, VeSuiDexCollection};
    use sui_dex::suidex_token::{Self, SUIDEX_TOKEN, SuiDexManager};
    use sui_dex::coin_wrapper::{Self, WrapperStore, COIN_WRAPPER, WrapperStoreCap};
    use sui_dex::token_whitelist::{Self, TokenWhitelist, TokenWhitelistAdminCap, RewardTokenWhitelistPerPool};
    use sui_dex::gauge::{Self, Gauge};
    use sui_dex::epoch;
    use sui_dex::minter::{Self, MinterConfig};
    use sui_dex::liquidity_pool::{Self, LiquidityPool, LiquidityPoolConfigs};
    use sui_dex::rewards_pool::{Self, RewardsPool};
    //use sui_dex::rewards_pool_continuous::{RewardsPool};

    // --- errors ---
    const E_GAUGE_INACTIVE: u64 = 1;
    const E_NOT_OWNER: u64 = 2;
    const E_INVALID_COIN: u64 = 3;
    const E_VECTOR_LENGTH_MISMATCH: u64 = 4;
    const E_NOT_OPERATOR: u64 = 5;
    const E_GAUGE_NOT_EXISTS: u64 = 6;
    const E_REWARD_TOKEN_NOT_WHITELISTED: u64 = 7;
    const E_TOKENS_RECENTLY_VOTED: u64 = 8;
    const E_NO_VOTES_FOR_TOKEN: u64 = 9;
    const E_NFT_EXISTS: u64 = 10;
    const E_ALREADY_VOTED_THIS_EPOCH: u64 = 11;
    const E_RECENTLY_VOTED: u64 = 12;
    const E_NOT_GOVERNANCE: u64 = 13;
    const E_ZERO_TOTAL_WEIGHT: u64 = 14;
    const E_GAUGE_NOT_FOUND: u64 = 15;
    const E_GAUGE_ALREADY_ACTIVE: u64 = 16;
    const E_WRONG_REWARD_POOL:u64 = 17;
    const E_WRONG_GAUGE: u64 = 18;

    // --- structs ---
    // otw
    public struct VOTE_MANAGER has drop {}

    public struct AdministrativeData has key {
        id: UID,
        gauges: Bag,
        active_gauges: Table<ID, bool>,
        active_gauges_list: vector<ID>,
        pool_to_gauge: Table<ID, ID>,
        gauge_to_fees_pool: Table<ID, ID>,
        gauge_to_incentive_pool: Table<ID, ID>,
        operator: address,
        governance: address,
        pending_distribution_epoch: u64,
    }

    public struct NullCoin {
        dummy_field: bool,
    }

    public struct VeTokenVoteAccounting has key {
        id: UID,
        votes_for_pools_by_ve_token: Table<ID, VecMap<ID, u64>>,
        last_voted_epoch: Table<ID, u64>,
    }

    public struct GaugeVoteAccounting has key {
        id: UID,
        total_votes: u128,
        votes_for_gauges: VecMap<ID, u128>
    }

    public struct VoteManagerAdminCap has key { 
        id: UID 
    }

    // --- Initialize function ---
    fun init(_otw: VOTE_MANAGER, ctx: &mut TxContext) {
        let admin_cap = VoteManagerAdminCap {
            id: object::new(ctx)
        };

        let administrative_data = AdministrativeData {
            id: object::new(ctx),
            gauges: bag::new(ctx),
            active_gauges: table::new(ctx),
            active_gauges_list: vector::empty(),
            pool_to_gauge: table::new(ctx),
            gauge_to_fees_pool: table::new(ctx),
            gauge_to_incentive_pool: table::new(ctx),
            operator: tx_context::sender(ctx),
            governance: tx_context::sender(ctx),
            pending_distribution_epoch: 0,
        };

        let ve_token_vote_accounting = VeTokenVoteAccounting {
            id: object::new(ctx),
            votes_for_pools_by_ve_token: table::new(ctx),
            last_voted_epoch: table::new(ctx),
        };

        let gauge_vote_accounting = GaugeVoteAccounting {
            id: object::new(ctx),
            total_votes: 0,
            votes_for_gauges: vec_map::empty()
        };

        transfer::share_object(administrative_data);
        transfer::share_object(ve_token_vote_accounting);
        transfer::share_object(gauge_vote_accounting);
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    public entry fun claim_rewards<BaseType, T0, T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13, T14>(
        ve_token: &VeSuiDexToken<SUIDEX_TOKEN>,
        liquidity_pool: ID,
        epoch_id: u64,
        admin_data: &AdministrativeData,
        fees_pool: &mut RewardsPool<BaseType>,
        incentive_pool: &mut RewardsPool<BaseType>,
        wrapper_store: &mut WrapperStore,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let gauge = get_gauge(admin_data, liquidity_pool);
        assert!(is_gauge_active(admin_data, gauge), E_GAUGE_INACTIVE);

        let account_addr = tx_context::sender(ctx);
        assert!(voting_escrow::token_owner(ve_token) == account_addr, E_NOT_OWNER);
        
        let mut rewards = rewards_pool::claim_rewards(account_addr, fees_pool, epoch_id, clock, ctx);
        vector::append(&mut rewards, rewards_pool::claim_rewards(account_addr, incentive_pool, epoch_id, clock, ctx));
        
        let mut valid_coins = vector::empty<String>();
        add_valid_coin<T0>(&mut valid_coins);
        add_valid_coin<T1>(&mut valid_coins);
        add_valid_coin<T2>(&mut valid_coins);
        add_valid_coin<T3>(&mut valid_coins);
        add_valid_coin<T4>(&mut valid_coins);
        add_valid_coin<T5>(&mut valid_coins);
        add_valid_coin<T6>(&mut valid_coins);
        add_valid_coin<T7>(&mut valid_coins);
        add_valid_coin<T8>(&mut valid_coins);
        add_valid_coin<T9>(&mut valid_coins);
        add_valid_coin<T10>(&mut valid_coins);
        add_valid_coin<T11>(&mut valid_coins);
        add_valid_coin<T12>(&mut valid_coins);
        add_valid_coin<T13>(&mut valid_coins);
        add_valid_coin<T14>(&mut valid_coins);

        vector::reverse(&mut rewards);
        let mut rewards_length = vector::length(&rewards);
        while (rewards_length > 0) {
            let reward = vector::pop_back(&mut rewards);
            if (coin::value(&reward) == 0) {
                coin::destroy_zero(reward);
            } else {
                let metadata_id = object::id(&reward);
                if (coin_wrapper::is_wrapper(wrapper_store, metadata_id)) {
                    let original = coin_wrapper::get_original<BaseType>(wrapper_store, metadata_id);
                    let (found, index) = vector::index_of(&valid_coins, &original);
                    assert!(found, E_INVALID_COIN);

                    let wrapped_coin = coin_wrapper::wrap(wrapper_store, reward, ctx);

                    if (index == 0) { unwrap_and_deposit<T0>(wrapper_store, account_addr, wrapped_coin); }
                    else if (index == 1) { unwrap_and_deposit<T1>(wrapper_store, account_addr, wrapped_coin); }
                    else if (index == 2) { unwrap_and_deposit<T2>(wrapper_store, account_addr, wrapped_coin); }
                    else if (index == 3) { unwrap_and_deposit<T3>(wrapper_store, account_addr, wrapped_coin); }
                    else if (index == 4) { unwrap_and_deposit<T4>(wrapper_store, account_addr, wrapped_coin); }
                    else if (index == 5) { unwrap_and_deposit<T5>(wrapper_store, account_addr, wrapped_coin); }
                    else if (index == 6) { unwrap_and_deposit<T6>(wrapper_store, account_addr, wrapped_coin); }
                    else if (index == 7) { unwrap_and_deposit<T7>(wrapper_store, account_addr, wrapped_coin); }
                    else if (index == 8) { unwrap_and_deposit<T8>(wrapper_store, account_addr, wrapped_coin); }
                    else if (index == 9) { unwrap_and_deposit<T9>(wrapper_store, account_addr, wrapped_coin); }
                    else if (index == 10) { unwrap_and_deposit<T10>(wrapper_store, account_addr, wrapped_coin); }
                    else if (index == 11) { unwrap_and_deposit<T11>(wrapper_store, account_addr, wrapped_coin); }
                    else if (index == 12) { unwrap_and_deposit<T12>(wrapper_store, account_addr, wrapped_coin); }
                    else if (index == 13) { unwrap_and_deposit<T13>(wrapper_store, account_addr, wrapped_coin); }
                    else {
                        assert!(index == 14, E_INVALID_COIN);
                        unwrap_and_deposit<T14>(wrapper_store, account_addr, wrapped_coin);
                    };
                } else {
                    transfer::public_transfer(reward, account_addr);
                };
            };
            rewards_length = rewards_length - 1;
        };
        vector::destroy_empty(rewards);
    }

    public fun get_gauge(
        admin_data: &AdministrativeData,
        liquidity_pool: ID
    ): ID {
        get_gauges(
            admin_data, 
            vector::singleton(liquidity_pool)
        )[0]
    }

    public fun get_gauges(
        admin_data: &AdministrativeData,
        mut liquidity_pools: vector<ID>
    ): vector<ID> {
        let mut gauges = vector::empty();
        vector::reverse(&mut liquidity_pools);
        
        while (!vector::is_empty(&liquidity_pools)) {
            let pool_id = vector::pop_back(&mut liquidity_pools);
            let gauge_id = *table::borrow(&admin_data.pool_to_gauge, pool_id);
            vector::push_back(&mut gauges, gauge_id);
        };

        vector::destroy_empty(liquidity_pools);
        gauges
    }

    public fun is_gauge_active(
        admin_data: &AdministrativeData,
        gauge_id: ID
    ): bool {
        if (table::contains(&admin_data.active_gauges, gauge_id)) {
            *table::borrow(&admin_data.active_gauges, gauge_id)
        } else {
            false
        }
    }

    public fun fees_pool(
        admin_data: &AdministrativeData,
        liquidity_pool: ID
    ): ID {
        let gauge_id = get_gauge(admin_data, liquidity_pool);
        *table::borrow(&admin_data.gauge_to_fees_pool, gauge_id)
    }

    public fun incentive_pool(
        admin_data: &AdministrativeData,
        liquidity_pool: ID
    ): ID {
        let gauge_id = get_gauge(admin_data, liquidity_pool);
        *table::borrow(&admin_data.gauge_to_incentive_pool, gauge_id)
    }

    fun add_valid_coin<T>(coins: &mut vector<String>) {
        let coin_name = coin_wrapper::format_coin<T>();
        if (coin_name != coin_wrapper::format_coin<NullCoin>()) {
            vector::push_back(coins, coin_name);
        };
    }

    fun unwrap_and_deposit<CoinType>(
        wrapper_store: &mut WrapperStore,
        recipient: address,
        coin: Coin<COIN_WRAPPER>
    ) {
        if (coin::value(&coin) > 0) {
            let unwrapped = coin_wrapper::unwrap<CoinType>(wrapper_store, coin);
            transfer::public_transfer(unwrapped, recipient);
        } else {
            coin::destroy_zero(coin);
        };
    }

    public fun whitelist_coin<T>(
        admin_data: &AdministrativeData,
        admin_cap: &TokenWhitelistAdminCap,
        whitelist: &mut TokenWhitelist,
        wrapper_store: &mut WrapperStore,
        wrapper_cap: &WrapperStoreCap,
        otw: COIN_WRAPPER,
        ctx: &mut TxContext
    ) {
        assert!(admin_data.operator == tx_context::sender(ctx), E_NOT_OPERATOR);
        
        token_whitelist::whitelist_coin<T>(admin_cap, whitelist);
        coin_wrapper::register_coin<T>(wrapper_cap, otw, wrapper_store, ctx);
        
        let mut tokens = vector::empty<String>();
        vector::push_back(&mut tokens, coin_wrapper::format_coin<T>());
    }

    public fun claimable_rewards<BaseType>(
        ve_token: &VeSuiDexToken<SUIDEX_TOKEN>,
        rewards_pool: &RewardsPool<BaseType>,
        incentive_pool: &RewardsPool<BaseType>, 
        wrapper_store: &WrapperStore,
        clock: &Clock,
        epoch_id: u64,
    ): VecMap<String, u64> {
        let account_addr = voting_escrow::token_owner(ve_token);
        let (mut fee_metadata, mut fee_amounts) = rewards_pool::claimable_rewards(
            account_addr,
            rewards_pool,
            epoch_id,
            clock
        );
        
        let (incentive_metadata, incentive_amounts) = rewards_pool::claimable_rewards(
            account_addr,
            incentive_pool,
            epoch_id,
            clock
        );
        
        vector::append(&mut fee_metadata, incentive_metadata);
        vector::append(&mut fee_amounts, incentive_amounts);
        
        let mut combined_rewards = vec_map::empty();
        
        vector::reverse(&mut fee_metadata);
        vector::reverse(&mut fee_amounts);
        
        let mut metadata_len = vector::length(&fee_metadata);
        assert!(metadata_len == vector::length(&fee_amounts), E_VECTOR_LENGTH_MISMATCH);
        
        while (metadata_len > 0) {
            let amount = vector::pop_back(&mut fee_amounts);
            if (amount > 0) {
                let metadata_id = vector::pop_back(&mut fee_metadata);
                let coin_name = coin_wrapper::get_original<BaseType>(wrapper_store, metadata_id);
                
                if (vec_map::contains(&combined_rewards, &coin_name)) {
                    let current_amount = vec_map::get_mut(&mut combined_rewards, &coin_name);
                    *current_amount = *current_amount + amount;
                } else {
                    vec_map::insert(&mut combined_rewards, coin_name, amount);
                };
            };
            metadata_len = metadata_len - 1;
        };
        
        vector::destroy_empty(fee_metadata);
        vector::destroy_empty(fee_amounts);
        combined_rewards
    }  

    public entry fun whitelist_native_fungible_assets(
        admin_data: &AdministrativeData,
        admin_cap: &TokenWhitelistAdminCap,
        whitelist: &mut TokenWhitelist,
        mut assets: vector<ID>,
        ctx: &mut TxContext
    ) {
        assert!(admin_data.operator == tx_context::sender(ctx), E_NOT_OPERATOR);
        
        token_whitelist::whitelist_native_fungible_assets(admin_cap, whitelist, assets);
        let mut tokens = vector::empty<String>();
        
        vector::reverse(&mut assets);
        
        let mut assets_len = vector::length(&assets);
        while (assets_len > 0) {
            vector::push_back(&mut tokens, coin_wrapper::format_fungible_asset(vector::pop_back(&mut assets)));
            assets_len = assets_len - 1;
        };
        vector::destroy_empty(assets);
    }

    public entry fun claim_rebase(
        account: address,
        ve_token: &mut VeSuiDexToken<SUIDEX_TOKEN>,
        collection: &mut VeSuiDexCollection,
        manager: &mut SuiDexManager,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let account_addr = tx_context::sender(ctx);
        assert!(voting_escrow::token_owner(ve_token) == account_addr, E_NOT_OWNER);

        voting_escrow::claim_rebase(account, ve_token, collection, manager, clock, ctx);
    }

    public fun claimable_rebase(
        ve_token: &VeSuiDexToken<SUIDEX_TOKEN>,
        collection: &VeSuiDexCollection,
        clock: &Clock
    ): u64 {
        voting_escrow::claimable_rebase(ve_token, collection, clock)
    }

    public fun advance_epoch<BaseType, QuoteType>(
        admin_data: &mut AdministrativeData,
        gauge_vote_accounting: &mut GaugeVoteAccounting,
        gauge: &mut Gauge<BaseType, QuoteType>,
        rewards_pool: &mut RewardsPool<BaseType>,
        manager: &mut SuiDexManager,
        collection: &mut VeSuiDexCollection, 
        minter: &mut MinterConfig,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_epoch = epoch::now(clock);
        
        if (admin_data.pending_distribution_epoch == current_epoch) {
            return
        };
        
        admin_data.pending_distribution_epoch = current_epoch;

        // mint new tokens and handle rebase
        let (mut minted_tokens, rebase_tokens) = minter::mint(minter, manager, collection, clock, ctx);
        
        if (coin::value(&rebase_tokens) > 0) {
            voting_escrow::add_rebase(collection, coin::value(&rebase_tokens), current_epoch - 1, clock);
            suidex_token::burn(suidex_token::get_treasury_cap(manager), rebase_tokens);
        } else {
            coin::destroy_zero(rebase_tokens);
        };

        let gauge_id = object::id(gauge);

        if (vec_map::contains(&gauge_vote_accounting.votes_for_gauges, &gauge_id)) {
            let vote_amount = *vec_map::get(&gauge_vote_accounting.votes_for_gauges, &gauge_id);
            
            if (gauge_vote_accounting.total_votes > 0) {
                let coins_amount = coin::value(&minted_tokens);
                let amount_to_extract = (((coins_amount as u128) * vote_amount / gauge_vote_accounting.total_votes) as u64);
                
                if (amount_to_extract > 0) {
                    let extracted_tokens = coin::split(&mut minted_tokens, amount_to_extract, ctx);
                    let extracted_balance = coin::into_balance(extracted_tokens);
                    gauge::add_rewards<BaseType, QuoteType>(gauge, extracted_balance, clock);
                };
            };

            let (gauge_fees, claim_fees) = gauge::claim_fees<BaseType, QuoteType>(gauge, ctx);
            if (coin::value(&gauge_fees) > 0 || coin::value(&claim_fees) > 0) {
                let mut fees = vector::empty();
                vector::push_back(&mut fees, gauge_fees);
                coin::destroy_zero(claim_fees);
                
                rewards_pool::add_rewards(
                    rewards_pool,
                    vector::singleton(gauge_id),
                    fees,
                    current_epoch,
                    ctx
                );
            } else {
                coin::destroy_zero(gauge_fees);
                coin::destroy_zero(claim_fees);
            };

            vec_map::remove(&mut gauge_vote_accounting.votes_for_gauges, &gauge_id);
        };

        if (coin::value(&minted_tokens) > 0) {
            suidex_token::burn(suidex_token::get_treasury_cap(manager), minted_tokens);
        } else {
            coin::destroy_zero(minted_tokens);
        };
    }

    public fun all_claimable_rewards<BaseType>(
        ve_token: &VeSuiDexToken<SUIDEX_TOKEN>,
        epoch_count: u64,
        rewards_pool: &RewardsPool<BaseType>,
        incentive_pool: &RewardsPool<BaseType>,
        wrapper_store: &WrapperStore,
        clock: &Clock,
    ) : VecMap<u64, VecMap<String, u64>> {
        let mut all_rewards = vec_map::empty<u64, VecMap<String, u64>>();
        let current_epoch = epoch::now(clock);
        let mut start_epoch = current_epoch - epoch_count;
        
        while (start_epoch < current_epoch) {
            let epoch_rewards = claimable_rewards(ve_token, rewards_pool, incentive_pool, wrapper_store, clock, start_epoch);
            if (vec_map::is_empty(&epoch_rewards) == false) {
                vec_map::insert(&mut all_rewards, start_epoch, epoch_rewards);
            };
            start_epoch = start_epoch + 1;
        };
        
        all_rewards
    }

    public fun all_current_votes<BaseType, QuoteType>(
        gauge_vote_accounting: &GaugeVoteAccounting,
        gauge_registry: &mut Table<ID, Gauge<BaseType, QuoteType>>
    ) : (VecMap<ID, u128>, u128) {
        let votes_for_gauges = &gauge_vote_accounting.votes_for_gauges;
        let mut liquidity_pools = vector::empty<ID>();
        let mut gauge_ids = vec_map::keys(votes_for_gauges);
        vector::reverse(&mut gauge_ids);
        
        let mut gauge_len = vector::length(&gauge_ids);
        while (gauge_len > 0) {
            let gauge_id = vector::pop_back(&mut gauge_ids);
            if (table::contains(gauge_registry, gauge_id)) {
                let gauge = table::borrow_mut(gauge_registry, gauge_id);
                vector::push_back(
                    &mut liquidity_pools, 
                    object::id(gauge::liquidity_pool(gauge))
                );
            };
            gauge_len = gauge_len - 1;
        };
        
        vector::destroy_empty(gauge_ids);
        
        let mut result_map = vec_map::empty();
        let mut i = 0;
        while (i < vector::length(&liquidity_pools)) {
            let pool_id = *vector::borrow(&liquidity_pools, i);
            let vote_amount = *vec_map::get(votes_for_gauges, &pool_id);
            vec_map::insert(&mut result_map, pool_id, vote_amount);
            i = i + 1;
        };
        
        (result_map, gauge_vote_accounting.total_votes)
    }

    public entry fun claim_rewards_6<BaseType, T0, T1, T2, T3, T4, T5>(
        ve_token: &VeSuiDexToken<SUIDEX_TOKEN>,
        liquidity_pool: ID,
        epoch_id: u64,
        admin_data: &AdministrativeData,
        rewards_pool: &mut RewardsPool<BaseType>,
        wrapper_store: &mut WrapperStore,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let gauge = get_gauge(admin_data, liquidity_pool);
        assert!(is_gauge_active(admin_data, gauge), E_GAUGE_INACTIVE);

        let account_addr = tx_context::sender(ctx);
        assert!(voting_escrow::token_owner(ve_token) == account_addr, E_NOT_OWNER);
        
        let mut rewards = rewards_pool::claim_rewards(account_addr, rewards_pool, epoch_id, clock, ctx);
        vector::append(&mut rewards, rewards_pool::claim_rewards(account_addr, rewards_pool, epoch_id, clock, ctx));
        
        let mut valid_coins = vector::empty<String>();
        add_valid_coin<T0>(&mut valid_coins);
        add_valid_coin<T1>(&mut valid_coins);
        add_valid_coin<T2>(&mut valid_coins);
        add_valid_coin<T3>(&mut valid_coins);
        add_valid_coin<T4>(&mut valid_coins);
        add_valid_coin<T5>(&mut valid_coins);

        vector::reverse(&mut rewards);
        let mut rewards_length = vector::length(&rewards);
        while (rewards_length > 0) {
            let reward = vector::pop_back(&mut rewards);
            if (coin::value(&reward) == 0) {
                coin::destroy_zero(reward);
            } else {
                let metadata_id = object::id(&reward);
                if (coin_wrapper::is_wrapper(wrapper_store, metadata_id)) {
                    let original = coin_wrapper::get_original<BaseType>(wrapper_store, metadata_id);
                    let (found, index) = vector::index_of(&valid_coins, &original);
                    assert!(found, E_INVALID_COIN);

                    let wrapped_coin = coin_wrapper::wrap(wrapper_store, reward, ctx);

                    if (index == 0) { unwrap_and_deposit<T0>(wrapper_store, account_addr, wrapped_coin); }
                    else if (index == 1) { unwrap_and_deposit<T1>(wrapper_store, account_addr, wrapped_coin); }
                    else if (index == 2) { unwrap_and_deposit<T2>(wrapper_store, account_addr, wrapped_coin); }
                    else if (index == 3) { unwrap_and_deposit<T3>(wrapper_store, account_addr, wrapped_coin); }
                    else if (index == 4) { unwrap_and_deposit<T4>(wrapper_store, account_addr, wrapped_coin); }
                    else {
                        assert!(index == 5, E_INVALID_COIN);
                        unwrap_and_deposit<T5>(wrapper_store, account_addr, wrapped_coin);
                    };
                } else {
                    transfer::public_transfer(reward, account_addr);
                };
            };
            rewards_length = rewards_length - 1;
        };
        vector::destroy_empty(rewards);
    }

    public entry fun claim_rewards_all_6<BaseType, T0, T1, T2, T3, T4, T5>(
        ve_token: &VeSuiDexToken<SUIDEX_TOKEN>,
        liquidity_pool: ID,
        epoch_count: u64,
        admin_data: &AdministrativeData,
        rewards_pool: &mut RewardsPool<BaseType>,
        wrapper_store: &mut WrapperStore,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_epoch = epoch::now(clock);
        let mut start_epoch = current_epoch - epoch_count;
        
        while (start_epoch < current_epoch) {
            claim_rewards_6<BaseType, T0, T1, T2, T3, T4, T5>(
                ve_token,
                liquidity_pool,
                start_epoch,
                admin_data,
                rewards_pool,
                wrapper_store,
                clock,
                ctx
            );
            start_epoch = start_epoch + 1;
        };
    }

    public entry fun batch_claim<BaseType, T0, T1, T2, T3, T4, T5>(
        mut ve_tokens: vector<VeSuiDexToken<SUIDEX_TOKEN>>,
        mut liquidity_pools: vector<ID>,
        epoch_count: u64,
        admin_data: &AdministrativeData,
        rewards_pool: &mut RewardsPool<BaseType>,
        wrapper_store: &mut WrapperStore,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        vector::reverse(&mut ve_tokens);
        let mut ve_token_count = vector::length(&ve_tokens);
        
        while (ve_token_count > 0) {
            let ve_token = vector::pop_back(&mut ve_tokens);
            vector::reverse(&mut liquidity_pools);
            let mut pool_len = vector::length(&liquidity_pools);
            
            while (pool_len > 0) {
                let pool = vector::pop_back(&mut liquidity_pools);
                
                claim_rewards_all_6<BaseType, T0, T1, T2, T3, T4, T5>(
                    &ve_token,
                    pool,
                    epoch_count,
                    admin_data,
                    rewards_pool,
                    wrapper_store,
                    clock,
                    ctx
                );
                
                vector::push_back(&mut liquidity_pools, pool);
                pool_len = pool_len - 1;
            };
            
            vector::push_back(&mut ve_tokens, ve_token);
            ve_token_count = ve_token_count - 1;
        };
        
        vector::destroy_empty(ve_tokens);
        vector::destroy_empty(liquidity_pools);
    }

    public fun last_voted_epoch(
        ve_token: &VeSuiDexToken<SUIDEX_TOKEN>,
        ve_token_accounting: &VeTokenVoteAccounting
    ): u64 {
        let token_id = object::id(ve_token);
        if (table::contains(&ve_token_accounting.last_voted_epoch, token_id)) {
            *table::borrow(&ve_token_accounting.last_voted_epoch, token_id)
        } else {
            0
        }
    }

    public fun can_vote(
        ve_token: &VeSuiDexToken<SUIDEX_TOKEN>, 
        ve_token_accounting: &VeTokenVoteAccounting,
        clock: &Clock
    ): bool {
        let last_vote_epoch = last_voted_epoch(ve_token, ve_token_accounting);
        last_vote_epoch < epoch::now(clock)
    }

    public fun claim_emissions<BaseType, QuoteType>(
        liquidity_pool: ID,
        admin_data: &AdministrativeData,
        gauge: &mut Gauge<BaseType, QuoteType>,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<SUIDEX_TOKEN> {
        let gauge_id = get_gauge(admin_data, liquidity_pool);
        assert!(is_gauge_active(admin_data, gauge_id), E_GAUGE_INACTIVE);

        assert!(object::id(gauge) == gauge_id, E_WRONG_GAUGE);
        let balance = gauge::claim_rewards(gauge, ctx, clock);
        
        coin::from_balance(balance, ctx)
    }

    public entry fun claim_emissions_entry<BaseType, QuoteType>(
        liquidity_pool: ID,
        admin_data: &AdministrativeData,
        gauge: &mut Gauge<BaseType, QuoteType>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let emissions = claim_emissions(liquidity_pool, admin_data, gauge, clock, ctx);
        transfer::public_transfer(emissions, tx_context::sender(ctx));
    }

    /*public entry fun claim_emissions_multiple<BaseType, QuoteType>(
        mut liquidity_pools: vector<ID>,
        admin_data: &AdministrativeData,
        gauge: &mut Gauge<BaseType, QuoteType>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        vector::reverse(&mut liquidity_pools);
        let mut pool_count = vector::length(&liquidity_pools);
        
        while (pool_count > 0) {
            let pool_id = vector::pop_back(&mut liquidity_pools);
            let gauge_id = get_gauge(admin_data, pool_id);

            claim_emissions_entry(
                pool_id,
                admin_data,
                gauge,
                clock,
                ctx
            );

            pool_count = pool_count - 1;
        };
        
        vector::destroy_empty(liquidity_pools);
    }*/

    public fun claimable_emissions<BaseType, QuoteType>(
        account_address: address,
        admin_data: &AdministrativeData,
        pool: ID,
        gauge: &mut Gauge<BaseType, QuoteType>,
        clock: &Clock
    ): u64 {
        let gauge_id = get_gauge(admin_data, pool);  
        assert!(object::id(gauge) == gauge_id, E_WRONG_GAUGE);
        gauge::claimable_rewards(account_address, gauge, clock)
    }

    /*public fun claimable_emissions_multiple<BaseType, QuoteType>(
        account_address: address,
        mut liquidity_pools: vector<ID>,
        admin_data: &AdministrativeData,
        gauge: &mut Gauge<BaseType, QuoteType>,
        clock: &Clock
    ): vector<u64> {
        let mut claimable_amounts = vector::empty();
        vector::reverse(&mut liquidity_pools);
        let mut pool_count = vector::length(&liquidity_pools);
        
        while (pool_count > 0) {
            let pool = vector::pop_back(&mut liquidity_pools);
            let gauge_id = get_gauge(admin_data, pool);  
            assert!(object::id(gauge) == gauge_id, E_WRONG_GAUGE);
            vector::push_back(&mut claimable_amounts, gauge::claimable_rewards(account_address, gauge, clock));
            vector::push_back(&mut liquidity_pools, pool); 
            pool_count = pool_count - 1;
        };
        
        vector::destroy_empty(liquidity_pools);
        claimable_amounts
    }*/

    public fun create_gauge<BaseType, QuoteType>(
        admin_data: &mut AdministrativeData,
        configs: &mut LiquidityPoolConfigs,
        base_metadata: &CoinMetadata<BaseType>,
        quote_metadata: &CoinMetadata<QuoteType>,
        is_stable: bool, 
        ctx: &mut TxContext
    ) {
        assert!(admin_data.operator == tx_context::sender(ctx), E_NOT_OPERATOR);
        
        // Create liquidity pool first
        let pool = liquidity_pool::liquidity_pool(configs, base_metadata, quote_metadata, is_stable);
        let pool_id = object::id(pool);

        let actual_pool = liquidity_pool::extract_pool(configs, base_metadata, quote_metadata, is_stable);
        
        // Create gauge and get its ID (note gauge is now shared via gauge module)
        let gauge_id = gauge::create<BaseType, QuoteType>(actual_pool, ctx);
        
        // Add to mappings
        vector::push_back(&mut admin_data.active_gauges_list, gauge_id);
        table::add(&mut admin_data.active_gauges, gauge_id, true);
        table::add(&mut admin_data.pool_to_gauge, pool_id, gauge_id);
        
        // Create reward pools
        let reward_tokens = vector::empty<ID>();
        let fees_pool_id = rewards_pool::create<BaseType>(reward_tokens, ctx);
        let incentive_pool_id = rewards_pool::create<BaseType>(reward_tokens, ctx);
        
        // Add reward pool mappings
        table::add(&mut admin_data.gauge_to_fees_pool, gauge_id, fees_pool_id);
        table::add(&mut admin_data.gauge_to_incentive_pool, gauge_id, incentive_pool_id);
    }

    public entry fun create_gauge_entry<BaseType, QuoteType>(
        admin_data: &mut AdministrativeData,
        configs: &mut LiquidityPoolConfigs,
        base_metadata: &CoinMetadata<BaseType>,
        quote_metadata: &CoinMetadata<QuoteType>,
        is_stable: bool, 
        ctx: &mut TxContext
    ) {
        create_gauge(
            admin_data,
            configs,
            base_metadata,
            quote_metadata,
            is_stable, 
            ctx
        );
    }

    public(package) fun create_gauge_internal<BaseType, QuoteType>(
        admin_data: &mut AdministrativeData,
        configs: &mut LiquidityPoolConfigs,
        base_metadata: &CoinMetadata<BaseType>,
        quote_metadata: &CoinMetadata<QuoteType>,
        is_stable: bool, 
        ctx: &mut TxContext
    ) {
        let pool = liquidity_pool::extract_pool(configs, base_metadata, quote_metadata, is_stable);

        let gauge_id = gauge::create<BaseType, QuoteType>(pool, ctx);
        let pool_id = gauge_id;
        
        table::add(&mut admin_data.active_gauges, gauge_id, false);
        
        table::add(&mut admin_data.pool_to_gauge, pool_id, gauge_id);
        
        let reward_tokens = vector::empty<ID>();
        let fees_pool_id = rewards_pool::create<BaseType>(reward_tokens, ctx);
        
        let reward_tokens = vector::empty<ID>();
        let incentive_pool_id = rewards_pool::create<BaseType>(reward_tokens, ctx);
        
        table::add(&mut admin_data.gauge_to_fees_pool, gauge_id, fees_pool_id);
        table::add(&mut admin_data.gauge_to_incentive_pool, gauge_id, incentive_pool_id);
    }

    public fun add_gauge<BaseType, QuoteType>(
        admin_data: &mut AdministrativeData,
        pool_id: ID,
        gauge: Gauge<BaseType, QuoteType>
    ) {
        dynamic_object_field::add(&mut admin_data.id, pool_id, gauge);
    }

    public fun store_gauge<BaseType, QuoteType>(
        admin_data: &mut AdministrativeData,
        gauge: Gauge<BaseType, QuoteType>
    ) {
        let gauge_id = object::id(&gauge);
        bag::add(&mut admin_data.gauges, gauge_id, gauge);
    }

    public fun borrow_gauge<BaseType, QuoteType>(
        admin_data: &mut AdministrativeData,
        gauge_id: ID
    ): &mut Gauge<BaseType, QuoteType> {
        bag::borrow_mut(&mut admin_data.gauges, gauge_id)
    }

    public fun get_gauge_obj<BaseType, QuoteType>(
        admin_data: &mut AdministrativeData,
        pool_id: ID
    ): &mut Gauge<BaseType, QuoteType> {
        dynamic_object_field::borrow_mut(&mut admin_data.id, pool_id)
    }

    public fun current_votes(
        liquidity_pool: ID,
        admin_data: &AdministrativeData,
        gauge_vote_accounting: &GaugeVoteAccounting,
    ): (u128, u128) {
        let gauge_id = get_gauge(admin_data, liquidity_pool);
        (
            *vec_map::get(&gauge_vote_accounting.votes_for_gauges, &gauge_id),
            gauge_vote_accounting.total_votes
        )
    }

    public entry fun disable_gauge(
        admin_data: &mut AdministrativeData,
        gauge_vote_accounting: &mut GaugeVoteAccounting,
        gauge_id: ID,
        ctx: &mut TxContext
    ) {
        assert!(admin_data.operator == tx_context::sender(ctx), E_NOT_OPERATOR);
        
        let (found, index) = vector::index_of(&admin_data.active_gauges_list, &gauge_id);
        assert!(found, E_GAUGE_NOT_FOUND);
        
        vector::remove(&mut admin_data.active_gauges_list, index);
        
        let active = table::borrow_mut(&mut admin_data.active_gauges, gauge_id);
        *active = false;

        if (vec_map::contains(&gauge_vote_accounting.votes_for_gauges, &gauge_id)) {
            let gauge_votes = *vec_map::get(&gauge_vote_accounting.votes_for_gauges, &gauge_id);
            gauge_vote_accounting.total_votes = gauge_vote_accounting.total_votes - gauge_votes;
            vec_map::remove(&mut gauge_vote_accounting.votes_for_gauges, &gauge_id);
        };
    }

    public entry fun enable_gauge(
        admin_data: &mut AdministrativeData,
        gauge_id: ID,
        ctx: &mut TxContext
    ) {
        assert!(admin_data.operator == tx_context::sender(ctx), E_NOT_OPERATOR);
        
        assert!(!vector::contains(&admin_data.active_gauges_list, &gauge_id), E_GAUGE_ALREADY_ACTIVE);
        
        vector::push_back(&mut admin_data.active_gauges_list, gauge_id);
        
        let active = table::borrow_mut(&mut admin_data.active_gauges, gauge_id);
        *active = true;
    }

    public fun gauge_exists<BaseType, QuoteType>(
        admin_data: &AdministrativeData,
        liquidity_pool: &LiquidityPool<BaseType, QuoteType>
    ): bool {
        let pool_id = object::id(liquidity_pool);
        table::contains(&admin_data.pool_to_gauge, pool_id)
    }

    public fun governance(admin_data: &AdministrativeData): address {
        admin_data.governance
    }

    public fun incentivize<BaseType, QuoteType>(
        rewards: vector<Coin<BaseType>>,
        incentive_pool: &mut RewardsPool<BaseType>,
        admin_data: &mut AdministrativeData,
        gauge: &mut Gauge<BaseType, QuoteType>,
        gauge_vote_accounting: &mut GaugeVoteAccounting,
        manager: &mut SuiDexManager,
        collection: &mut VeSuiDexCollection,
        minter: &mut MinterConfig,
        whitelist: &RewardTokenWhitelistPerPool,
        wrapper_store: &WrapperStore,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let liquidity_pool = gauge::liquidity_pool(gauge);
        assert!(gauge_exists(admin_data, liquidity_pool), E_GAUGE_NOT_EXISTS);
        
        let mut reward_tokens = vector::empty<ID>();
        let mut i = 0;
        while (i < vector::length(&rewards)) {
            let coin_id = object::id(vector::borrow(&rewards, i));
            vector::push_back(&mut reward_tokens, coin_id); // Add ID unconditionally
            
            if (coin_wrapper::is_wrapper(wrapper_store, coin_id)) {
                let original = coin_wrapper::get_original<BaseType>(wrapper_store, coin_id);
                let token_name = string::from_ascii(original);
                
                assert!(
                    token_whitelist::is_reward_token_whitelisted_on_pool(
                        whitelist,
                        &token_name,
                        object::id_address(liquidity_pool)
                    ),
                    E_REWARD_TOKEN_NOT_WHITELISTED
                );
            };
            i = i + 1;
        };

        assert!(vector::length(&reward_tokens) == vector::length(&rewards), E_VECTOR_LENGTH_MISMATCH);
        let pool_id = object::id(liquidity_pool);
        let incentive_pool_id = incentive_pool(admin_data, pool_id);
        assert!(incentive_pool_id == object::id(incentive_pool), E_WRONG_REWARD_POOL);

        advance_epoch<BaseType, QuoteType>(
            admin_data,
            gauge_vote_accounting,
            gauge,  // Pass the gauge directly now
            incentive_pool,
            manager,
            collection,
            minter,
            clock,
            ctx
        );

        rewards_pool::add_rewards(
            incentive_pool,
            reward_tokens,
            rewards,
            epoch::now(clock) + 1,
            ctx
        );
    }

    public fun incentivize_coin<BaseType, QuoteType, CoinType>(
        rewards_pool: &mut RewardsPool<BaseType>,
        admin_data: &mut AdministrativeData,
        gauge: &mut Gauge<BaseType, QuoteType>,
        gauge_vote_accounting: &mut GaugeVoteAccounting,
        manager: &mut SuiDexManager,
        collection: &mut VeSuiDexCollection,
        minter: &mut MinterConfig,
        whitelist: &RewardTokenWhitelistPerPool,
        wrapper_store: &mut WrapperStore,
        reward_coin: Coin<CoinType>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let wrapped_coin = coin_wrapper::wrap<CoinType>(wrapper_store, reward_coin, ctx);
        let base_coin: Coin<BaseType> = coin_wrapper::unwrap<BaseType>(wrapper_store, wrapped_coin);
        
        let mut rewards = vector::empty();
        vector::push_back(&mut rewards, base_coin);

        incentivize(
            rewards,
            rewards_pool,
            admin_data,
            gauge,
            gauge_vote_accounting,
            manager,
            collection,
            minter,
            whitelist,
            wrapper_store,
            clock,
            ctx
        )
    }

    public entry fun incentivize_coin_entry<BaseType, QuoteType, CoinType>(
        rewards_pool: &mut RewardsPool<BaseType>,
        admin_data: &mut AdministrativeData,
        gauge: &mut Gauge<BaseType, QuoteType>,
        gauge_vote_accounting: &mut GaugeVoteAccounting,
        manager: &mut SuiDexManager,
        collection: &mut VeSuiDexCollection,
        minter: &mut MinterConfig,
        whitelist: &RewardTokenWhitelistPerPool,
        wrapper_store: &mut WrapperStore,
        reward_coin: Coin<CoinType>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        incentivize_coin(
            rewards_pool,
            admin_data,
            gauge,
            gauge_vote_accounting,
            manager,
            collection,
            minter,
            whitelist,
            wrapper_store,
            reward_coin,
            clock,
            ctx
        )
    }

    public entry fun incentivize_entry<BaseType, QuoteType>(
        mut metadata_objects: vector<ID>, 
        mut amounts: vector<u64>,
        mut coins: vector<Coin<BaseType>>,
        rewards_pool: &mut RewardsPool<BaseType>,
        admin_data: &mut AdministrativeData,
        gauge: &mut Gauge<BaseType, QuoteType>,
        gauge_vote_accounting: &mut GaugeVoteAccounting,
        manager: &mut SuiDexManager,
        collection: &mut VeSuiDexCollection,
        minter: &mut MinterConfig,
        whitelist: &RewardTokenWhitelistPerPool,
        wrapper_store: &mut WrapperStore,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(vector::length(&metadata_objects) == vector::length(&amounts), E_VECTOR_LENGTH_MISMATCH);
        let mut rewards = vector::empty();
        vector::reverse(&mut metadata_objects);
        vector::reverse(&mut amounts);
        
        let mut metadata_count = vector::length(&metadata_objects);
        assert!(metadata_count == vector::length(&amounts), E_VECTOR_LENGTH_MISMATCH);
        
        while (metadata_count > 0) {
            vector::push_back(
                &mut rewards,
                vector::pop_back(&mut coins)
            );
            metadata_count = metadata_count - 1;
        };

        vector::destroy_empty(metadata_objects);
        vector::destroy_empty(amounts);
        vector::destroy_empty(coins);
        
        incentivize(
            rewards,
            rewards_pool,
            admin_data,
            gauge,
            gauge_vote_accounting,
            manager,
            collection,
            minter,
            whitelist,
            wrapper_store,
            clock,
            ctx
        )
    }

    public entry fun merge_ve_tokens(
        ve_token_accounting: &mut VeTokenVoteAccounting,
        source_token: VeSuiDexToken<SUIDEX_TOKEN>,
        target_token: &mut VeSuiDexToken<SUIDEX_TOKEN>,
        collection: &mut VeSuiDexCollection,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let source_last_voted = last_voted_epoch(&source_token, ve_token_accounting);
        let can_merge = if (source_last_voted < epoch::now(clock)) {
            let target_last_voted = last_voted_epoch(target_token, ve_token_accounting);
            target_last_voted < epoch::now(clock)
        } else {
            false
        };

        assert!(can_merge, E_TOKENS_RECENTLY_VOTED);

        let source_id = object::id(&source_token);
        if (table::contains(&ve_token_accounting.votes_for_pools_by_ve_token, source_id)) {
            table::remove(&mut ve_token_accounting.votes_for_pools_by_ve_token, source_id);
        };
        if (table::contains(&ve_token_accounting.last_voted_epoch, source_id)) {
            table::remove(&mut ve_token_accounting.last_voted_epoch, source_id);
        };
        
        voting_escrow::merge_ve_nft(
            tx_context::sender(ctx),
            source_token,
            target_token,
            collection,
            clock,
            ctx
        );
    }

    public fun whitelist_default_reward_pool<BaseType, QuoteType>(
        liquidity_pool: &LiquidityPool<BaseType, QuoteType>,
        base_metadata: &CoinMetadata<BaseType>,
        quote_metadata: &CoinMetadata<QuoteType>,
        admin_cap: &TokenWhitelistAdminCap,
        pool_whitelist: &mut RewardTokenWhitelistPerPool,
        wrapper_store: &WrapperStore,
    ) {
        let mut whitelisted_tokens = vector::empty<string::String>();

        // Add SUI token as default - use explicit string creation
        vector::push_back(&mut whitelisted_tokens, string::utf8(b"sui::sui::SUI"));

        // Get assets from liquidity pool
        let inner_assets = liquidity_pool::supported_inner_assets<BaseType, QuoteType>(
            base_metadata,
            quote_metadata
        );

        // Add supported assets to whitelist with proper string handling
        let mut i = 0;
        let len = vector::length(&inner_assets);
        while (i < len) {
            let asset_id = *vector::borrow(&inner_assets, i);
            if (coin_wrapper::is_wrapper(wrapper_store, asset_id)) {
                let original = coin_wrapper::get_original<BaseType>(wrapper_store, asset_id);
                // Safely create string from ASCII
                let token_string = string::from_ascii(original);
                vector::push_back(&mut whitelisted_tokens, token_string);
            };
            i = i + 1;
        };

        // Set whitelist tokens
        token_whitelist::set_whitelist_reward_tokens(
            admin_cap,
            pool_whitelist,
            whitelisted_tokens,
            object::id_address(liquidity_pool),
            true // is_whitelisted
        );
    }

    public entry fun whitelist_token_reward_pool_entry<BaseType, QuoteType>(
        liquidity_pool: &LiquidityPool<BaseType, QuoteType>,
        tokens: vector<string::String>,
        admin_cap: &TokenWhitelistAdminCap,
        pool_whitelist: &mut RewardTokenWhitelistPerPool,
        admin_data: &AdministrativeData,
        is_whitelisted: bool,
        ctx: &mut TxContext
    ) {
        // check if sender is operator
        assert!(admin_data.operator == tx_context::sender(ctx), E_NOT_OPERATOR);
        
        // set whitelist tokens
        token_whitelist::set_whitelist_reward_tokens(
            admin_cap,
            pool_whitelist,
            tokens,
            object::id_address(liquidity_pool),
            is_whitelisted
        );
    }

    public fun operator(admin_data: &AdministrativeData): address {
        admin_data.operator
    }

    public fun pending_distribution_epoch(admin_data: &AdministrativeData): u64 {
        admin_data.pending_distribution_epoch
    }

    public entry fun vote<BaseType, QuoteType>(
        ve_token: &VeSuiDexToken<SUIDEX_TOKEN>,
        pool_id: ID,
        weight: u64,
        admin_data: &mut AdministrativeData,
        gauge_vote_accounting: &mut GaugeVoteAccounting,
        gauge: &mut Gauge<BaseType, QuoteType>,
        rewards_pool: &mut RewardsPool<BaseType>,
        manager: &mut SuiDexManager,
        collection: &mut VeSuiDexCollection,
        minter: &mut MinterConfig, 
        ve_token_accounting: &mut VeTokenVoteAccounting,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(weight > 0, E_ZERO_TOTAL_WEIGHT);

        advance_epoch<BaseType, QuoteType>(
            admin_data, 
            gauge_vote_accounting,
            gauge,
            rewards_pool,
            manager,
            collection,
            minter,
            clock,
            ctx
        );

        assert!(voting_escrow::token_owner(ve_token) == tx_context::sender(ctx), E_NOT_OWNER);
        let token_id = object::id(ve_token);
        let current_epoch = epoch::now(clock);
        
        let last_voted_epoch = if (table::contains(&ve_token_accounting.last_voted_epoch, token_id)) {
            table::borrow_mut(&mut ve_token_accounting.last_voted_epoch, token_id)
        } else {
            table::add(&mut ve_token_accounting.last_voted_epoch, token_id, 0);
            table::borrow_mut(&mut ve_token_accounting.last_voted_epoch, token_id)
        };
        assert!(current_epoch > *last_voted_epoch, E_ALREADY_VOTED_THIS_EPOCH);
        *last_voted_epoch = current_epoch;

        remove_ve_token_vote_records(ve_token_accounting, ve_token);

        assert!(table::contains(&admin_data.pool_to_gauge, pool_id), E_GAUGE_NOT_EXISTS);
        let gauge_id = *table::borrow(&admin_data.pool_to_gauge, pool_id);
        assert!(object::id(gauge) == gauge_id, E_WRONG_GAUGE);
        assert!(is_gauge_active(admin_data, gauge_id), E_GAUGE_INACTIVE);

        let base_voting_power = voting_escrow::get_voting_power(ve_token, clock);
        let voting_power = (base_voting_power * weight) / 100; // Apply weight percentage

        // Update gauge votes
        gauge_vote_accounting.total_votes = gauge_vote_accounting.total_votes + (voting_power as u128);
        
        if (vec_map::contains(&gauge_vote_accounting.votes_for_gauges, &gauge_id)) {
            let gauge_votes = vec_map::get_mut(&mut gauge_vote_accounting.votes_for_gauges, &gauge_id);
            *gauge_votes = *gauge_votes + (voting_power as u128);
        } else {
            vec_map::insert(&mut gauge_vote_accounting.votes_for_gauges, gauge_id, (voting_power as u128));
        };

        let mut new_votes = vec_map::empty<ID, u64>();
        vec_map::insert(&mut new_votes, pool_id, voting_power);
        table::add(&mut ve_token_accounting.votes_for_pools_by_ve_token, token_id, new_votes);
    }

    public entry fun poke<BaseType, QuoteType>(
        ve_token: &VeSuiDexToken<SUIDEX_TOKEN>,
        pool_id: ID,
        admin_data: &mut AdministrativeData,
        gauge_vote_accounting: &mut GaugeVoteAccounting,
        gauge: &mut Gauge<BaseType, QuoteType>,
        rewards_pool: &mut RewardsPool<BaseType>,
        manager: &mut SuiDexManager,
        collection: &mut VeSuiDexCollection,
        minter: &mut MinterConfig,
        ve_token_accounting: &mut VeTokenVoteAccounting,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let token_id = object::id(ve_token);
        
        // check if token has existing votes
        assert!(
            table::contains(&ve_token_accounting.votes_for_pools_by_ve_token, token_id),
            E_NO_VOTES_FOR_TOKEN
        );
        
        // get existing vote map
        let vote_map = table::borrow(
            &ve_token_accounting.votes_for_pools_by_ve_token,
            token_id
        );

        // get vote amount for this pool
        assert!(vec_map::contains(vote_map, &pool_id), E_NO_VOTES_FOR_TOKEN);
        let vote_amount = *vec_map::get(vote_map, &pool_id);

        vote<BaseType, QuoteType>(
            ve_token,
            pool_id,
            vote_amount,
            admin_data,
            gauge_vote_accounting,
            gauge,
            rewards_pool,
            manager,
            collection,
            minter,
            ve_token_accounting,
            clock,
            ctx
        );
    }

    fun remove_ve_token_vote_records(
        ve_token_accounting: &mut VeTokenVoteAccounting,
        ve_token: &VeSuiDexToken<SUIDEX_TOKEN>,
    ) {
        let token_id = object::id(ve_token);
        if (table::contains(&ve_token_accounting.votes_for_pools_by_ve_token, token_id)) {
            // retrieve all existing vote records for this token
            let mut old_votes = table::remove(&mut ve_token_accounting.votes_for_pools_by_ve_token, token_id);
            
            // get all keys first
            let mut keys = vec_map::keys(&old_votes);
            
            // clear all voting records for this token, pool by pool
            while (!vector::is_empty(&keys)) {
                let key = vector::pop_back(&mut keys);
                vec_map::remove(&mut old_votes, &key);
            };
            
            vector::destroy_empty(keys);
            vec_map::destroy_empty(old_votes);
        };
    }

    public entry fun rescue_stuck_rewards<BaseType, QuoteType>(
        mut liquidity_pools: vector<ID>,
        fees_pool: &mut RewardsPool<BaseType>,
        incentive_pool: &mut RewardsPool<BaseType>,
        admin_data: &mut AdministrativeData,
        gauge: &mut Gauge<BaseType, QuoteType>,
        gauge_vote_accounting: &mut GaugeVoteAccounting,
        manager: &mut SuiDexManager,
        collection: &mut VeSuiDexCollection,
        minter: &mut MinterConfig,
        whitelist: &RewardTokenWhitelistPerPool,
        wrapper_store: &mut WrapperStore,
        epoch_count: u64,
        account_address: address,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_epoch = epoch::now(clock);
        vector::reverse(&mut liquidity_pools);
        let mut pool_count = vector::length(&liquidity_pools);

        while (pool_count > 0) {
            let pool_id = vector::pop_back(&mut liquidity_pools);
            let mut start_epoch = current_epoch - epoch_count;
            
            // Verify pools match the gauge
            let lp = gauge::liquidity_pool(gauge);
            let fees_pool_id = fees_pool(admin_data, object::id(lp));
            let incentive_pool_id = incentive_pool(admin_data, object::id(lp));

            assert!(object::id(fees_pool) == fees_pool_id, E_WRONG_REWARD_POOL);
            assert!(object::id(incentive_pool) == incentive_pool_id, E_WRONG_REWARD_POOL);
            
            let mut rescued_rewards = vector::empty<Coin<BaseType>>();
            
            while (start_epoch < current_epoch) {
                let fees_rewards = rewards_pool::claim_rewards(
                    account_address,
                    fees_pool,
                    start_epoch,
                    clock,
                    ctx
                );
                vector::append(&mut rescued_rewards, fees_rewards);

                let incentive_rewards = rewards_pool::claim_rewards(
                    account_address,
                    incentive_pool,
                    start_epoch,
                    clock,
                    ctx
                );
                vector::append(&mut rescued_rewards, incentive_rewards);

                start_epoch = start_epoch + 1;
            };

            if (!vector::is_empty(&rescued_rewards)) {
                incentivize(
                    rescued_rewards,
                    incentive_pool,
                    admin_data,
                    gauge,
                    gauge_vote_accounting,
                    manager,
                    collection,
                    minter,
                    whitelist,
                    wrapper_store,
                    clock,
                    ctx
                );
            } else {
                vector::destroy_empty(rescued_rewards);
            };

            pool_count = pool_count - 1;
        };

        vector::destroy_empty(liquidity_pools);
    }

    public entry fun reset(
        ve_token: &VeSuiDexToken<SUIDEX_TOKEN>,
        ve_token_accounting: &mut VeTokenVoteAccounting,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(voting_escrow::token_owner(ve_token) == tx_context::sender(ctx), E_NOT_OWNER);
        
        let token_id = object::id(ve_token);
        let current_epoch = epoch::now(clock);
        
        let last_voted_epoch = if (table::contains(&ve_token_accounting.last_voted_epoch, token_id)) {
            table::borrow_mut(&mut ve_token_accounting.last_voted_epoch, token_id)
        } else {
            table::add(&mut ve_token_accounting.last_voted_epoch, token_id, 0);
            table::borrow_mut(&mut ve_token_accounting.last_voted_epoch, token_id)
        };

        assert!(current_epoch > *last_voted_epoch, E_ALREADY_VOTED_THIS_EPOCH);
        *last_voted_epoch = current_epoch;

        remove_ve_token_vote_records(ve_token_accounting, ve_token);

    }

    public entry fun split_ve_tokens(
        account: address,
        ve_token: VeSuiDexToken<SUIDEX_TOKEN>,
        split_amounts: vector<u64>,
        ve_token_accounting: &VeTokenVoteAccounting,
        collection: &mut VeSuiDexCollection,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let last_vote_epoch = last_voted_epoch(&ve_token, ve_token_accounting);
        assert!(last_vote_epoch < epoch::now(clock), E_RECENTLY_VOTED);

        let mut split_tokens = voting_escrow::split_ve_nft(
            account,
            ve_token,
            split_amounts,
            collection,
            clock,
            ctx
        );

        while (!vector::is_empty(&split_tokens)) {
            transfer::public_transfer(vector::pop_back(&mut split_tokens), account);
        };
        vector::destroy_empty(split_tokens);
    }

    public fun token_votes(
        ve_token: &VeSuiDexToken<SUIDEX_TOKEN>,
        ve_token_accounting: &VeTokenVoteAccounting
    ): (VecMap<ID, u64>, u64) {
        let token_id = object::id(ve_token);
        
        let votes = if (table::contains(&ve_token_accounting.votes_for_pools_by_ve_token, token_id)) {
            *table::borrow(&ve_token_accounting.votes_for_pools_by_ve_token, token_id)
        } else {
            vec_map::empty()
        };

        let last_voted = if (table::contains(&ve_token_accounting.last_voted_epoch, token_id)) {
            *table::borrow(&ve_token_accounting.last_voted_epoch, token_id)
        } else {
            0
        };

        (votes, last_voted)
    }

    public entry fun update_governance(
        admin_data: &mut AdministrativeData,
        new_governance: address,
        ctx: &mut TxContext
    ) {
        assert!(admin_data.governance == tx_context::sender(ctx), E_NOT_GOVERNANCE);
        admin_data.governance = new_governance;
    }

    public entry fun update_operator(
        admin_data: &mut AdministrativeData,
        new_operator: address,
        ctx: &mut TxContext
    ) {
        assert!(admin_data.operator == tx_context::sender(ctx), E_NOT_OPERATOR);
        admin_data.operator = new_operator;
    }

    // --- test helpers ---
    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(VOTE_MANAGER {}, ctx)
    }

    #[test_only]
    public fun verify_pool_gauge_mapping(
        admin_data: &AdministrativeData,
        pool_id: ID
    ): bool {
        table::contains(&admin_data.pool_to_gauge, pool_id)
    }

    /*#[test_only]
    public fun get_gauge_from_admin<BaseType, QuoteType>(
        gauge_config: &mut GaugeConfig,
        admin_data: &AdministrativeData,
        index: u64
    ): (&mut Gauge<BaseType, QuoteType>, ID) {
        // Get first gauge id from active_gauges_list
        let gauge_id = *vector::borrow(&admin_data.active_gauges_list, index);
        let gauge = gauge::get_gauge(gauge_config, gauge_id);
        let pool = gauge::liquidity_pool(gauge);
        let pool_id = object::id(pool);
        (gauge, pool_id)
    }*/
    
}