module sui_dex::eth {
    use sui::coin::{Self, TreasuryCap};

    public struct ETH has drop {}

    public struct TCap has key, store {
        id: UID,
        cap: TreasuryCap<ETH>,
    }

    fun init_eth(witness: ETH, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency(witness, 6, b"ETH", b"eth", b"", option::none(), ctx);

        let tcap = TCap {
            id: object::new(ctx),
            cap: treasury_cap
        };

        transfer::share_object(tcap);
        transfer::public_freeze_object(metadata);
    }

    #[test_only]
    public fun init_for_testing_eth(ctx: &mut TxContext) {
        init_eth(ETH {}, ctx); 
    }
}
