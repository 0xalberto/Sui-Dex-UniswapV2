module sui_dex::suidex_token {
    use sui::coin::{Self, Coin, TreasuryCap};

    // --- structs ---
    // OTW
    public struct SUIDEX_TOKEN has drop {}
    
    // token manager
    public struct SuiDexManager has key {
        id: UID,
        cap: TreasuryCap<SUIDEX_TOKEN>,
        minter: address
    }

    // init
    fun init(
        otw: SUIDEX_TOKEN, 
        ctx: &mut TxContext
    ) {
        let (treasury_cap, metadata) = coin::create_currency(
            otw,
            18, // decimals
            b"SDEX", // symbol
            b"SuiDex", // name
            b"Coin of SuiDex Dex", // description
            option::none(), // icon url
            ctx
        );

        let manager = SuiDexManager {
            id: object::new(ctx),
            cap: treasury_cap,
            minter: tx_context::sender(ctx)
        };

        transfer::share_object(manager);
        transfer::public_freeze_object(metadata);
    }

    // mint
    public(package) fun mint(
        authority: &mut TreasuryCap<SUIDEX_TOKEN>, 
        amount: u64, 
        ctx: &mut TxContext
    ): Coin<SUIDEX_TOKEN> {
        coin::mint(authority, amount, ctx)
    }

    // burn
    public(package) fun burn(
        authority: &mut TreasuryCap<SUIDEX_TOKEN>, 
        coin: Coin<SUIDEX_TOKEN>
    ): u64 {
        coin::burn(authority, coin)
    }

    // transfer
    public(package) fun transfer(
        coin: &mut Coin<SUIDEX_TOKEN>, 
        amount: u64,
        recipient: address,
        ctx: &mut TxContext
    ) {
        let coin_to_send = coin::split(coin, amount, ctx);
        transfer::public_transfer(coin_to_send, recipient);
    }

    // freeze transfer
    public(package) fun freeze_transfers(coin: Coin<SUIDEX_TOKEN>) {
        transfer::public_freeze_object(coin);
    }

    public fun withdraw(
        manager: &mut SuiDexManager, 
        amount: u64, 
        ctx: &mut TxContext
    ): Coin<SUIDEX_TOKEN> {
        let coin = mint(&mut manager.cap, amount, ctx);
        coin
    }

    // --- public view functions ---
    // balance
    public fun balance(coin: &Coin<SUIDEX_TOKEN>): u64 {
        coin::value(coin)
    }

    // total supply
    public fun total_supply(manager: &SuiDexManager): u64 {
        coin::total_supply(&manager.cap)
    }

    // cap
    public fun get_treasury_cap(manager: &mut SuiDexManager): &mut TreasuryCap<SUIDEX_TOKEN> {
        &mut manager.cap
    }

    // --- tests funcs ---
    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init( SUIDEX_TOKEN{}, ctx);
    }

    #[test_only]
    public(package) fun cap(manager: &mut SuiDexManager): &mut TreasuryCap<SUIDEX_TOKEN> {
        &mut manager.cap
    }
}