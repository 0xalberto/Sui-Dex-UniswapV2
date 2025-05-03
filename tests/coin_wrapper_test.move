#[test_only]
module sui_dex::coin_wrapper_test {
    use sui::test_scenario::{Self as ts, next_tx};
    use sui::coin::{Self, Coin};
    use std::type_name;

    // --- modules ---
    use sui_dex::coin_wrapper::{Self, WrapperStoreCap, COIN_WRAPPER, WrapperStore};
    
    // --- structs ---
    public struct USDT has drop {}
    public struct USDC has drop {}

    // --- errors ---
    const E_COIN_ALREADY_REGISTERED: u64 = 0;
    const E_REGISTRATION_FAILED: u64 = 1;
    const E_INCORRECT_ORIGINAL_COIN_TYPE: u64 = 2;
    const E_INCORRECT_WRAPPED_AMOUNT: u64 = 3;
    const E_INCORRECT_UNWRAPPED_AMOUNT: u64 = 4;
    const E_COIN_NOT_REGISTERED: u64 = 5;

    // --- addresses ---
    const OWNER : address = @0xab;

    fun setup() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;

        coin_wrapper::init_for_testing(scenario.ctx());

        ts::end(scenario_val);
    }

    // test register coin
    #[test]
    fun test_register() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;

        next_tx(scenario, OWNER);
        {
            let mut registry = ts::take_shared<WrapperStore>(scenario);
            let cap = ts::take_from_sender<WrapperStoreCap>(scenario);

            let usdt_type = type_name::get<USDT>().into_string();
            let usdc_type = type_name::get<USDC>().into_string();

            // assert coins are not registered initially
            assert!(!coin_wrapper::is_supported(&mut registry, &usdt_type), E_COIN_ALREADY_REGISTERED);
            assert!(!coin_wrapper::is_supported(&mut registry, &usdc_type), E_COIN_ALREADY_REGISTERED);

            coin_wrapper::register_coin_for_testing<USDT>(
                &cap,
                &mut registry,
                ts::ctx(scenario)
            );

            // assert USDT is now registered
            assert!(coin_wrapper::is_supported(&mut registry, &usdt_type), E_REGISTRATION_FAILED);

            coin_wrapper::register_coin_for_testing<USDC>(
                &cap,
                &mut registry,
                ts::ctx(scenario)
            );

            // assert USDC is now registered
            assert!(coin_wrapper::is_supported(&mut registry, &usdc_type), E_REGISTRATION_FAILED);

            // get wrapped asset data and verify it exists
            let usdt_wrapper = coin_wrapper::get_wrapped_data<USDT>(&registry);
            let usdc_wrapper = coin_wrapper::get_wrapped_data<USDC>(&registry);
            
            // verify original coin types match
            assert!(coin_wrapper::get_original_coin_type(usdt_wrapper) == usdt_type, E_INCORRECT_ORIGINAL_COIN_TYPE);
            assert!(coin_wrapper::get_original_coin_type(usdc_wrapper) == usdc_type, E_INCORRECT_ORIGINAL_COIN_TYPE);

            ts::return_shared(registry);
            ts::return_to_sender(scenario, cap);
        };

        ts::end(scenario_val);
    }

    // test wrap
    #[test]
    fun test_wrap() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        
        // register USDT
        next_tx(scenario, OWNER);
        {
            let mut registry = ts::take_shared<WrapperStore>(scenario);
            let cap = ts::take_from_sender<WrapperStoreCap>(scenario);
            
            coin_wrapper::register_coin_for_testing<USDT>(
                &cap,
                &mut registry,
                ts::ctx(scenario)
            );
            
            let usdt_type = type_name::get<USDT>().into_string();
            assert!(coin_wrapper::is_supported(&mut registry, &usdt_type), E_REGISTRATION_FAILED);
            
            ts::return_shared(registry);
            ts::return_to_sender(scenario, cap);
        };
        
        // create some test USDT coins and wrap them
        next_tx(scenario, OWNER);
        {
            let mut registry = ts::take_shared<WrapperStore>(scenario);
            
            // mint test USDT coins
            let mint_amount = 1000;
            let usdt_coin = coin::mint_for_testing<USDT>(mint_amount, ts::ctx(scenario));
            
            // verify initial coin amount
            assert!(coin::value(&usdt_coin) == mint_amount, E_INCORRECT_WRAPPED_AMOUNT);
            
            // wrap the USDT coins
            let wrapped_coin = coin_wrapper::wrap<USDT>(
                &mut registry,
                usdt_coin,
                ts::ctx(scenario)
            );
            
            // verify wrapped coin exists and has correct amount
            assert!(coin::value(&wrapped_coin) == mint_amount, E_INCORRECT_WRAPPED_AMOUNT);
            
            transfer::public_transfer(wrapped_coin, OWNER);    
            ts::return_shared(registry);
        };
        
        // verify the wrapped coins in owner's account
        next_tx(scenario, OWNER);
        {
            let wrapped_coin = ts::take_from_sender<Coin<COIN_WRAPPER>>(scenario);
            assert!(coin::value(&wrapped_coin) == 1000, E_INCORRECT_WRAPPED_AMOUNT);
            ts::return_to_sender(scenario, wrapped_coin);
        };

        ts::end(scenario_val);
    }

    // test unwrap
    #[test]
    fun test_unwrap() {
        setup();
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        
        // first register USDT and wrap some coins
        next_tx(scenario, OWNER);
        {
            let mut registry = ts::take_shared<WrapperStore>(scenario);
            let cap = ts::take_from_sender<WrapperStoreCap>(scenario);
            
            coin_wrapper::register_coin_for_testing<USDT>(
                &cap,
                &mut registry,
                ts::ctx(scenario)
            );
            
            let usdt_type = type_name::get<USDT>().into_string();
            assert!(coin_wrapper::is_supported(&mut registry, &usdt_type), E_REGISTRATION_FAILED);
            
            ts::return_shared(registry);
            ts::return_to_sender(scenario, cap);
        };
        
        // wrap some coins
        let mint_amount = 1000;
        next_tx(scenario, OWNER);
        {
            let mut registry = ts::take_shared<WrapperStore>(scenario);
            
            // create and wrap USDT
            let usdt_coin = coin::mint_for_testing<USDT>(mint_amount, ts::ctx(scenario));
            let wrapped_coin = coin_wrapper::wrap<USDT>(
                &mut registry,
                usdt_coin,
                ts::ctx(scenario)
            );
            
            // verify wrapped amount
            assert!(coin::value(&wrapped_coin) == mint_amount, E_INCORRECT_WRAPPED_AMOUNT);
            
            // transfer wrapped coin to owner
            transfer::public_transfer(wrapped_coin, OWNER);
            
            ts::return_shared(registry);
        };
        
        // test unwrapping
        next_tx(scenario, OWNER);
        {
            let mut registry = ts::take_shared<WrapperStore>(scenario);
            let wrapped_coin = ts::take_from_sender<Coin<COIN_WRAPPER>>(scenario);
            
            // verify wrapped coin amount before unwrap
            assert!(coin::value(&wrapped_coin) == mint_amount, E_INCORRECT_WRAPPED_AMOUNT);
            
            // unwrap the coin
            let unwrapped_coin = coin_wrapper::unwrap<USDT>(
                &mut registry,
                wrapped_coin
            );
            
            // verify unwrapped amount matches original
            assert!(coin::value(&unwrapped_coin) == mint_amount, E_INCORRECT_UNWRAPPED_AMOUNT);
            
            // transfer unwrapped coin back to owner
            transfer::public_transfer(unwrapped_coin, OWNER);
            
            ts::return_shared(registry);
        };
        
        // Verify the unwrapped coins in owner's account
        next_tx(scenario, OWNER);
        {
            let unwrapped_coin = ts::take_from_sender<Coin<USDT>>(scenario);
            assert!(coin::value(&unwrapped_coin) == mint_amount, E_INCORRECT_UNWRAPPED_AMOUNT);
            ts::return_to_sender(scenario, unwrapped_coin);
        };
        
        // Test unwrap failure cases
        next_tx(scenario, OWNER);
        {
            let mut registry = ts::take_shared<WrapperStore>(scenario);
            
            // try to unwrap USDC (not registered)
            let mut failed = false;
            if (!coin_wrapper::is_supported(&mut registry, &type_name::get<USDC>().into_string())) {
                failed = true;
            };
            assert!(failed, E_COIN_NOT_REGISTERED);
            
            ts::return_shared(registry);
        };
        
        // test multiple wrap/unwrap cycles
        next_tx(scenario, OWNER);
        {
            let mut registry = ts::take_shared<WrapperStore>(scenario);
            
            // create new USDT coins
            let usdt_coin = coin::mint_for_testing<USDT>(mint_amount, ts::ctx(scenario));
            
            // wrap
            let wrapped_coin = coin_wrapper::wrap<USDT>(
                &mut registry,
                usdt_coin,
                ts::ctx(scenario)
            );
            
            // unwrap immediately
            let unwrapped_coin = coin_wrapper::unwrap<USDT>(
                &mut registry,
                wrapped_coin
            );
            
            // verify amount preserved through wrap/unwrap cycle
            assert!(coin::value(&unwrapped_coin) == mint_amount, E_INCORRECT_UNWRAPPED_AMOUNT);
            
            transfer::public_transfer(unwrapped_coin, OWNER);        
            ts::return_shared(registry);
        };
        
        ts::end(scenario_val);
    }
}