module sui_dex::token_whitelist {
    use std::string::{Self, String};
    use sui::table::{Self, Table};
    use sui::vec_set::{Self, VecSet};
    use std::type_name;

    // --- friends modules ---
    //use sui_dex::vote_manager;
    use sui_dex::coin_wrapper;

    // --- errors ---
    const E_MAX_WHITELIST_EXCEEDED: u64 = 1;

    // --- structs ---
    // OTW
    public struct TOKEN_WHITELIST has drop {}

    public struct RewardTokenWhitelistPerPool has key {
        id: UID,
        whitelist: Table<address, VecSet<String>>
    }

    public struct TokenWhitelist has key {
        id: UID,
        tokens: VecSet<String>
    }

    public struct TokenWhitelistAdminCap has key {
        id: UID
    }

    // init
    fun init(_otw: TOKEN_WHITELIST, ctx: &mut TxContext) {
        let admin_cap = TokenWhitelistAdminCap {
            id: object::new(ctx)
        };

        let whitelist = TokenWhitelist {
            id: object::new(ctx),
            tokens: vec_set::empty()
        };

        let pool_whitelist = RewardTokenWhitelistPerPool {
            id: object::new(ctx),
            whitelist: table::new(ctx)
        };

        transfer::share_object(whitelist);
        transfer::share_object(pool_whitelist);
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    public fun add_to_whitelist(
        _: &TokenWhitelistAdminCap,
        whitelist: &mut TokenWhitelist,
        mut new_tokens: vector<String>
    ) {
        vector::reverse(&mut new_tokens);
        let mut new_tokens_length = vector::length(&new_tokens);
        
        while (new_tokens_length > 0) {
            let token = vector::pop_back(&mut new_tokens);
            if (!vec_set::contains(&whitelist.tokens, &token)) {
                vec_set::insert(&mut whitelist.tokens, token);
            };
            new_tokens_length = new_tokens_length - 1;
        };

        vector::destroy_empty(new_tokens);
    }

    public fun are_whitelisted(
        whitelist: &TokenWhitelist,
        tokens: &vector<String>
    ): bool {
        let mut all_whitelisted = true;
        let mut i = 0;
        while (i < vector::length(tokens)) {
            let is_token_whitelisted = vec_set::contains(&whitelist.tokens, vector::borrow(tokens, i));
            all_whitelisted = is_token_whitelisted;
            if (!is_token_whitelisted) {
                break
            };
            i = i + 1;
        };
        all_whitelisted
    }

    public fun is_reward_token_whitelisted_on_pool(
        pool_whitelist: &RewardTokenWhitelistPerPool,
        token: &String,
        pool_address: address
    ): bool {
        if (!table::contains(&pool_whitelist.whitelist, pool_address)) {
            return false
        };
        vec_set::contains(table::borrow(&pool_whitelist.whitelist, pool_address), token)
    }

    public fun set_whitelist_reward_token<T>(
        admin_cap: &TokenWhitelistAdminCap,
        pool_whitelist: &mut RewardTokenWhitelistPerPool,
        pool_address: address,
        is_whitelisted: bool
    ) {
        let mut tokens = vector::empty<String>();
        let type_string = type_name::get<T>();
        let ascii_string = type_name::into_string(type_string);
        vector::push_back(&mut tokens, string::from_ascii(ascii_string));
        set_whitelist_reward_tokens(admin_cap, pool_whitelist, tokens, pool_address, is_whitelisted);
    }

    public fun set_whitelist_reward_tokens(
        _: &TokenWhitelistAdminCap,
        pool_whitelist: &mut RewardTokenWhitelistPerPool,
        tokens: vector<String>,
        pool_address: address,
        is_whitelisted: bool,
    ) {
        if (!table::contains(&pool_whitelist.whitelist, pool_address)) {
            table::add(&mut pool_whitelist.whitelist, pool_address, vec_set::empty<String>());
        };

        let pool_tokens = table::borrow_mut(&mut pool_whitelist.whitelist, pool_address);
        let current_len = vec_set::size(pool_tokens);
        assert!(current_len <= 15, E_MAX_WHITELIST_EXCEEDED);

        let mut i = 0;
        while (i < vector::length(&tokens)) {
            let token = vector::borrow(&tokens, i);
            if (is_whitelisted) {
                if (!vec_set::contains(pool_tokens, token)) {
                    assert!(vec_set::size(pool_tokens) < 15, E_MAX_WHITELIST_EXCEEDED);
                    vec_set::insert(pool_tokens, *token);
                };
            } else {
                if (vec_set::contains(pool_tokens, token)) {
                    vec_set::remove(pool_tokens, token);
                };
            };
            i = i + 1;
        };
    }

    public fun whitelist_coin<T>(
        admin_cap: &TokenWhitelistAdminCap,
        whitelist: &mut TokenWhitelist
    ) {
        let mut coins = vector::empty<String>();
        let type_string = type_name::get<T>();
        let ascii_string = type_name::into_string(type_string);
        let coin_string = string::from_ascii(ascii_string);
        vector::push_back(&mut coins, coin_string);
        add_to_whitelist(admin_cap, whitelist, coins);
    }

    public fun whitelist_length(
        pool_whitelist: &RewardTokenWhitelistPerPool,
        pool_address: address
    ): u64 {
        if (!table::contains(&pool_whitelist.whitelist, pool_address)) {
            return 0
        };
        vec_set::size(table::borrow(&pool_whitelist.whitelist, pool_address))
    }

    public fun whitelist_native_fungible_assets(
        admin_cap: &TokenWhitelistAdminCap,
        whitelist: &mut TokenWhitelist,
        mut assets: vector<ID>
    ) {
        let mut asset_names = vector::empty<String>();
        vector::reverse(&mut assets);
        
        let mut assets_len = vector::length(&assets);
        while (assets_len > 0) {
            let ascii_string = coin_wrapper::format_fungible_asset(vector::pop_back(&mut assets));
            let string = string::from_ascii(ascii_string);
            vector::push_back(&mut asset_names, string);
            assets_len = assets_len - 1;
        };
        vector::destroy_empty(assets);
        
        add_to_whitelist(admin_cap, whitelist, asset_names);
    }

    public fun whitelisted_reward_token_per_pool(
        pool_whitelist: &RewardTokenWhitelistPerPool,
        pool_address: address
    ): vector<String> {
        if (!table::contains(&pool_whitelist.whitelist, pool_address)) {
            return vector::empty()
        };
        
        let pool_tokens = table::borrow(&pool_whitelist.whitelist, pool_address);
        let mut result = vector::empty();
        let tokens = vec_set::keys(pool_tokens);
        let mut i = 0;
        let len = vector::length(tokens);
        
        while (i < len) {
            vector::push_back(&mut result, *vector::borrow(tokens, i));
            i = i + 1;
        };
        
        result
    }

    public fun whitelisted_tokens(whitelist: &TokenWhitelist): vector<String> {
        let tokens_copy = vec_set::into_keys(whitelist.tokens);
        tokens_copy
    }

    // --- test helpers ---
    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(TOKEN_WHITELIST {}, ctx)
    }
}