#[test_only]
module sui_dex::minter_test {
    use sui::test_scenario::{Self as ts, next_tx};
    use sui::clock;
    use sui::coin;

    // --- modules ---
    use sui_dex::minter::{Self, MinterConfig, MinterAdminCap};
    use sui_dex::voting_escrow::{Self, VeSuiDexCollection, VeSuiDexToken};
    use sui_dex::suidex_token::{Self, SUIDEX_TOKEN, SuiDexManager};

    // --- addresses ---
    const OWNER: address = @sui_dex;
    const RECIPIENT: address = @0xcd;

    // --- params ---
    const MS_IN_WEEK: u64 = 604800000; // milliseconds in a week

    fun setup(): VeSuiDexToken<SUIDEX_TOKEN> {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;

        voting_escrow::init_for_testing(scenario.ctx());
        suidex_token::init_for_testing(ts::ctx(scenario));
        ts::end(scenario_val);

        let mut scenario_val1 = ts::begin(OWNER);
        let scenario1 = &mut scenario_val1;

        let mut collection = ts::take_shared<VeSuiDexCollection>(scenario1);
        let mut manager = ts::take_shared<SuiDexManager>(scenario1);
        let clock = clock::create_for_testing(ts::ctx(scenario1));
        minter::init_for_testing(ts::ctx(scenario1), &clock);
        
        next_tx(scenario1, OWNER);
        let admin_cap = ts::take_from_sender<MinterAdminCap>(scenario1);
        let ve_token = minter::initial_mint(&admin_cap, &mut manager, &mut collection, &clock, ts::ctx(scenario1));
        ts::return_shared(collection);
        ts::return_shared(manager);
        ts::return_to_sender(scenario1, admin_cap);
        clock::destroy_for_testing(clock);
        ts::end(scenario_val1);
        ve_token
    }

    #[test]
    fun test_initialize() {
        let ve_token = setup();
        assert!(voting_escrow::get_lockup_expiration_epoch(&ve_token) == voting_escrow::max_lockup_epochs(), 1);
        transfer::public_transfer(ve_token, OWNER);
    }

    #[test]
    fun test_mint() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let weekly_emission = 150000000000000;
        let ve_token = setup();
        assert!(voting_escrow::get_lockup_expiration_epoch(&ve_token) == voting_escrow::max_lockup_epochs(), 1);
        let mut clock = clock::create_for_testing(ts::ctx(scenario));
        clock.increment_for_testing(MS_IN_WEEK);
        let collection = ts::take_shared<VeSuiDexCollection>(scenario);
        let mut manager = ts::take_shared<SuiDexManager>(scenario);

        next_tx(scenario, OWNER);
        
        transfer::public_transfer(ve_token, OWNER);
        let mut minter_config = ts::take_shared<MinterConfig>(scenario);

        let (minted_tokens, additional_minted_tokens) = minter::mint(&mut minter_config, &mut manager, &collection, &clock, scenario.ctx());
        assert!(coin::value(&minted_tokens) > weekly_emission / 2, 2);
        assert!(coin::value(&additional_minted_tokens) > 0, 3);
        transfer::public_transfer(minted_tokens, OWNER);
        transfer::public_transfer(additional_minted_tokens, OWNER);

        ts::return_shared(manager);
        ts::return_shared(minter_config);
        ts::return_shared(collection);
        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }

    #[test]
    fun test_update_team_account() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let ve_token = setup();
        assert!(voting_escrow::get_lockup_expiration_epoch(&ve_token) == voting_escrow::max_lockup_epochs(), 1);

        let clock = clock::create_for_testing(ts::ctx(scenario));
        let collection = ts::take_shared<VeSuiDexCollection>(scenario);
        let mut minter_config = ts::take_shared<MinterConfig>(scenario);
        let admin_cap = ts::take_from_sender<MinterAdminCap>(scenario);

        next_tx(scenario, OWNER);
        minter::update_team_account(&admin_cap, &mut minter_config, RECIPIENT, ts::ctx(scenario));
        minter::confirm_new_team_account(&admin_cap, &mut minter_config, ts::ctx(scenario));
        assert!(minter::mitner_addres(&minter_config) == RECIPIENT, 4);

        transfer::public_transfer(ve_token, OWNER);
        ts::return_shared(minter_config);
        ts::return_to_sender(scenario, admin_cap);
        ts::return_shared(collection);
        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }

    #[test]
    fun test_update_team_rate() {
        let mut scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let ve_token = setup();
        assert!(voting_escrow::get_lockup_expiration_epoch(&ve_token) == voting_escrow::max_lockup_epochs(), 1);

        let clock = clock::create_for_testing(ts::ctx(scenario));
        let collection = ts::take_shared<VeSuiDexCollection>(scenario);
        let mut minter_config = ts::take_shared<MinterConfig>(scenario);
        let admin_cap = ts::take_from_sender<MinterAdminCap>(scenario);

        next_tx(scenario, OWNER);
        let new_rate_bps = 10;
        minter::set_team_rate(&admin_cap, &mut minter_config, new_rate_bps, ts::ctx(scenario));
        assert!(minter::team_emission_rate_bps(&minter_config) == new_rate_bps, 5);

        transfer::public_transfer(ve_token, OWNER);
        ts::return_shared(minter_config);
        ts::return_shared(collection);
        ts::return_to_sender(scenario, admin_cap);
        clock::destroy_for_testing(clock);
        ts::end(scenario_val);
    }
}