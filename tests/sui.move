module sui_dex::sui {
    use sui::coin::{Self, TreasuryCap};

    public struct SUI has drop {}

    public struct TCap has key, store {
        id: UID,
        cap: TreasuryCap<SUI>,
    }

    fun init_sui(witness: SUI, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency(witness, 6, b"SUI", b"sui", b"", option::none(), ctx);

        let tcap = TCap {
            id: object::new(ctx),
            cap: treasury_cap
        };

        transfer::share_object(tcap);
        transfer::public_freeze_object(metadata);
    }

    #[test_only]
    public fun init_for_testing_sui(ctx: &mut TxContext) {
        init_sui(SUI {}, ctx); 
    }
}
