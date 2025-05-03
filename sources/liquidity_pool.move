module sui_dex::liquidity_pool {
    use std::ascii::String;
    use sui::table::{Self, Table};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin, CoinMetadata};
    use sui::package;
    //use sui::dynamic_field;
    use sui::dynamic_object_field;
    use sui::dynamic_field;
    use sui_dex::coin_wrapper::{Self, WrapperStore};
    use sui::event;

    // --- addresses ---
    const DEFAULT_ADMIN: address = @0x123;

    // --- errors ---
    const E_INSUFFICIENT_BALANCE: u64 = 1;
    const E_MIN_LOCK_TIME: u64 = 2;
    const E_MAX_LOCK_TIME: u64 = 3;
    const E_NOT_OWNER: u64 = 4;
    const E_LOCK_NOT_EXPIRED: u64 = 5;
    const E_INVALID_UPDATE: u64 = 6;
    const E_ZERO_AMOUNT: u64 = 7;
    const E_ZERO_TOTAL_POWER: u64 = 8;
    const E_SAME_TOKEN: u64 = 9;
    const E_NOT_WHITELISTED: u64 = 17;

    // --- structs ---
    // otw
    public struct LIQUIDITY_POOL has drop {}

    public struct FeesAccounting has key {
        id: UID,
        total_fees_base: u128,
        total_fees_quote: u128,
        total_fees_at_last_claim_base: Table<address, u128>,
        total_fees_at_last_claim_quote: Table<address, u128>,
        claimable_base: Table<address, u128>,
        claimable_quote: Table<address, u128>
    }

    public struct LiquidityPool<phantom BaseType, phantom QuoteType> has key, store {
        id: UID,
        base_balance: Balance<BaseType>,
        quote_balance: Balance<QuoteType>,
        base_fees: Balance<BaseType>,
        quote_fees: Balance<QuoteType>,
        swap_fee_bps: u64,
        is_stable: bool
    }

    // Config as a shared object
    public struct LiquidityPoolConfigs has key {
        id: UID,
        all_pools: vector<ID>,
        is_paused: bool,
        fee_manager: address,
        pauser: address,
        pending_fee_manager: address,
        pending_pauser: address,
        stable_fee_bps: u64,
        volatile_fee_bps: u64
    }

    public struct AdminCap has key {
        id: UID
    }

    /// Struct to manage whitelisted LPers
    public struct WhitelistedLPers has key {
        id: UID,
        whitelisted_lpers: Table<address, bool>,
        fee_manager: address
    }

    // --- events ---
    public struct CreatePoolEvent has copy, drop {
        pool: ID,
        token_1: String,
        token_2: String,
        is_stable: bool,
    }
    // init
    fun init(otw: LIQUIDITY_POOL, ctx: &mut TxContext) {
        let configs = LiquidityPoolConfigs {
            id: object::new(ctx),
            all_pools: vector::empty(),
            is_paused: false,
            fee_manager: DEFAULT_ADMIN,
            pauser: DEFAULT_ADMIN,
            pending_fee_manager: @0x0,
            pending_pauser: @0x0,
            stable_fee_bps: 4,
            volatile_fee_bps: 10
        };

        let admin_cap = AdminCap {
            id: object::new(ctx)
        };

        let whitelisted_lpers = WhitelistedLPers {
            id: object::new(ctx),
            whitelisted_lpers: table::new(ctx),
            fee_manager: DEFAULT_ADMIN
        };

        transfer::share_object(configs);
        transfer::transfer(admin_cap, DEFAULT_ADMIN);
        transfer::share_object(whitelisted_lpers);

        let publisher = package::claim(otw, ctx);
        transfer::public_transfer(publisher, tx_context::sender(ctx));
    }

    public fun swap<BaseType, QuoteType>(
        //pool: &mut LiquidityPool<BaseType, QuoteType>,
        configs: &mut LiquidityPoolConfigs,
        fees_accounting: &mut FeesAccounting,
        base_metadata: &CoinMetadata<BaseType>,
        quote_metadata: &CoinMetadata<QuoteType>,
        is_stable: bool,
        mut input_coin: Coin<BaseType>,
        ctx: &mut TxContext
    ): Coin<QuoteType> {
        assert!(!configs.is_paused, E_LOCK_NOT_EXPIRED);
        let pool = liquidity_pool_mut(configs, base_metadata, quote_metadata, is_stable);
        
        let input_amount = coin::value(&input_coin);
        
        let (output_amount, fee_amount) = get_amount_out(
            pool,
            base_metadata,
        quote_metadata,
            input_amount
        );
        
        let fee_coin = coin::split(&mut input_coin, fee_amount, ctx);
        
        let (standardized_reserve_base, standardized_reserve_quote) = if (pool.is_stable) {
            standardize_reserve(
                (balance::value(&pool.base_balance) as u256),
                (balance::value(&pool.quote_balance) as u256),
                coin::get_decimals(base_metadata),
                coin::get_decimals(quote_metadata)
            )
        } else {
            (
                (balance::value(&pool.base_balance) as u256),
                (balance::value(&pool.quote_balance) as u256)
            )
        };

        let base_coin_balance = coin::into_balance(input_coin);
        let base_fee_balance = coin::into_balance(fee_coin);
        
        balance::join(&mut pool.base_balance, base_coin_balance);
        balance::join(&mut pool.base_fees, base_fee_balance);
        
        fees_accounting.total_fees_base = fees_accounting.total_fees_base + (fee_amount as u128);
        
        let out_balance = balance::split(&mut pool.quote_balance, output_amount);
        let output_coin = coin::from_balance(out_balance, ctx);

        let (updated_reserve_base, updated_reserve_quote) = if (pool.is_stable) {
            standardize_reserve(
                (balance::value(&pool.base_balance) as u256),
                (balance::value(&pool.quote_balance) as u256),
                coin::get_decimals(base_metadata),
                coin::get_decimals(quote_metadata)
            )
        } else {
            (
                (balance::value(&pool.base_balance) as u256),
                (balance::value(&pool.quote_balance) as u256)
            )
        };

        assert!(
            calculate_k(standardized_reserve_base, standardized_reserve_quote, pool.is_stable) <= 
            calculate_k(updated_reserve_base, updated_reserve_quote, pool.is_stable),
            E_INVALID_UPDATE
        );

        output_coin
    }

    public fun get_amount_out<BaseType, QuoteType>(
        pool: &LiquidityPool<BaseType, QuoteType>,
        base_metadata: &CoinMetadata<BaseType>,
        quote_metadata: &CoinMetadata<QuoteType>,
        input_amount: u64
    ): (u64, u64) {
        let (base_reserve, quote_reserve, base_decimals, quote_decimals) = (
            balance::value(&pool.base_balance),
            balance::value(&pool.quote_balance),
            coin::get_decimals(base_metadata),
            coin::get_decimals(quote_metadata)
        );

        let constant_factor = 10000;
        assert!(constant_factor != 0, E_ZERO_TOTAL_POWER);

        let adjusted_amount_in = (
            ((input_amount as u128) * ((10000 - pool.swap_fee_bps) as u128) / (constant_factor as u128)) 
            as u64
        );
        let amount_in_u256 = (adjusted_amount_in as u256);

        let output_amount = if (pool.is_stable) {
            let (standard_reserve_base, standard_reserve_quote) = 
                standardize_reserve(
                    (base_reserve as u256), 
                    (quote_reserve as u256), 
                    base_decimals, 
                    quote_decimals
                );

            let pow10_scale_quote = std::u64::pow(10, (quote_decimals));
            assert!(pow10_scale_quote != 0, E_ZERO_TOTAL_POWER);

            let constant_factor_large = (100000000 as u128);
            assert!(constant_factor_large != 0, E_ZERO_TOTAL_POWER);

            let y = get_y(
                (((((amount_in_u256 as u128) as u256) * 
                ((constant_factor_large as u128) as u256) / 
                (pow10_scale_quote as u256)) as u128) as u256) + 
                standard_reserve_base,
                calculate_k(
                    standard_reserve_base, 
                    standard_reserve_quote, 
                    true
                ),
                standard_reserve_quote
            );

            ((((
                (standard_reserve_quote - y) as u128
            ) as u256) * 
            (std::u64::pow(10, (quote_decimals)) as u256) / 
            (constant_factor_large as u256)) as u128) as u256
        } else {
            amount_in_u256 * 
            (quote_reserve as u256) / 
            ((base_reserve as u256) + amount_in_u256)
        };

        ((output_amount as u64), input_amount - adjusted_amount_in)
    }

    public fun calculate_constant_k<BaseType, QuoteType>(
        liquidity_pool: &LiquidityPool<BaseType, QuoteType>
    ): u256 {
        let reserve_amount_1 = (balance::value(&liquidity_pool.base_balance) as u256);
        let reserve_amount_2 = (balance::value(&liquidity_pool.quote_balance) as u256);
        
        if (liquidity_pool.is_stable) {
            reserve_amount_1 * reserve_amount_1 * reserve_amount_1 * reserve_amount_2 + 
            reserve_amount_2 * reserve_amount_2 * reserve_amount_2 * reserve_amount_1
        } else {
            reserve_amount_1 * reserve_amount_2
        }
    }

    fun calculate_k(
        amount_1: u256, 
        amount_2: u256, 
        is_stable: bool
    ): u256 {
        if (is_stable) {
            // stable pools: x³y + y³x
            amount_1 * amount_1 * amount_1 * amount_2 + 
            amount_2 * amount_2 * amount_2 * amount_1
        } else {
            // volatile pools: simple xy (constant product)
            amount_1 * amount_2
        }
    }

    fun standardize_reserve(
        amount_1: u256,
        amount_2: u256,
        decimals_1: u8,
        decimals_2: u8
    ): (u256, u256) {
        // calculate decimal adjustments (10^decimals)
        let factor_1 = std::u64::pow(10, (decimals_1));
        let factor_2 = std::u64::pow(10, (decimals_2));
        
        // check for zero factors
        assert!(factor_1 != 0, E_ZERO_TOTAL_POWER);
        assert!(factor_2 != 0, E_ZERO_TOTAL_POWER);

        let constant_factor = (100000000 as u128); // 10^8
        
        // standardize both amounts:
        // (amount * 10^8) / (10^decimals)
        (
            // standardize amount_1
            (((
                (amount_1 as u128) as u256 * 
                (constant_factor as u256)
            ) / (factor_1 as u256)) as u128) as u256,
            
            // standardize amount_2
            (((
                (amount_2 as u128) as u256 * 
                (constant_factor as u256)
            ) / (factor_2 as u256)) as u128) as u256
        )
    }

    fun get_y(
        target_value: u256,
        multiplier: u256,
        mut current_guess: u256
    ): u256 {
        let mut iteration_count: u64 = 0;
        while (iteration_count < 255) {
            let calculated_output = multiplier * current_guess * current_guess * current_guess 
                + multiplier * multiplier * multiplier * current_guess;
            
            if (calculated_output < target_value) {
                let adjustment = (target_value - calculated_output) / 
                    (3 * multiplier * current_guess * current_guess + multiplier * multiplier * multiplier);
                current_guess = current_guess + adjustment;
            } else {
                let adjustment = (calculated_output - target_value) / 
                    (3 * multiplier * current_guess * current_guess + multiplier * multiplier * multiplier);
                current_guess = current_guess - adjustment;
            };
            
            if (current_guess > current_guess) {
                if (current_guess - current_guess <= 1) {
                    return current_guess
                };
            } else if (current_guess - current_guess <= 1) {
                return current_guess
            };
            
            iteration_count = iteration_count + 1;
        };
        current_guess
    }

    public fun liquidity_pool<BaseType, QuoteType>(
        configs: &LiquidityPoolConfigs,
        base_metadata: &CoinMetadata<BaseType>,
        quote_metadata: &CoinMetadata<QuoteType>,
        is_stable: bool
    ): &LiquidityPool<BaseType, QuoteType> {
        let pool_name = pool_name(base_metadata, quote_metadata, is_stable);
        dynamic_object_field::borrow(&configs.id, pool_name)
    }

    public fun liquidity_pool_mut<BaseType, QuoteType>(
        configs: &mut LiquidityPoolConfigs,
        base_metadata: &CoinMetadata<BaseType>,
        quote_metadata: &CoinMetadata<QuoteType>,
        is_stable: bool
    ): &mut LiquidityPool<BaseType, QuoteType> {
        let pool_name = pool_name(base_metadata, quote_metadata, is_stable);
        dynamic_object_field::borrow_mut(&mut configs.id, pool_name)
    }
    
    public fun liquidity_pool_address<BaseType, QuoteType>(
        base_metadata: &CoinMetadata<BaseType>,
        quote_metadata: &CoinMetadata<QuoteType>,
        is_stable: bool
    ): address {
        if (!is_sorted(base_metadata, quote_metadata)) {
            return liquidity_pool_address(quote_metadata, base_metadata, is_stable)
        };
        
        // Create a deterministic name for the pool
        let pool_name = pool_name(base_metadata, quote_metadata, is_stable);
        
        // Derive the pool's address using object::id_to_address
        let name_bytes = pool_name;
        object::id_to_address(&object::id_from_bytes(name_bytes))
    }

    public fun pool_name<BaseType, QuoteType>(
        base_metadata: &CoinMetadata<BaseType>,
        quote_metadata: &CoinMetadata<QuoteType>, 
        is_stable: bool
    ): vector<u8> {
        if (!is_sorted(base_metadata, quote_metadata)) {
            return pool_name(quote_metadata, base_metadata, is_stable)
        };
        
        let mut name_bytes = vector::empty<u8>();
        
        let base_id = object::id(base_metadata);
        let base_bytes = object::id_to_bytes(&base_id);
        vector::append(&mut name_bytes, base_bytes);
        
        let quote_id = object::id(quote_metadata);
        let quote_bytes = object::id_to_bytes(&quote_id);
        vector::append(&mut name_bytes, quote_bytes);
        
        if (is_stable) {
            vector::push_back(&mut name_bytes, 1)
        } else {
            vector::push_back(&mut name_bytes, 0)
        };
        
        name_bytes
    }
    
    public fun is_sorted<BaseType, QuoteType>(
        base_metadata: &CoinMetadata<BaseType>,
        quote_metadata: &CoinMetadata<QuoteType>
    ): bool {
        assert!(object::id(base_metadata) != object::id(quote_metadata), E_SAME_TOKEN);
        
        let base_id = object::id(base_metadata);
        let quote_id = object::id(quote_metadata);
        let base_bytes = object::id_to_bytes(&base_id);
        let quote_bytes = object::id_to_bytes(&quote_id);
        
        let mut i = 0;
        let len = vector::length(&base_bytes);
        while (i < len) {
            let base_byte = *vector::borrow(&base_bytes, i);
            let quote_byte = *vector::borrow(&quote_bytes, i);
            if (base_byte < quote_byte) return true;
            if (base_byte > quote_byte) return false;
            i = i + 1;
        };
        false
    }

    public entry fun accept_fee_manager(
        configs: &mut LiquidityPoolConfigs,
        ctx: &mut TxContext
    ) {
        assert!(
            tx_context::sender(ctx) == configs.pending_fee_manager,
            E_NOT_OWNER
        );
        
        configs.fee_manager = configs.pending_fee_manager;
        configs.pending_fee_manager = @0x0;
    }

    public entry fun accept_pauser(
        configs: &mut LiquidityPoolConfigs,
        ctx: &mut TxContext
    ) {
        assert!(
            tx_context::sender(ctx) == configs.pending_pauser,
            E_NOT_OWNER
        );
        
        configs.pauser = configs.pending_pauser;
        configs.pending_pauser = @0x0;
    }

    public fun all_pool_ids(configs: &LiquidityPoolConfigs): vector<ID> {
        configs.all_pools
    }

    public fun burn<BaseType, QuoteType>(
        pool: &mut LiquidityPool<BaseType, QuoteType>,
        lp_amount: u64,
        ctx: &mut TxContext
    ): (Coin<BaseType>, Coin<QuoteType>) {
        let (withdraw_amount_1, withdraw_amount_2) = liquidity_amounts(pool, lp_amount);
        assert!(withdraw_amount_1 > 0 && withdraw_amount_2 > 0, E_MAX_LOCK_TIME);
        
        let withdrawn_asset_1 = coin::take(&mut pool.base_balance, withdraw_amount_1, ctx);
        let withdrawn_asset_2 = coin::take(&mut pool.quote_balance, withdraw_amount_2, ctx);
        
        (withdrawn_asset_1, withdrawn_asset_2)
    }

    public fun liquidity_amounts<BaseType, QuoteType>(
        pool: &LiquidityPool<BaseType, QuoteType>,
        total_liquidity: u64
    ): (u64, u64) {
        // Get current token balances from pool
        let base_reserve = balance::value(&pool.base_balance);
        let quote_reserve = balance::value(&pool.quote_balance);
        
        // Get total supply
        let total_supply = (base_reserve + quote_reserve);
        assert!(total_supply != 0, E_ZERO_TOTAL_POWER);
        
        // Calculate proportional amounts
        let amount_1 = (((total_liquidity as u128) * 
                        (base_reserve as u128)) / 
                        (total_supply as u128));
                        
        let amount_2 = (((total_liquidity as u128) * 
                        (quote_reserve as u128)) / 
                        (total_supply as u128));
        
        // Return amounts cast back to u64
        ((amount_1 as u64), (amount_2 as u64))
    }

    public fun claim_fees<BaseType, QuoteType>(
        pool: &mut LiquidityPool<BaseType, QuoteType>,
        ctx: &mut TxContext
    ): (Coin<BaseType>, Coin<QuoteType>) {
        let (claimable_amount_1, claimable_amount_2) = gauge_claimable_fees(pool);

        let withdrawn_asset_1 = if (claimable_amount_1 > 0) {
            let claim_balance = balance::split(&mut pool.base_fees, claimable_amount_1);
            coin::from_balance(claim_balance, ctx)
        } else {
            coin::zero<BaseType>(ctx)
        };

        let withdrawn_asset_2 = if (claimable_amount_2 > 0) {
            let claim_balance = balance::split(&mut pool.quote_fees, claimable_amount_2);
            coin::from_balance(claim_balance, ctx)
        } else {
            coin::zero<QuoteType>(ctx)
        };

        (withdrawn_asset_1, withdrawn_asset_2)
    }

    public fun gauge_claimable_fees<BaseType, QuoteType>(
        pool: &LiquidityPool<BaseType, QuoteType>
    ): (u64, u64) {
        let base_fees = balance::value(&pool.base_fees);
        let quote_fees = balance::value(&pool.quote_fees);
        (base_fees, quote_fees)
    }

    #[allow(lint(self_transfer))]
    public fun create<BaseType, QuoteType>(
        base_metadata: &CoinMetadata<BaseType>,
        quote_metadata: &CoinMetadata<QuoteType>,
        configs: &mut LiquidityPoolConfigs,
        is_stable: bool,
        ctx: &mut TxContext
    ): ID {
        if (!is_sorted(base_metadata, quote_metadata)) {
            return create(quote_metadata, base_metadata, configs, is_stable, ctx)
        };

        let fee_bps = if (is_stable) {
            configs.stable_fee_bps
        } else {
            configs.volatile_fee_bps
        };

        // Create the pool
        let liquidity_pool = LiquidityPool<BaseType, QuoteType> {
            id: object::new(ctx),
            base_balance: balance::zero<BaseType>(),
            quote_balance: balance::zero<QuoteType>(),
            base_fees: balance::zero<BaseType>(),
            quote_fees: balance::zero<QuoteType>(),
            swap_fee_bps: fee_bps,
            is_stable,
        };

        // Create fees accounting
        let fees_accounting = FeesAccounting {
            id: object::new(ctx),
            total_fees_base: 0,
            total_fees_quote: 0,
            total_fees_at_last_claim_base: table::new<address, u128>(ctx),
            total_fees_at_last_claim_quote: table::new<address, u128>(ctx),
            claimable_base: table::new<address, u128>(ctx),
            claimable_quote: table::new<address, u128>(ctx)
        };

        let liquidity_pool_id = object::id(&liquidity_pool);
        
        // Add pool ID to configs BEFORE sharing
        vector::push_back(&mut configs.all_pools, liquidity_pool_id);

        // Share objects explicitly
        transfer::share_object(fees_accounting);
        let pool_name = pool_name(base_metadata, quote_metadata, is_stable);
        dynamic_object_field::add(&mut configs.id, pool_name, liquidity_pool);

        assert!(verify_pool_exists(configs, base_metadata, quote_metadata, is_stable), 1);

        event::emit(CreatePoolEvent {
            pool: liquidity_pool_id,
            token_1: coin::get_symbol(base_metadata),
            token_2: coin::get_symbol(quote_metadata),
            is_stable
        });

        liquidity_pool_id
    }

    public fun get_trade_diff<BaseType, QuoteType>(
        pool: &LiquidityPool<BaseType, QuoteType>,
        base_metadata: &CoinMetadata<BaseType>,
        quote_metadata: &CoinMetadata<QuoteType>,
        input_metadata: &CoinMetadata<BaseType>,
        amount_in: u64
    ): (u64, u64) {
        let (base_reserve, quote_reserve, base_decimals, quote_decimals) = (
            balance::value(&pool.base_balance),
            balance::value(&pool.quote_balance),
            coin::get_decimals(base_metadata),
            coin::get_decimals(quote_metadata)
        );

        let selected_scale = if (input_metadata == base_metadata) {
            base_decimals 
        } else {
            quote_decimals
        };

        let calculated_amount_out = if (input_metadata == base_metadata) {
            assert!(quote_reserve != 0, E_ZERO_TOTAL_POWER);
            (((base_reserve as u128) * 
            (std::u64::pow(10, quote_decimals) as u128) / 
            (quote_reserve as u128)) as u64)
        } else {
            assert!(base_reserve != 0, E_ZERO_TOTAL_POWER);
            (((quote_reserve as u128) * 
            (std::u64::pow(10, base_decimals) as u128) / 
            (base_reserve as u128)) as u64)
        };

        let (amount_out_for_calculated, _fee) = get_amount_out(
            pool,
            base_metadata,
            quote_metadata,
            calculated_amount_out
        );
        assert!(calculated_amount_out != 0, E_ZERO_TOTAL_POWER);

        let (amount_out_for_input, _fee) = get_amount_out(
            pool,
            base_metadata,
            quote_metadata,
            amount_in
        );
        assert!(amount_in != 0, E_ZERO_TOTAL_POWER);

        (
            (((amount_out_for_calculated as u128) * 
            (std::u64::pow(10, selected_scale) as u128) / 
            (calculated_amount_out as u128)) as u64),
            (((amount_out_for_input as u128) * 
            (std::u64::pow(10, selected_scale) as u128) / 
            (amount_in as u128)) as u64)
        )
    }

    public fun is_stable<BaseType, QuoteType>(pool: &LiquidityPool<BaseType, QuoteType>): bool {
        pool.is_stable
    }

    public fun liquidity_out<BaseType, QuoteType>(
        pool: &LiquidityPool<BaseType, QuoteType>,
        base_metadata: &CoinMetadata<BaseType>,
        quote_metadata: &CoinMetadata<QuoteType>,
        amount_base: u64,
        amount_quote: u64,
        is_stable: bool,
    ): u64 {
        if (!is_sorted(base_metadata, quote_metadata)) {
            return liquidity_out(
                pool,
                base_metadata,
                quote_metadata,
                amount_quote,
                amount_base,
                is_stable
            )
        };

        let base_reserve = balance::value(&pool.base_balance);
        let quote_reserve = balance::value(&pool.quote_balance);
        let total_supply = base_reserve + quote_reserve;

        if (total_supply == 0) {
            ((std::u64::sqrt((amount_base) * (amount_quote)) as u64)) - 1000
        } else {
            assert!(base_reserve != 0, E_ZERO_TOTAL_POWER);
            assert!(quote_reserve != 0, E_ZERO_TOTAL_POWER);

            std::u64::min(
                ((amount_base as u128) * (total_supply as u128) / (base_reserve as u128)) as u64,
                ((amount_quote as u128) * (total_supply as u128) / (quote_reserve as u128)) as u64
            )
        }
    }

    public fun total_supply<BaseType, QuoteType>(
        pool: &LiquidityPool<BaseType, QuoteType>
    ): u128 {
        let base_reserve = (balance::value(&pool.base_balance) as u128);
        let quote_reserve = (balance::value(&pool.quote_balance) as u128);
        base_reserve + quote_reserve
    }

    public fun min_liquidity(): u64 {
        1000
    }

    public fun mint_lp<BaseType, QuoteType>(
        pool: &mut LiquidityPool<BaseType, QuoteType>,
        fees_accounting: &mut FeesAccounting,
        whitelist: &WhitelistedLPers,
        base_metadata: &CoinMetadata<BaseType>,
        quote_metadata: &CoinMetadata<QuoteType>,
        input_base_coin: Coin<BaseType>,
        input_quote_coin: Coin<QuoteType>,
        is_stable: bool,
        ctx: &mut TxContext
    ): u64 {
        if (!is_sorted(base_metadata, quote_metadata)) {
            return mint_lp(
                pool,
                fees_accounting,
                whitelist,
                base_metadata,
                quote_metadata,
                input_base_coin,
                input_quote_coin,
                is_stable,
                ctx
            )
        };

        let amount_base = coin::value(&input_base_coin);
        let amount_quote = coin::value(&input_quote_coin);
        assert!(amount_base > 0 && amount_quote > 0, E_INSUFFICIENT_BALANCE);

        let base_reserve = balance::value(&pool.base_balance);
        let quote_reserve = balance::value(&pool.quote_balance);
        let total_supply = base_reserve + quote_reserve;

        let liquidity_out = if (total_supply == 0) {
            ((std::u64::sqrt((amount_base) * (amount_quote)) as u64)) - 1000
        } else {
            assert!(base_reserve != 0, E_ZERO_TOTAL_POWER);
            assert!(quote_reserve != 0, E_ZERO_TOTAL_POWER);
            std::u64::min(
                ((amount_base as u128) * (total_supply as u128) / (base_reserve as u128)) as u64,
                ((amount_quote as u128) * (total_supply as u128) / (quote_reserve as u128)) as u64
            )
        };

        assert!(liquidity_out > 0, E_MIN_LOCK_TIME);

        // Add tokens to pool
        let base_balance = coin::into_balance(input_base_coin);
        let quote_balance = coin::into_balance(input_quote_coin);
        balance::join(&mut pool.base_balance, base_balance);
        balance::join(&mut pool.quote_balance, quote_balance);

        // Update fees accounting
        fees_accounting.total_fees_base = fees_accounting.total_fees_base;
        fees_accounting.total_fees_quote = fees_accounting.total_fees_quote;

        let lper = tx_context::sender(ctx);
        let is_whitelisted = is_whitelisted_lper(whitelist, lper);

        // If whitelisted, store their contribution percentage for fee distribution
        if (is_whitelisted) {
            let total_supply = base_reserve + quote_reserve;
            let contribution_percentage = ((liquidity_out as u128) * 10000) / (total_supply as u128);
            dynamic_field::add(&mut pool.id, lper, contribution_percentage);
        };


        liquidity_out
    }

    public fun pool_reserve<BaseType, QuoteType>(
        pool: &LiquidityPool<BaseType, QuoteType>,
        base_metadata: &CoinMetadata<BaseType>,
        quote_metadata: &CoinMetadata<QuoteType>
    ): (u64, u64, u8, u8) {
        (
            balance::value(&pool.base_balance),
            balance::value(&pool.quote_balance),
            coin::get_decimals(base_metadata),
            coin::get_decimals(quote_metadata)
        )
    }

    public fun pool_reserves<BaseType, QuoteType>(
        pool: &LiquidityPool<BaseType, QuoteType>
    ): (u64, u64) {
        (
            balance::value(&pool.base_balance),
            balance::value(&pool.quote_balance)
        )
    }

    public entry fun set_fee_manager(
        configs: &mut LiquidityPoolConfigs,
        new_fee_manager: address,
        ctx: &mut TxContext
    ) {
        assert!(
            tx_context::sender(ctx) == configs.fee_manager,
            E_NOT_OWNER
        );
        configs.pending_fee_manager = new_fee_manager;
    }

    public entry fun set_pause(
        configs: &mut LiquidityPoolConfigs,
        pause_status: bool,
        ctx: &mut TxContext
    ) {
        assert!(
            tx_context::sender(ctx) == configs.pauser,
            E_NOT_OWNER
        );
        configs.is_paused = pause_status;
    }

    public entry fun set_pauser(
        configs: &mut LiquidityPoolConfigs,
        new_pauser: address,
        ctx: &mut TxContext
    ) {
        assert!(
            tx_context::sender(ctx) == configs.pauser,
            E_NOT_OWNER
        );
        configs.pending_pauser = new_pauser;
    }

    public entry fun set_pool_swap_fee<BaseType, QuoteType>(
        pool: &mut LiquidityPool<BaseType, QuoteType>,
        configs: &LiquidityPoolConfigs,
        new_swap_fee: u64,
        ctx: &mut TxContext
    ) {
        assert!(new_swap_fee <= 30, E_ZERO_AMOUNT);
        
        assert!(tx_context::sender(ctx) == configs.fee_manager, E_NOT_OWNER);
        
        pool.swap_fee_bps = new_swap_fee;
    }

    public entry fun set_stable_fee(
        configs: &mut LiquidityPoolConfigs,
        new_stable_fee: u64,
        ctx: &mut TxContext
    ) {
        assert!(new_stable_fee <= 30, E_ZERO_AMOUNT);
        
        assert!(tx_context::sender(ctx) == configs.fee_manager, E_NOT_OWNER);
        
        configs.stable_fee_bps = new_stable_fee;
    }

    public entry fun set_volatile_fee(
        configs: &mut LiquidityPoolConfigs,
        new_volatile_fee: u64,
        ctx: &mut TxContext
    ) {
        assert!(new_volatile_fee <= 30, E_ZERO_AMOUNT);
        
        assert!(tx_context::sender(ctx) == configs.fee_manager, E_NOT_OWNER);
        
        configs.volatile_fee_bps = new_volatile_fee;
    }

    public fun supported_inner_assets<BaseType, QuoteType>(
        base_metadata: &CoinMetadata<BaseType>,
        quote_metadata: &CoinMetadata<QuoteType>
    ): vector<ID> {
        let mut inner_assets = vector::empty<ID>();
        
        vector::push_back(&mut inner_assets, object::id(base_metadata));
        vector::push_back(&mut inner_assets, object::id(quote_metadata));
        
        inner_assets
    }

    public fun supported_native_fungible_assets<BaseType, QuoteType>(
        base_metadata: &CoinMetadata<BaseType>,
        quote_metadata: &CoinMetadata<QuoteType>,
        wrapper_store: &WrapperStore,
    ): vector<ID> {
        let mut inner_assets = supported_inner_assets(base_metadata, quote_metadata);
        let mut native_assets = vector::empty<ID>();
        
        vector::reverse(&mut inner_assets);
        let mut inner_assets_length = vector::length(&inner_assets);
        
        while (inner_assets_length > 0) {
            let asset_id = vector::pop_back(&mut inner_assets);
            if (!coin_wrapper::is_wrapper(wrapper_store, asset_id)) {
                vector::push_back(&mut native_assets, asset_id);
            };
            inner_assets_length = inner_assets_length - 1;
        };
        
        vector::destroy_empty(inner_assets);
        native_assets
    }

    public fun supported_token_strings<BaseType, QuoteType>(
        base_metadata: &CoinMetadata<BaseType>,
        quote_metadata: &CoinMetadata<QuoteType>,
        wrapper_store: &WrapperStore,
    ): vector<String> {
        let mut inner_assets = supported_inner_assets(base_metadata, quote_metadata);
        let mut token_strings = vector::empty<String>();
        
        vector::reverse(&mut inner_assets);
        let mut inner_assets_length = vector::length(&inner_assets);
        
        while (inner_assets_length > 0) {
            let asset_id = vector::pop_back(&mut inner_assets);
            vector::push_back(
                &mut token_strings, 
                coin_wrapper::get_original<BaseType>(wrapper_store, asset_id)
            );
            inner_assets_length = inner_assets_length - 1;
        };
        
        vector::destroy_empty(inner_assets);
        token_strings
    }

    public fun swap_fee_bps<BaseType, QuoteType>(
        pool: &LiquidityPool<BaseType, QuoteType>
    ): u64 {
        pool.swap_fee_bps
    }

    public entry fun update_claimable_fees<BaseType, QuoteType>(
        _account: address,
        _pool: &mut LiquidityPool<BaseType, QuoteType>,
        _ctx: &mut TxContext
    ) {
        abort 0
    }

    // --- test helpers ---
    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(LIQUIDITY_POOL {}, ctx)
    } 

    #[test_only]
    public(package) fun configs_id(configs: &LiquidityPoolConfigs): &UID {
        &configs.id
    }

    #[test_only]
    public fun create_liquidity_pool_test<BaseType, QuoteType>(
        base_metadata: &CoinMetadata<BaseType>,
        quote_metadata: &CoinMetadata<QuoteType>,
        configs: &mut LiquidityPoolConfigs,
        is_stable: bool,
        ctx: &mut TxContext
    ): (LiquidityPool<BaseType, QuoteType>, ID) {
        let fee_bps = if (is_stable) {
            configs.stable_fee_bps
        } else {
            configs.volatile_fee_bps
        };

        // Create the pool
        let liquidity_pool = LiquidityPool<BaseType, QuoteType> {
            id: object::new(ctx),
            base_balance: balance::zero<BaseType>(),
            quote_balance: balance::zero<QuoteType>(),
            base_fees: balance::zero<BaseType>(),
            quote_fees: balance::zero<QuoteType>(),
            swap_fee_bps: fee_bps,
            is_stable,
        };

        // Create fees accounting
        let fees_accounting = FeesAccounting {
            id: object::new(ctx),
            total_fees_base: 0,
            total_fees_quote: 0,
            total_fees_at_last_claim_base: table::new<address, u128>(ctx),
            total_fees_at_last_claim_quote: table::new<address, u128>(ctx),
            claimable_base: table::new<address, u128>(ctx),
            claimable_quote: table::new<address, u128>(ctx)
        };

        let liquidity_pool_id = object::id(&liquidity_pool);
        
        // Add pool ID to configs BEFORE sharing
        vector::push_back(&mut configs.all_pools, liquidity_pool_id);

        // Share objects explicitly
        transfer::share_object(fees_accounting);

        (liquidity_pool, liquidity_pool_id)
    }

    public fun extract_pool<BaseType, QuoteType>(
        configs: &mut LiquidityPoolConfigs,
        base_metadata: &CoinMetadata<BaseType>,
        quote_metadata: &CoinMetadata<QuoteType>,
        is_stable: bool
    ): LiquidityPool<BaseType, QuoteType> {
        let pool_name = pool_name(base_metadata, quote_metadata, is_stable);
        dynamic_object_field::remove(&mut configs.id, pool_name)
    }

    public fun verify_pool_exists<BaseType, QuoteType>(
        configs: &LiquidityPoolConfigs,
        base_metadata: &CoinMetadata<BaseType>,
        quote_metadata: &CoinMetadata<QuoteType>,
        is_stable: bool
    ): bool {
        let pool_name = pool_name(base_metadata, quote_metadata, is_stable); 
        dynamic_object_field::exists_(&configs.id, pool_name)
    }

    public entry fun add_whitelisted_lper(
        whitelist: &mut WhitelistedLPers,
        lper: address,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == whitelist.fee_manager, E_NOT_OWNER);
        if (!table::contains(&whitelist.whitelisted_lpers, lper)) {
            table::add(&mut whitelist.whitelisted_lpers, lper, true);
        };
    }

    public entry fun remove_whitelisted_lper(
        whitelist: &mut WhitelistedLPers,
        lper: address,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == whitelist.fee_manager, E_NOT_OWNER);
        if (table::contains(&whitelist.whitelisted_lpers, lper)) {
            table::remove(&mut whitelist.whitelisted_lpers, lper);
        };
    }

    public fun is_whitelisted_lper(
        whitelist: &WhitelistedLPers,
        lper: address
    ): bool {
        table::contains(&whitelist.whitelisted_lpers, lper)
    }

    public fun claim_whitelisted_fees<BaseType, QuoteType>(
        pool: &mut LiquidityPool<BaseType, QuoteType>,
        whitelist: &WhitelistedLPers,
        ctx: &mut TxContext
    ): (Coin<BaseType>, Coin<QuoteType>) {
        let lper = tx_context::sender(ctx);
        assert!(is_whitelisted_lper(whitelist, lper), E_NOT_WHITELISTED);
        
        let contribution_percentage = *dynamic_field::borrow<address, u128>(&pool.id, lper);
        
        let base_fees = (balance::value(&pool.base_fees) as u128);
        let quote_fees = (balance::value(&pool.quote_fees) as u128);
        
        let claimable_base = ((base_fees * contribution_percentage) / 10000 as u64);
        let claimable_quote = ((quote_fees * contribution_percentage) / 10000 as u64);
        
        let base_coin = if (claimable_base > 0) {
            coin::from_balance(balance::split(&mut pool.base_fees, claimable_base), ctx)
        } else {
            coin::zero<BaseType>(ctx)
        };
        
        let quote_coin = if (claimable_quote > 0) {
            coin::from_balance(balance::split(&mut pool.quote_fees, claimable_quote), ctx)
        } else {
            coin::zero<QuoteType>(ctx)
        };
        
        (base_coin, quote_coin)
    }
}