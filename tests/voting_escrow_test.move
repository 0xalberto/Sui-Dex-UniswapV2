#[test_only]
module sui_dex::voting_escrow_test {
    use sui::test_scenario::{Self as ts, next_tx};
    use sui::clock;
    use sui::coin::{Self, Coin};

    // --- modules ---
    use sui_dex::voting_escrow::{Self, VeSuiDexCollection, VeSuiDexToken};
    use sui_dex::suidex_token::{Self, SUIDEX_TOKEN, SuiDexManager};
    use sui_dex::epoch;

    // --- addresses ---
    const OWNER: address = @0xab;
    const RECIPIENT: address = @0xcd;

    // --- params ---
    const AMOUNT: u64 = 1000;
    const LOCK_DURATION: u64 = 52;
    const MS_IN_WEEK: u64 = 604800000; // milliseconds in a week

    fun setup() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;

        voting_escrow::init_for_testing(scenario.ctx());
        suidex_token::init_for_testing(ts::ctx(scenario));

        ts::end(scenario_val);
    }

    //test create lock and withdraw by owner
    #[test]
    fun test_create_lock_and_withdraw_by_owner() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;

        setup();

        // setup clock
        let mut clock = clock::create_for_testing(ts::ctx(scenario));
        
        next_tx(scenario, OWNER);
        let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);

        // create a lock
        next_tx(scenario, OWNER);
        let coin = coin::mint_for_testing<SUIDEX_TOKEN>(AMOUNT, ts::ctx(scenario));
        let ve_token = voting_escrow::create_lock(
            coin,
            LOCK_DURATION,
            &mut collection,
            &clock,
            ts::ctx(scenario)
        );

        // assert initial state
        assert!(voting_escrow::get_lockup_expiration_epoch(&ve_token) == LOCK_DURATION, 1);
        assert!(voting_escrow::locked_amount(&ve_token) == AMOUNT, 2);

        // fast forward time to after lock period
        clock::increment_for_testing(&mut clock, ((LOCK_DURATION + 1) as u64) * MS_IN_WEEK);

        // assert lock has expired
        assert!(voting_escrow::remaining_lockup_epochs(&ve_token, &clock) == 0, 3);

        // try withdraw
        voting_escrow::withdraw_entry(
            OWNER,
            ve_token,
            &collection,
            &clock,
            ts::ctx(scenario)
        );
        
        // verify coins were transferred to owner
        next_tx(scenario, OWNER);
        let withdrawn_coins = ts::take_from_sender<Coin<SUIDEX_TOKEN>>(scenario);
        assert!(coin::value(&withdrawn_coins) == AMOUNT, 4);

        coin::burn_for_testing(withdrawn_coins);
        ts::return_shared(collection);
        clock::destroy_for_testing(clock);
        
        ts::end(scenario_val);
    }

    //test create lock for recipient and withdraw
    #[test]
    fun test_create_lock_for_recipient_and_withdraw() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        
        setup();
        
        // setup clock
        let mut clock = clock::create_for_testing(ts::ctx(scenario));
        
        let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
        
        // create a lock for recipient
        let coin = coin::mint_for_testing<SUIDEX_TOKEN>(AMOUNT, ts::ctx(scenario));
        voting_escrow::create_lock_for(
            coin,
            LOCK_DURATION,
            RECIPIENT,
            &mut collection,
            &clock,
            ts::ctx(scenario)
        );

        next_tx(scenario, RECIPIENT);
        let ve_token = ts::take_from_address<VeSuiDexToken<SUIDEX_TOKEN>>(scenario, RECIPIENT);
        
        // assert initial state for recipient's token
        assert!(voting_escrow::get_lockup_expiration_epoch(&ve_token) == LOCK_DURATION, 1);
        assert!(voting_escrow::locked_amount(&ve_token) == AMOUNT, 2);
        assert!(voting_escrow::remaining_lockup_epochs(&ve_token, &clock) == LOCK_DURATION, 3);
        
        // fast forward time to after lock period
        clock::set_for_testing(&mut clock, ((LOCK_DURATION + 1) as u64) * MS_IN_WEEK);
        
        // assert lock has expired
        assert!(voting_escrow::remaining_lockup_epochs(&ve_token, &clock) == 0, 4);
        
        // try withdraw as recipient
        voting_escrow::withdraw_entry(
            RECIPIENT,
            ve_token,
            &collection,
            &clock,
            ts::ctx(scenario)
        );
        
        // verify coins were transferred to recipient
        next_tx(scenario, RECIPIENT);
        let withdrawn_coins = ts::take_from_sender<Coin<SUIDEX_TOKEN>>(scenario);
        assert!(coin::value(&withdrawn_coins) == AMOUNT, 5);
        
        coin::burn_for_testing(withdrawn_coins);
        ts::return_shared(collection);
        clock::destroy_for_testing(clock);
        
        ts::end(scenario_val);
    }

    // test extend lock duration by owner
    #[test]
    fun test_extend_lock_duration_by_owner() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        
        setup();
        
        // setup clock
        let mut clock = clock::create_for_testing(ts::ctx(scenario));
        
        let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
        
        // create initial lock
        next_tx(scenario, OWNER);
        let coin = coin::mint_for_testing<SUIDEX_TOKEN>(AMOUNT, ts::ctx(scenario));
        let ve_token = voting_escrow::create_lock(
            coin,
            LOCK_DURATION,
            &mut collection,
            &clock,
            ts::ctx(scenario)
        );
        
        // assert initial state
        let initial_end_epoch = voting_escrow::get_lockup_expiration_epoch(&ve_token);
        assert!(initial_end_epoch == LOCK_DURATION, 1);
        assert!(voting_escrow::remaining_lockup_epochs(&ve_token, &clock) == LOCK_DURATION, 2);

        // transfer token to establish ownership
        transfer::public_transfer(ve_token, OWNER);
        
        next_tx(scenario, OWNER);
        {
            let mut ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
        
            // fast forward time to near end of lock (but not expired)
            clock::set_for_testing(&mut clock, (LOCK_DURATION - 10) * MS_IN_WEEK);
            assert!(voting_escrow::remaining_lockup_epochs(&ve_token, &clock) == LOCK_DURATION - 42 , 2);

            // extend lock duration
            let extension = 52; // extend by another year
            voting_escrow::extend_lockup(
                OWNER,
                &mut ve_token,
                extension,
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );
            
            // verify extension
            let new_end_epoch = voting_escrow::get_lockup_expiration_epoch(&ve_token);

            assert!(voting_escrow::remaining_lockup_epochs(&ve_token, &clock) == 52, 4);
            assert!(new_end_epoch > initial_end_epoch, 3);
            
            
            ts::return_to_sender(scenario, ve_token);
            
            ts::return_shared(collection);
            clock::destroy_for_testing(clock);
        };
        
        ts::end(scenario_val);
    }

    // test extend lock duration by recipient
    #[test]
    fun test_extend_lock_duration_by_recipient() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        
        setup();
        
        // setup clock
        let mut clock = clock::create_for_testing(ts::ctx(scenario));
        
        let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
        
        // create initial lock for recipient
        next_tx(scenario, OWNER);
        let coin = coin::mint_for_testing<SUIDEX_TOKEN>(AMOUNT, ts::ctx(scenario));
        voting_escrow::create_lock_for(
            coin,
            LOCK_DURATION,
            RECIPIENT,
            &mut collection,
            &clock,
            ts::ctx(scenario)
        );
        
        next_tx(scenario, RECIPIENT);
        {
            let ve_token = ts::take_from_address<VeSuiDexToken<SUIDEX_TOKEN>>(scenario, RECIPIENT);
            
            // assert initial state
            let initial_end_epoch = voting_escrow::get_lockup_expiration_epoch(&ve_token);
            assert!(initial_end_epoch == LOCK_DURATION, 1);
            assert!(voting_escrow::remaining_lockup_epochs(&ve_token, &clock) == LOCK_DURATION, 2);

            // return token to establish ownership
            ts::return_to_address(RECIPIENT, ve_token);
        };
        
        next_tx(scenario, RECIPIENT);
        {
            let mut ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            let initial_end_epoch = voting_escrow::get_lockup_expiration_epoch(&ve_token);
        
            // fast forward time to near end of lock (but not expired)
            clock::set_for_testing(&mut clock, (LOCK_DURATION - 10) * MS_IN_WEEK);
            assert!(voting_escrow::remaining_lockup_epochs(&ve_token, &clock) == LOCK_DURATION - 42 , 3);

            // extend lock duration
            let extension = 52; // extend by another year
            voting_escrow::extend_lockup(
                RECIPIENT,  // Recipient extends their own lock
                &mut ve_token,
                extension,
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );
            
            // verify extension
            let new_end_epoch = voting_escrow::get_lockup_expiration_epoch(&ve_token);
            
            assert!(voting_escrow::remaining_lockup_epochs(&ve_token, &clock) == 52, 4);
            assert!(new_end_epoch > initial_end_epoch, 5);
            
            ts::return_to_sender(scenario, ve_token);
        };
        
        ts::return_shared(collection);
        clock::destroy_for_testing(clock);
        
        ts::end(scenario_val);
    }

    #[test]
    fun test_increase_amount_entry() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        
        setup();
        
        // setup clock
        let clock = clock::create_for_testing(ts::ctx(scenario));
        
        let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
        let mut manager = ts::take_shared<SuiDexManager>(scenario);
        
        // create initial lock
        next_tx(scenario, OWNER);
        let coin = coin::mint_for_testing<SUIDEX_TOKEN>(AMOUNT, ts::ctx(scenario));
        let ve_token = voting_escrow::create_lock(
            coin,
            LOCK_DURATION,
            &mut collection,
            &clock,
            ts::ctx(scenario)
        );
        
        // assert initial state
        assert!(voting_escrow::get_lockup_expiration_epoch(&ve_token) == LOCK_DURATION, 1);
        assert!(voting_escrow::locked_amount(&ve_token) == AMOUNT, 2);

        // transfer token to establish ownership
        transfer::public_transfer(ve_token, OWNER);
        
        next_tx(scenario, OWNER);
        {
            let mut ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
        
            // increase amount
            let additional_amount = 500;
            voting_escrow::increase_amount_entry(
                OWNER,
                &mut ve_token,
                additional_amount,
                &mut manager,
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );
            
            // verify new amount
            assert!(voting_escrow::locked_amount(&ve_token) == AMOUNT + additional_amount, 3);
            
            // verify lock duration remained same
            assert!(voting_escrow::get_lockup_expiration_epoch(&ve_token) == LOCK_DURATION, 4);
            
            ts::return_to_sender(scenario, ve_token);
        };
        
        ts::return_shared(collection);
        ts::return_shared(manager);
        clock::destroy_for_testing(clock);
        
        ts::end(scenario_val);
    }

    #[test]
    fun test_increase_amount_entry_by_recipient() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        
        setup();
        
        // setup clock
        let mut clock = clock::create_for_testing(ts::ctx(scenario));
        
        let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
        let mut manager = ts::take_shared<SuiDexManager>(scenario);
        
        // create initial lock for recipient
        next_tx(scenario, OWNER);
        let coin = coin::mint_for_testing<SUIDEX_TOKEN>(AMOUNT, ts::ctx(scenario));
        voting_escrow::create_lock_for(
            coin,
            LOCK_DURATION,
            RECIPIENT,
            &mut collection,
            &clock,
            ts::ctx(scenario)
        );

        next_tx(scenario, RECIPIENT);
        {
            let mut ve_token = ts::take_from_address<VeSuiDexToken<SUIDEX_TOKEN>>(scenario, RECIPIENT);
            
            // assert initial state
            assert!(voting_escrow::locked_amount(&ve_token) == AMOUNT, 1);
            assert!(voting_escrow::get_lockup_expiration_epoch(&ve_token) == LOCK_DURATION, 2);
            
            // increase amount as recipient
            let additional_amount = 500;
            voting_escrow::increase_amount_entry(
                RECIPIENT,
                &mut ve_token,
                additional_amount,
                &mut manager,
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );
            
            // verify new amount
            assert!(voting_escrow::locked_amount(&ve_token) == AMOUNT + additional_amount, 3);
            
            // verify lock duration remained same
            assert!(voting_escrow::get_lockup_expiration_epoch(&ve_token) == LOCK_DURATION, 4);

            ts::return_to_address(RECIPIENT, ve_token);
        };
        
        // test increasing amount when lock is about to expire
        next_tx(scenario, RECIPIENT); 
        {
            let mut ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            
            // fast forward time to near end of lock (but not expired)
            clock::set_for_testing(&mut clock, (LOCK_DURATION - 1) * MS_IN_WEEK);
            
            // try increasing amount near expiry
            let additional_amount = 300;
            voting_escrow::increase_amount_entry(
                RECIPIENT,
                &mut ve_token,
                additional_amount,
                &mut manager, 
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );
            
            // verify final amount
            assert!(voting_escrow::locked_amount(&ve_token) == AMOUNT + 500 + additional_amount, 5);
            
            ts::return_to_sender(scenario, ve_token);
        };
        
        ts::return_shared(collection);
        ts::return_shared(manager);
        clock::destroy_for_testing(clock);
        
        ts::end(scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = voting_escrow::E_LOCK_EXPIRED)]
    fun test_increase_amount_entry_fails_when_expired() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        
        setup();
        
        // setup clock
        let mut clock = clock::create_for_testing(ts::ctx(scenario));
        
        let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
        let mut manager = ts::take_shared<SuiDexManager>(scenario);
        
        // create initial lock
        next_tx(scenario, OWNER);
        let coin = coin::mint_for_testing<SUIDEX_TOKEN>(AMOUNT, ts::ctx(scenario));
        let ve_token = voting_escrow::create_lock(
            coin,
            LOCK_DURATION,
            &mut collection,
            &clock,
            ts::ctx(scenario)
        );

        // transfer token to establish ownership 
        transfer::public_transfer(ve_token, OWNER);
        
        next_tx(scenario, OWNER);
        {
            let mut ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            
            // fast forward time to after lock expiry
            clock::set_for_testing(&mut clock, (LOCK_DURATION + 1) * MS_IN_WEEK);
            
            // try to increase amount when expired - should fail
            voting_escrow::increase_amount_entry(
                OWNER,
                &mut ve_token,
                500,
                &mut manager,
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );
            
            ts::return_to_sender(scenario, ve_token);
        };
        
        ts::return_shared(collection);
        ts::return_shared(manager);
        clock::destroy_for_testing(clock);
        
        ts::end(scenario_val);
    }

    #[test]
    fun test_claim_rebase() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        
        setup();
        
        // setup clock
        let mut clock = clock::create_for_testing(ts::ctx(scenario));
        
        let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
        let mut manager = ts::take_shared<SuiDexManager>(scenario);
        
        // create initial lock
        next_tx(scenario, OWNER);
        let coin = coin::mint_for_testing<SUIDEX_TOKEN>(AMOUNT, ts::ctx(scenario));
        let ve_token = voting_escrow::create_lock(
            coin,
            LOCK_DURATION,
            &mut collection,
            &clock,
            ts::ctx(scenario)
        );
        
        // transfer token to establish ownership
        transfer::public_transfer(ve_token, OWNER);
        
        next_tx(scenario, OWNER);
        {
            let mut ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            
            // initial state
            let initial_amount = voting_escrow::locked_amount(&ve_token);
            let initial_next_rebase = voting_escrow::next_rebase_epoch(&ve_token);
            
            // fast forward time to create gap for rebase
            clock::increment_for_testing(&mut clock, MS_IN_WEEK);
            let current_epoch = epoch::now(&clock);
            
            // setup rebase state for previous epoch
            voting_escrow::add_fake_rebase(
                &mut collection,
                initial_next_rebase, // use token's next_rebase_epoch
                100, // rebase amount
                &clock // total voting power
            );
            
            // verify there is claimable amount before claiming
            let claimable_before = voting_escrow::claimable_rebase(&ve_token, &collection, &clock);
            assert!(claimable_before == 100, 0); // make sure we have something to claim
            
            // claim rebase
            voting_escrow::claim_rebase(
                OWNER,
                &mut ve_token,
                &mut collection,
                &mut manager,
                &clock,
                ts::ctx(scenario)
            );
            
            // verify amount increased by claimable amount
            let final_amount = voting_escrow::locked_amount(&ve_token);
            assert!(final_amount == initial_amount + claimable_before, 1);
            
            // verify next_rebase_epoch updated to current epoch
            assert!(voting_escrow::next_rebase_epoch(&ve_token) == current_epoch, 2);
            
            ts::return_to_sender(scenario, ve_token);
        };
        
        ts::return_shared(collection);
        ts::return_shared(manager);
        clock::destroy_for_testing(clock);
        
        ts::end(scenario_val);
    }

    #[test]
    fun test_merge_ve_nft() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        
        setup();
        
        // setup clock
        let clock = clock::create_for_testing(ts::ctx(scenario));
        
        let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
        
        // create first token (source)
        next_tx(scenario, OWNER);
        {
            let coin1 = coin::mint_for_testing<SUIDEX_TOKEN>(AMOUNT, ts::ctx(scenario));
            let source_token = voting_escrow::create_lock(
                coin1,
                LOCK_DURATION,
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );
            transfer::public_transfer(source_token, OWNER);
        };

        // create second token (target) with different amount and duration
        next_tx(scenario, OWNER);
        {
            let coin2 = coin::mint_for_testing<SUIDEX_TOKEN>(AMOUNT * 2, ts::ctx(scenario));
            let target_token = voting_escrow::create_lock(
                coin2,
                LOCK_DURATION + 10, // longer duration
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );
            transfer::public_transfer(target_token, OWNER);
        };

        next_tx(scenario, OWNER);
        {
            let source_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            let mut target_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);

            // initial states
            let source_amount = voting_escrow::locked_amount(&source_token);
            let source_end_epoch = voting_escrow::get_lockup_expiration_epoch(&source_token);
            
            let target_amount = voting_escrow::locked_amount(&target_token);
            let target_end_epoch = voting_escrow::get_lockup_expiration_epoch(&target_token);
            
            // merge tokens
            voting_escrow::merge_ve_nft(
                OWNER,
                source_token, // source token consumed
                &mut target_token,
                &mut collection,
                &clock,
                scenario.ctx()
            );

            // verify merged amounts
            assert!(voting_escrow::locked_amount(&target_token) == source_amount + target_amount, 1);

            // verify end epoch (should keep longer duration)
            let final_end_epoch = voting_escrow::get_lockup_expiration_epoch(&target_token);
            assert!(final_end_epoch == if (source_end_epoch > target_end_epoch) { 
                source_end_epoch 
            } else { 
                target_end_epoch 
            }, 2);

            ts::return_to_sender(scenario, target_token);
        };

        ts::return_shared(collection);
        clock::destroy_for_testing(clock);
        
        ts::end(scenario_val);
    }

    #[test]
    fun test_split_ve_nft() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        
        setup();
        
        // setup clock
        let clock = clock::create_for_testing(ts::ctx(scenario));
        
        let mut collection = ts::take_shared<VeSuiDexCollection>(scenario);
        
        // create initial token to split
        next_tx(scenario, OWNER);
        let initial_amount = 3000; // 3000 tokens to split
        let coin = coin::mint_for_testing<SUIDEX_TOKEN>(initial_amount, ts::ctx(scenario));
        let ve_token = voting_escrow::create_lock(
            coin,
            LOCK_DURATION,
            &mut collection,
            &clock,
            ts::ctx(scenario)
        );
        
        // transfer token to establish ownership
        transfer::public_transfer(ve_token, OWNER);
        
        next_tx(scenario, OWNER);
        {
            let ve_token = ts::take_from_sender<VeSuiDexToken<SUIDEX_TOKEN>>(scenario);
            
            // create split amounts vector [900, 900, 1200]
            // last amount should be larger to account for remaining balance
            let mut split_amounts = vector::empty<u64>();
            vector::push_back(&mut split_amounts, 900);
            vector::push_back(&mut split_amounts, 900);
            vector::push_back(&mut split_amounts, 1200);
            
            // Split the token
            let mut new_tokens = voting_escrow::split_ve_nft(
                OWNER,
                ve_token,
                split_amounts,
                &mut collection,
                &clock,
                ts::ctx(scenario)
            );
            
            // verify number of new tokens
            assert!(vector::length(&new_tokens) == 3, 1);

            // verify exact amounts of each token
            let first_token = vector::borrow(&new_tokens, 0);
            let second_token = vector::borrow(&new_tokens, 1);
            let third_token = vector::borrow(&new_tokens, 2);
            
            assert!(voting_escrow::locked_amount(first_token) == 900, 4);
            assert!(voting_escrow::locked_amount(second_token) == 900, 5);
            assert!(voting_escrow::locked_amount(third_token) == 1200, 6);
            
            // verify total amount equals initial amount
            let mut total_amount = 0;
            let mut i = 0;
            while (i < vector::length(&new_tokens)) {
                let token = vector::borrow(&new_tokens, i);
                total_amount = total_amount + voting_escrow::locked_amount(token);
                assert!(voting_escrow::get_lockup_expiration_epoch(token) == LOCK_DURATION, 3);
                i = i + 1;
            };
            assert!(total_amount == initial_amount, 2);

            // transfer tokens back to owner
            while (!vector::is_empty(&new_tokens)) {
                transfer::public_transfer(vector::pop_back(&mut new_tokens), OWNER);
            };
            
            vector::destroy_empty(new_tokens);
        };
        
        ts::return_shared(collection);
        clock::destroy_for_testing(clock);
        
        ts::end(scenario_val);
    }
}