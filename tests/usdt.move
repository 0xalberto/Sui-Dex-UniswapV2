module sui_dex::usdt {
    use sui::coin::{Self, TreasuryCap};

    public struct USDT has drop {}

    public struct TCap has key, store {
        id: UID,
        cap: TreasuryCap<USDT>,
    }

    fun init_usdt(witness: USDT, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency(witness, 6, b"USDT", b"usdt", b"", option::none(), ctx);

        let tcap = TCap {
            id: object::new(ctx),
            cap: treasury_cap
        };

        transfer::share_object(tcap);
        transfer::public_freeze_object(metadata);
    }

    #[test_only]
    public fun init_for_testing_usdt(ctx: &mut TxContext) {
        init_usdt(USDT {}, ctx); 
    }
}
