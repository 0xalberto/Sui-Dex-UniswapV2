module sui_dex::voting_escrow {
    use std::string::{Self, String};
    use sui::table::{Self, Table};
    use sui::coin::{Self, Coin};
    use sui::clock::Clock;
    use sui::package;
    use sui::display;
    use sui::balance::{Self, Balance};

    use sui_dex::suidex_token::{Self, SUIDEX_TOKEN, SuiDexManager};
    use sui_dex::epoch;

    // --- errors ---
    const E_NOT_OWNER: u64 = 0;
    const E_INVALID_UPDATE: u64 = 1;
    const E_ZERO_AMOUNT: u64 = 2;
    const E_LOCK_EXPIRED: u64 = 3;
    const E_PENDING_REBASE: u64 = 4;
    const E_ZERO_TOTAL_POWER: u64 = 5;
    const E_EPOCH_NOT_ENDED: u64 = 6;
    const E_LOCK_DURATION_TOO_SHORT: u64 = 7;
    const E_LOCK_DURATION_TOO_LONG: u64 = 8;
    const E_INVALID_EXTENSION: u64 = 9;
    const E_NO_SNAPSHOT_FOUND: u64 = 10;
    const E_INVALID_SPLIT_AMOUNTS: u64 = 11;
    const E_TABLE_ENTRY_NOT_FOUND: u64 = 12;
    const E_INVALID_EPOCH: u64 = 13;

    // --- collection specific constants ---
    const COLLECTION_NAME: vector<u8> = b"SuiDex Voting Tokens";
    const COLLECTION_DESCRIPTION: vector<u8> = b"SuiDex Voting Tokens";
    const COLLECTION_URI_BASE: vector<u8> = b"https://api.SuiDex.finance/api/v1/ve-nft/uri/";

    // --- structs ---
    // otw
    public struct VOTING_ESCROW has drop {}

    public struct TokenSnapshot has store, drop, copy {
        epoch: u64,
        locked_amount: u64,
        end_epoch: u64,
    }

    public struct VeSuiDexCollection has key {
        id: UID,
        unscaled_total_voting_power_per_epoch: Table<u64, u128>,
        rebases: Table<u64, u64>,
    }

    public struct VeSuiDexToken<phantom SUIDEX_TOKEN> has key, store {
        id: UID,
        owner: address,
        locked_amount: u64,
        end_epoch: u64,
        snapshots: vector<TokenSnapshot>,
        next_rebase_epoch: u64,
        locked_coins: Balance<SUIDEX_TOKEN>
    }

    public struct CollectionData has key {
        id: UID,
        name: String,
        description: String,
        uri_base: String,
    }

    public struct Frozen<phantom SUIDEX_TOKEN> has key {
        id: UID,
        token: VeSuiDexToken<SUIDEX_TOKEN>
    }

    public struct AdminCap has key {
        id: UID
    }

    // init
    fun init(otw: VOTING_ESCROW, ctx: &mut TxContext) {
        // create the collection data
        let collection = CollectionData {
            id: object::new(ctx),
            name: string::utf8(COLLECTION_NAME),
            description: string::utf8(COLLECTION_DESCRIPTION),
            uri_base: string::utf8(COLLECTION_URI_BASE),
        };
        
        // create the Display object for NFT metadata
        let publisher = package::claim(otw, ctx);
        
        let display = display::new_with_fields<VeSuiDexToken<SUIDEX_TOKEN>>(
            &publisher,
            vector[
                string::utf8(b"name"),
                string::utf8(b"description"),
                string::utf8(b"image_url"),
            ],
            vector[
                // template for token display properties
                string::utf8(b"SuiDex Voting Token #{id}"),
                string::utf8(b"Locked tokens: {locked_amount}"),
                string::utf8(COLLECTION_URI_BASE),
            ],
            ctx
        );
        
        // transfer the collection data object
        transfer::share_object(collection);
        
        // create admin capability
        transfer::transfer(
            AdminCap { id: object::new(ctx) },
            tx_context::sender(ctx)
        );
        
        // create collection state
        let collection_state = VeSuiDexCollection {
            id: object::new(ctx),
            unscaled_total_voting_power_per_epoch: table::new(ctx),
            rebases: table::new(ctx),
        };
        
        transfer::share_object(collection_state);
        transfer::public_transfer(display, ctx.sender());
        transfer::public_transfer(publisher, ctx.sender())
    }

    public fun withdraw(
        account: address,
        ve_token: VeSuiDexToken<SUIDEX_TOKEN>, 
        collection: &VeSuiDexCollection,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<SUIDEX_TOKEN> {
        let claimable = claimable_rebase(&ve_token, collection, clock);
        assert!(claimable == 0, E_PENDING_REBASE);
        
        assert!(tx_context::sender(ctx) == account, E_NOT_OWNER);
        assert!(ve_token.end_epoch <= epoch::now(clock), E_EPOCH_NOT_ENDED);

        let VeSuiDexToken {
            id,
            owner: _,
            locked_amount: _,
            end_epoch,
            snapshots,
            next_rebase_epoch: _,
            mut locked_coins,
        } = ve_token;    

        let amount = balance::value(&locked_coins);

        //let coins = suidex_token::withdraw(manager, amount, ctx);
        let coins = coin::take(&mut locked_coins, amount, ctx);
        
        let empty_balance = balance::withdraw_all(&mut locked_coins);

        balance::destroy_zero(empty_balance);
        object::delete(id);

        destroy_snapshots(snapshots);
        balance::destroy_zero(locked_coins);
        
        assert!(end_epoch <= epoch::now(clock), E_EPOCH_NOT_ENDED);
        coins
    }

    public entry fun withdraw_entry (
        account: address,
        ve_token: VeSuiDexToken<SUIDEX_TOKEN>,
        collection: &VeSuiDexCollection,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let withdrawn_coins = withdraw(
            account,
            ve_token,
            collection,
            clock,
            ctx
        );

        transfer::public_transfer(withdrawn_coins, account)
    }

    fun destroy_snapshots(mut snapshots: vector<TokenSnapshot>) {
        while (!vector::is_empty(&snapshots)) {
            vector::pop_back(&mut snapshots);
        };
        vector::destroy_empty(snapshots);
    }

    public fun claimable_rebase(
        ve_token: &VeSuiDexToken<SUIDEX_TOKEN>,
        collection: &VeSuiDexCollection,
        clock: &Clock
    ): u64 {
        claimable_rebase_internal(ve_token, collection, clock)
    }

    public entry fun claim_rebase(
        account: address,
        ve_token: &mut VeSuiDexToken<SUIDEX_TOKEN>,
        collection: &mut VeSuiDexCollection,
        manager: &mut SuiDexManager,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == account, E_NOT_OWNER);
        
        let claimable = claimable_rebase_internal(ve_token, collection, clock);
        
        if (claimable > 0) {
            let rebase_coins = suidex_token::withdraw(manager, claimable, ctx);
            
            increase_amount_rebase(
                ve_token,
                rebase_coins,
                collection,
                clock,
            );
            
            ve_token.next_rebase_epoch = epoch::now(clock);
        }
    }

    public fun add_rebase(
        collection: &mut VeSuiDexCollection,
        amount: u64,
        epoch_number: u64,
        clock: &Clock,
    ) {
        assert!(epoch_number < epoch::now(clock), E_INVALID_EPOCH);
        assert!(amount > 0, E_ZERO_AMOUNT);
        table::add(&mut collection.rebases, epoch_number, amount);
    }

    fun claimable_rebase_internal(
        ve_token: &VeSuiDexToken<SUIDEX_TOKEN>,
        collection: &VeSuiDexCollection,
        clock: &Clock,
    ): u64 {
        let mut next_rebase_epoch = ve_token.next_rebase_epoch;
        let mut total_claimable: u128 = 0;

        while (next_rebase_epoch < epoch::now(clock)) {
            let epoch_rebase = if (table::contains(&collection.rebases, next_rebase_epoch)) {
                (*table::borrow(&collection.rebases, next_rebase_epoch) as u128)
            } else {
                0
            };

            if (epoch_rebase > 0) {
                let user_voting_power = get_voting_power_at_epoch(ve_token, next_rebase_epoch, clock);
                let total_voting_power_table = &collection.unscaled_total_voting_power_per_epoch;
                
                let total_voting_power = if (!table::contains(total_voting_power_table, next_rebase_epoch)) {
                    0
                } else {
                    *table::borrow(total_voting_power_table, next_rebase_epoch) / (104 as u128)
                };

                assert!(total_voting_power != 0, E_ZERO_TOTAL_POWER);
                
                let user_power_u256 = (user_voting_power as u256);
                let epoch_rebase_u256 = (epoch_rebase as u256);
                let total_power_u256 = (total_voting_power as u256);
                
                total_claimable = total_claimable + ((user_power_u256 * epoch_rebase_u256 / total_power_u256) as u128);
            };
            
            next_rebase_epoch = next_rebase_epoch + 1;
        };

        (total_claimable as u64)
    }

    public fun get_voting_power(
        ve_token: &VeSuiDexToken<SUIDEX_TOKEN>,
        clock: &Clock
    ): u64 {
        get_voting_power_at_epoch(ve_token, epoch::now(clock), clock)
    }

    public fun get_voting_power_at_epoch(
        ve_token: &VeSuiDexToken<SUIDEX_TOKEN>,
        target_epoch: u64,
        clock: &Clock,
    ): u64 {
        let (locked_amount, end_epoch) = if (target_epoch == epoch::now(clock)) {
            (ve_token.locked_amount, ve_token.end_epoch)
        } else {
            let snapshots = &ve_token.snapshots;
            let mut snapshot_index = vector::length(snapshots);
            while (snapshot_index > 0 && vector::borrow(snapshots, snapshot_index - 1).epoch > target_epoch) {
                snapshot_index = snapshot_index - 1;
            };
            assert!(snapshot_index > 0, E_NO_SNAPSHOT_FOUND);
            let snapshot = vector::borrow(snapshots, snapshot_index - 1);
            (snapshot.locked_amount, snapshot.end_epoch)
        };

        if (end_epoch <= target_epoch) {
            0
        } else {
            locked_amount * (end_epoch - target_epoch) / 104
        }
    }

    public fun create_lock(
        coin: Coin<SUIDEX_TOKEN>,
        lock_duration: u64,
        collection: &mut VeSuiDexCollection,
        clock: &Clock,
        ctx: &mut TxContext
    ): VeSuiDexToken<SUIDEX_TOKEN> {
        create_lock_with(
            coin,
            lock_duration,
            tx_context::sender(ctx),
            collection,
            clock,
            ctx
        )
    }

    public entry fun create_lock_for(
        coin: Coin<SUIDEX_TOKEN>,
        lock_duration: u64,
        recipient: address,
        collection: &mut VeSuiDexCollection,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let ve_token = create_lock_with(
            coin,
            lock_duration,
            recipient,  // Pass recipient address
            collection,
            clock,
            ctx
        );
        transfer::transfer(ve_token, recipient);
    }

    public fun create_lock_with(
        coin: Coin<SUIDEX_TOKEN>,
        lock_duration: u64,
        _recipient: address,
        collection: &mut VeSuiDexCollection,
        clock: &Clock,
        ctx: &mut TxContext
    ): VeSuiDexToken<SUIDEX_TOKEN> {
        let amount = coin::value(&coin);
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(lock_duration >= 2, E_LOCK_DURATION_TOO_SHORT);
        assert!(lock_duration <= 104, E_LOCK_DURATION_TOO_LONG);

        let end_epoch = epoch::now(clock) + lock_duration;
        
        // create veToken
        let mut ve_token = VeSuiDexToken {
            id: object::new(ctx),
            owner: ctx.sender(),
            locked_amount: amount,
            end_epoch,
            snapshots: vector::empty(),
            next_rebase_epoch: epoch::now(clock),
            locked_coins: coin::into_balance(coin)
        };

        update_snapshots(&mut ve_token, amount, end_epoch, clock);

        update_manifested_total_supply(
            0, 
            0,
            amount,
            end_epoch,
            collection,
            clock
        );

        ve_token
    }

    public fun update_snapshots(
        token: &mut VeSuiDexToken<SUIDEX_TOKEN>, 
        locked_amount: u64, 
        end_epoch: u64,
        clock: &Clock,
    ) {
        let snapshots = &mut token.snapshots;
        let current_epoch = epoch::now(clock);
        let snapshot_count = vector::length(snapshots);
        
        if (snapshot_count == 0 || vector::borrow(snapshots, snapshot_count - 1).epoch < current_epoch) {
            let new_snapshot = TokenSnapshot {
                epoch: current_epoch,
                locked_amount,
                end_epoch,
            };
            vector::push_back(snapshots, new_snapshot);
        } else {
            let last_snapshot = vector::borrow_mut(snapshots, snapshot_count - 1);
            last_snapshot.locked_amount = locked_amount;
            last_snapshot.end_epoch = end_epoch;
        };
    }

    fun update_manifested_total_supply(
        old_amount: u64,
        old_end_epoch: u64,
        new_amount: u64,
        new_end_epoch: u64,
        collection: &mut VeSuiDexCollection,
        clock: &Clock,
    ) {
        assert!(new_amount > old_amount || new_end_epoch > old_end_epoch, E_INVALID_UPDATE);
        
        let mut current_epoch = epoch::now(clock);
        let manifested_supply = &mut collection.unscaled_total_voting_power_per_epoch;
        
        while (current_epoch < new_end_epoch) {
            let old_value = if (old_amount == 0 || old_end_epoch <= current_epoch) {
                0
            } else {
                old_amount * (old_end_epoch - current_epoch)
            };

            let new_supply = (new_amount * (new_end_epoch - current_epoch) - old_value) as u128;

            if (table::contains(manifested_supply, current_epoch)) {
                let supply = table::borrow_mut(manifested_supply, current_epoch);
                *supply = *supply + new_supply;
            } else {
                table::add(manifested_supply, current_epoch, new_supply);
            };
            
            current_epoch = current_epoch + 1;
        };
    }

    public entry fun extend_lockup(
        account: address,
        ve_token: &mut VeSuiDexToken<SUIDEX_TOKEN>,
        extension_duration: u64,
        collection: &mut VeSuiDexCollection,
        clock: &Clock,
        ctx: &mut TxContext
    ) {

        assert!(extension_duration >= 2, E_LOCK_DURATION_TOO_SHORT);
        assert!(extension_duration <= 104, E_LOCK_DURATION_TOO_SHORT);
        
        assert!(tx_context::sender(ctx) == account, E_NOT_OWNER);
        
        let old_end_epoch = ve_token.end_epoch;
        let new_end_epoch = epoch::now(clock) + extension_duration;
        
        assert!(new_end_epoch > old_end_epoch, E_INVALID_EXTENSION);
        
        ve_token.end_epoch = new_end_epoch;
        let locked_amount = ve_token.locked_amount;
        
        update_snapshots(ve_token, locked_amount, new_end_epoch, clock);
        update_manifested_total_supply(
            locked_amount,
            old_end_epoch,
            locked_amount,
            new_end_epoch,
            collection,
            clock
        );
    }

    public fun get_lockup_expiration_epoch(ve_token: &VeSuiDexToken<SUIDEX_TOKEN>): u64 {
        ve_token.end_epoch
    }

    public fun get_lockup_expiration_time(ve_token: &VeSuiDexToken<SUIDEX_TOKEN>): u64 {
        let expiration_epoch = get_lockup_expiration_epoch(ve_token);
        expiration_epoch * 604800
    }

    public fun increase_amount(
        account: address,
        ve_token: &mut VeSuiDexToken<SUIDEX_TOKEN>,
        additional_coin: Coin<SUIDEX_TOKEN>,
        collection: &mut VeSuiDexCollection,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == account, E_NOT_OWNER);
        increase_amount_internal(ve_token, additional_coin, collection, clock);
    }


    public entry fun increase_amount_entry(
        account: address,
        ve_token: &mut VeSuiDexToken<SUIDEX_TOKEN>,
        amount: u64,
        manager: &mut SuiDexManager,
        collection: &mut VeSuiDexCollection,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let additional_coin = suidex_token::withdraw(manager, amount, ctx);
        increase_amount(account, ve_token, additional_coin, collection, clock, ctx);
    }

    fun increase_amount_internal(
        ve_token: &mut VeSuiDexToken<SUIDEX_TOKEN>,
        additional_coin: Coin<SUIDEX_TOKEN>,
        collection: &mut VeSuiDexCollection,
        clock: &Clock
    ) {
        assert!(ve_token.end_epoch > epoch::now(clock), E_LOCK_EXPIRED);
        
        let additional_amount = coin::value(&additional_coin);
        assert!(additional_amount > 0, E_ZERO_AMOUNT);
        
        let old_amount = ve_token.locked_amount;
        let new_amount = old_amount + additional_amount;
        ve_token.locked_amount = new_amount;
        
        let additional_balance = coin::into_balance(additional_coin);
        balance::join(&mut ve_token.locked_coins, additional_balance);
        
        let end_epoch = ve_token.end_epoch;
        update_snapshots(ve_token, new_amount, end_epoch, clock);
        update_manifested_total_supply(
            old_amount,
            end_epoch,
            new_amount,
            end_epoch,
            collection,
            clock
        );
    }

    public fun increase_amount_rebase(
        ve_token: &mut VeSuiDexToken<SUIDEX_TOKEN>,
        rebase_coins: Coin<SUIDEX_TOKEN>,
        collection: &mut VeSuiDexCollection,
        clock: &Clock,
    ) {
        let rebase_amount = coin::value(&rebase_coins);
        assert!(rebase_amount > 0, E_ZERO_AMOUNT);

        let old_amount = ve_token.locked_amount;
        let new_amount = old_amount + rebase_amount;
        ve_token.locked_amount = new_amount;

        let rebase_balance = coin::into_balance(rebase_coins);
        balance::join(&mut ve_token.locked_coins, rebase_balance);

        let end_epoch = ve_token.end_epoch;
        update_snapshots(ve_token, new_amount, end_epoch, clock);
        update_manifested_total_supply(
            old_amount,
            end_epoch,
            new_amount,
            end_epoch,
            collection,
            clock
        );
    }

    public fun locked_amount(
        ve_token: &VeSuiDexToken<SUIDEX_TOKEN>
    ): u64 {
        ve_token.locked_amount
    }

    public fun max_lockup_epochs(): u64 {
        104
    }

    public entry fun merge(
        _account: address,
        _ve_token1: &mut VeSuiDexToken<SUIDEX_TOKEN>,
        _ve_token2: &mut VeSuiDexToken<SUIDEX_TOKEN>,
        _ctx: &mut TxContext
    ) {
        abort 0
    }

    public(package) fun merge_ve_nft(
        account: address,
        source_token: VeSuiDexToken<SUIDEX_TOKEN>,
        target_token: &mut VeSuiDexToken<SUIDEX_TOKEN>,
        collection: &mut VeSuiDexCollection,
        clock: &Clock,
        ctx: &TxContext
    ) {
        let source_rebase = claimable_rebase(&source_token, collection, clock);
        let target_rebase = claimable_rebase(target_token, collection, clock);
        assert!(source_rebase == 0 && target_rebase == 0, E_PENDING_REBASE);

        assert!(tx_context::sender(ctx) == account, E_NOT_OWNER);
        assert!(source_token.owner == account, E_NOT_OWNER);
        assert!(target_token.owner == account, E_NOT_OWNER);

        let transfer_amount = balance::value(&source_token.locked_coins);

        let source_end_epoch = source_token.end_epoch;
        let source_snapshots = source_token.snapshots;

        let VeSuiDexToken {
            id,
            owner: _,
            locked_amount: _,
            end_epoch: _,
            snapshots: _,
            next_rebase_epoch: _,
            locked_coins: source_balance
        } = source_token;

        object::delete(id);
        destroy_snapshots(source_snapshots);
        
        balance::join(&mut target_token.locked_coins, source_balance);

        let old_amount = target_token.locked_amount;
        let new_amount = transfer_amount + old_amount;
        target_token.locked_amount = new_amount;

        let target_end_epoch = target_token.end_epoch;

        if (source_end_epoch > target_end_epoch) {
            target_token.end_epoch = source_end_epoch;
            update_snapshots(target_token, new_amount, source_end_epoch, clock);
            update_manifested_total_supply(
                old_amount,
                target_end_epoch,
                old_amount,
                source_end_epoch,
                collection,
                clock
            );
        } else {
            update_snapshots(target_token, new_amount, target_end_epoch, clock);
            if (source_end_epoch != target_end_epoch) {
                update_manifested_total_supply(
                    transfer_amount,
                    source_end_epoch,
                    transfer_amount,
                    target_end_epoch,
                    collection,
                    clock
                );
            };
        };
    }

    public fun remaining_lockup_epochs(
        ve_token: &VeSuiDexToken<SUIDEX_TOKEN>,
        clock: &Clock,
    ): u64 {
        let expiration_epoch = get_lockup_expiration_epoch(ve_token);
        let current_epoch = epoch::now(clock);
        if (expiration_epoch <= current_epoch) {
            0
        } else {
            expiration_epoch - current_epoch
        }
    }

    public fun split(
        _account: address,
        _ve_token: &mut VeSuiDexToken<SUIDEX_TOKEN>,
        _split_amounts: vector<u64>,
        _ctx: &mut TxContext,
    ): vector<VeSuiDexToken<SUIDEX_TOKEN>> {
        abort 0
    }

    public entry fun split_entry(
        _account: address,
        _ve_token: &mut VeSuiDexToken<SUIDEX_TOKEN>,
        _split_amounts: vector<u64>,
        _ctx: &mut TxContext,
    ) {
        abort 0
    }

    public(package) fun split_ve_nft(
        account: address,
        ve_token: VeSuiDexToken<SUIDEX_TOKEN>,
        mut split_amounts: vector<u64>,
        collection: &mut VeSuiDexCollection,
        clock: &Clock,
        ctx: &mut TxContext
    ): vector<VeSuiDexToken<SUIDEX_TOKEN>> {
        assert!(tx_context::sender(ctx) == account, E_NOT_OWNER);
        assert!(ve_token.owner == account, E_NOT_OWNER);
        
        let claimable = claimable_rebase(&ve_token, collection, clock);
        assert!(claimable == 0, E_PENDING_REBASE);

        let mut amounts_copy = vector::empty();
        let mut i = 0;
        while (i < vector::length(&split_amounts)) {
            vector::push_back(&mut amounts_copy, *vector::borrow(&split_amounts, i));
            i = i + 1;
        };

        let mut total_split_amount = 0;
        vector::reverse(&mut split_amounts);
        let mut split_amounts_length = vector::length(&split_amounts);
        while (split_amounts_length > 0) {
            total_split_amount = total_split_amount + vector::pop_back(&mut split_amounts);
            split_amounts_length = split_amounts_length - 1;
        };
        vector::destroy_empty(split_amounts);

        assert!(total_split_amount == balance::value(&ve_token.locked_coins), E_INVALID_SPLIT_AMOUNTS);

        let end_epoch = ve_token.end_epoch;
        let locked_amount = ve_token.locked_amount; 

        let VeSuiDexToken {
            id,
            owner: _,
            locked_amount: _,
            end_epoch: _,
            snapshots,
            next_rebase_epoch: _,
            locked_coins,
        } = ve_token;

        let balance_to_split = locked_coins;
        
        let mut current_epoch = epoch::now(clock);
        while (current_epoch < end_epoch) {
            let manifested_supply = &mut collection.unscaled_total_voting_power_per_epoch;
            assert!(table::contains(manifested_supply, current_epoch), E_TABLE_ENTRY_NOT_FOUND);
            let supply = table::borrow_mut(manifested_supply, current_epoch);
            *supply = *supply - ((locked_amount * (end_epoch - std::u64::min(current_epoch, end_epoch))) as u128);
            current_epoch = current_epoch + 1;
        };

        let remaining_lockup = end_epoch - epoch::now(clock);
        
        let mut new_ve_tokens = vector::empty<VeSuiDexToken<SUIDEX_TOKEN>>();
        
        let mut coins_to_split = coin::from_balance(balance_to_split, ctx);

        vector::reverse(&mut amounts_copy);
        while (!vector::is_empty(&amounts_copy)) {
            let split_amount = vector::pop_back(&mut amounts_copy);
            if (coin::value(&coins_to_split) > split_amount) {
                let split_coin = coin::split(&mut coins_to_split, split_amount, ctx);
                let mut new_ve_token = create_lock_with(
                    split_coin,
                    remaining_lockup,
                    account,
                    collection,
                    clock,
                    ctx
                );
                update_snapshots(&mut new_ve_token, split_amount, end_epoch, clock);
                vector::push_back(&mut new_ve_tokens, new_ve_token);
            };
        };
        vector::destroy_empty(amounts_copy);
        
        let final_ve_token = create_lock_with(
            coins_to_split,
            remaining_lockup,
            account,
            collection,
            clock,
            ctx
        );
        vector::push_back(&mut new_ve_tokens, final_ve_token);
        
        object::delete(id);
        destroy_snapshots(snapshots);
        
        new_ve_tokens
    }

    public fun total_voting_power(
        collection: &VeSuiDexCollection,
        clock: &Clock,
    ): u128 {
        total_voting_power_at(collection, epoch::now(clock))
    }

    public fun set_rebase_at_specified_epoch(
        account: address,
        collection: &mut VeSuiDexCollection,
        epoch_number: u64,
        rebase_amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == account, E_NOT_OWNER);
        assert!(table::contains(&collection.rebases, epoch_number), E_INVALID_EPOCH);
        let rebase = table::borrow_mut(&mut collection.rebases, epoch_number);
        *rebase = rebase_amount;
    }

    public fun total_voting_power_at(
        collection: &VeSuiDexCollection,
        target_epoch: u64,
    ): u128 {
        let voting_power_table = &collection.unscaled_total_voting_power_per_epoch;
        if (!table::contains(voting_power_table, target_epoch)) {
            0
        } else {
            *table::borrow(voting_power_table, target_epoch) / (104 as u128)
        }
    }

    public fun token_owner(        
        ve_token: &VeSuiDexToken<SUIDEX_TOKEN>,
    ): address {
        ve_token.owner
    }

    public fun nft_exists(
        ve_token: &VeSuiDexToken<SUIDEX_TOKEN>,
        addr: address
    ): bool {
        ve_token.owner == addr
    }

    // --- test helpers ---
    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(VOTING_ESCROW {}, ctx)
    }

    #[test_only]
    public(package) fun next_rebase_epoch(ve_token: &VeSuiDexToken<SUIDEX_TOKEN>): u64{
        ve_token.next_rebase_epoch
    }

    #[test_only]
    public(package) fun add_fake_rebase(
        collection: &mut VeSuiDexCollection, 
        epoch_number: u64, 
        rebase_amount: u64,
        clock: &Clock,
    ) {
        add_rebase(collection, rebase_amount, epoch_number, clock)
    }
}