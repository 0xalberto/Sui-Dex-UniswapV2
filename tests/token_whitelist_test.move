#[test_only]
module sui_dex::token_whitelist_test {
    use std::string::{Self, String};
    use sui::test_scenario::{Self as ts, next_tx};
    use std::type_name;

    // --- modules ---
    use sui_dex::token_whitelist::{Self, TokenWhitelist, TokenWhitelistAdminCap, RewardTokenWhitelistPerPool};

    // --- errors ---
    const ERR_WHITELIST_SHOULD_CONTAIN: u64 = 0;
    const ERR_WRONG_WHITELIST_LENGTH: u64 = 1;

    // --- addresses ---
    const OWNER : address = @0xab;
    const POOL_ADDRESS: address = @0x32;

    // --- structs ---
    public struct TestCoin {}
    public struct TestRewardCoin {}

    fun setup() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;

        token_whitelist::init_for_testing(scenario.ctx());

        ts::end(scenario_val);
    }

    #[test]
    fun test_add_to_whitelist() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        
        next_tx(scenario, OWNER);
        {
            let admin_cap = ts::take_from_address<TokenWhitelistAdminCap>(
                scenario,
                OWNER
            );
            let mut whitelist = ts::take_shared<TokenWhitelist>(scenario);
            
            // create test tokens
            let mut tokens = vector::empty<String>();
            vector::push_back(&mut tokens, string::utf8(b"Token1"));
            vector::push_back(&mut tokens, string::utf8(b"Token2"));
            
            // add tokens to whitelist
            token_whitelist::add_to_whitelist(&admin_cap, &mut whitelist, tokens);
            
            // verify tokens were added
            assert!(token_whitelist::are_whitelisted(&whitelist, &tokens), 0);
            
            ts::return_to_address(OWNER, admin_cap);
            ts::return_shared(whitelist);
        };
        
        ts::end(scenario_val);
    }

    #[test]
    fun test_add_to_whitelist_duplicates() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        
        next_tx(scenario, OWNER);
        {
            let admin_cap = ts::take_from_address<TokenWhitelistAdminCap>(
                scenario,
                OWNER
            );
            let mut whitelist = ts::take_shared<TokenWhitelist>(scenario);
            
            // create test tokens
            let mut tokens = vector::empty<String>();
            vector::push_back(&mut tokens, string::utf8(b"Token1"));
            vector::push_back(&mut tokens, string::utf8(b"Token1"));
            vector::push_back(&mut tokens, string::utf8(b"Token2"));
            
            // add tokens to whitelist
            token_whitelist::add_to_whitelist(&admin_cap, &mut whitelist, tokens);
            
            // verify duplicates were handled (should only have 2 unique tokens)
            assert!(token_whitelist::are_whitelisted(&whitelist, &tokens), 0);
            
            ts::return_to_address(OWNER, admin_cap);
            ts::return_shared(whitelist);
        };
        
        ts::end(scenario_val);
    }

    #[test]
    fun test_whitelisted_reward_token_per_pool_empty() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;

        next_tx(scenario, OWNER);
        {
            let pool_whitelist = ts::take_shared<RewardTokenWhitelistPerPool>(scenario);

            // test getting tokens for non-existent pool
            let tokens = token_whitelist::whitelisted_reward_token_per_pool(
                &pool_whitelist,
                POOL_ADDRESS
            );
            
            // verify empty vector is returned
            assert!(vector::length(&tokens) == 0, ERR_WRONG_WHITELIST_LENGTH);

            ts::return_shared(pool_whitelist);
        };

        ts::end(scenario_val);
    }

    #[test]
    fun test_set_whitelist_reward_tokens() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;

        next_tx(scenario, OWNER);
        {
            let admin_cap = ts::take_from_address<TokenWhitelistAdminCap>(
                scenario,
                OWNER
            );
            let mut pool_whitelist = ts::take_shared<RewardTokenWhitelistPerPool>(scenario);

            // create test tokens
            let mut tokens = vector::empty<String>();
            vector::push_back(&mut tokens, string::utf8(b"Token1"));
            vector::push_back(&mut tokens, string::utf8(b"Token2"));

            // add tokens to whitelist
            token_whitelist::set_whitelist_reward_tokens(
                &admin_cap,
                &mut pool_whitelist,
                tokens,
                POOL_ADDRESS,
                true
            );

            let whitelisted_tokens = token_whitelist::whitelisted_reward_token_per_pool(
                &pool_whitelist,
                POOL_ADDRESS
            );
            
            // verify correct number of tokens returned
            assert!(vector::length(&whitelisted_tokens) == 2, ERR_WRONG_WHITELIST_LENGTH);
            
            // verify specific tokens are in the returned vector
            assert!(vector::contains(&whitelisted_tokens, &string::utf8(b"Token1")), ERR_WHITELIST_SHOULD_CONTAIN);
            assert!(vector::contains(&whitelisted_tokens, &string::utf8(b"Token2")), ERR_WHITELIST_SHOULD_CONTAIN);

            ts::return_to_address(OWNER, admin_cap);
            ts::return_shared(pool_whitelist);
        };

        ts::end(scenario_val);
    }

    #[test]
    fun test_set_whitelist_reward_token() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;

        next_tx(scenario, OWNER);
        {
            let admin_cap = ts::take_from_address<TokenWhitelistAdminCap>(
                scenario,
                OWNER
            );
            let mut pool_whitelist = ts::take_shared<RewardTokenWhitelistPerPool>(scenario);

            // add TestCoin type to whitelist
            token_whitelist::set_whitelist_reward_token<TestCoin>(
                &admin_cap,
                &mut pool_whitelist,
                POOL_ADDRESS,
                true
            );

            // verify the type was properly converted and added
            let length = token_whitelist::whitelist_length(&pool_whitelist, POOL_ADDRESS);
            assert!(length == 1, ERR_WRONG_WHITELIST_LENGTH);

            ts::return_to_address(OWNER, admin_cap);
            ts::return_shared(pool_whitelist);
        };

        ts::end(scenario_val);
    }

    #[test]
    fun test_whitelist_coin() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;

        next_tx(scenario, OWNER);
        {
            let admin_cap = ts::take_from_address<TokenWhitelistAdminCap>(
                scenario,
                OWNER
            );
            let mut whitelist = ts::take_shared<TokenWhitelist>(scenario);

            // whitelist TestCoin
            token_whitelist::whitelist_coin<TestCoin>(
                &admin_cap,
                &mut whitelist
            );

            // get the actual type string for TestCoin
            let type_string = type_name::get<TestCoin>();
            let ascii_string = type_name::into_string(type_string);
            let test_coin_string = string::from_ascii(ascii_string);

            // create a vector with just TestCoin
            let mut check_tokens = vector::empty<String>();
            vector::push_back(&mut check_tokens, test_coin_string);

            // verify TestCoin is whitelisted
            assert!(token_whitelist::are_whitelisted(&whitelist, &check_tokens), ERR_WHITELIST_SHOULD_CONTAIN);

            // add TestRewardCoin
            token_whitelist::whitelist_coin<TestRewardCoin>(
                &admin_cap,
                &mut whitelist
            );

            // get all whitelisted tokens and verify count
            let whitelisted_tokens = token_whitelist::whitelisted_tokens(&whitelist);
            assert!(vector::length(&whitelisted_tokens) == 2, ERR_WRONG_WHITELIST_LENGTH);

            ts::return_to_address(OWNER, admin_cap);
            ts::return_shared(whitelist);
        };

        ts::end(scenario_val);
    }
}