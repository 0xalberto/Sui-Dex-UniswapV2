module sui_dex::coin_wrapper {
    use sui::table::{Self, Table};
    use sui::coin::{Self, Coin, TreasuryCap, CoinMetadata};
    use sui::dynamic_object_field;
    use std::string;
    use std::ascii::String;
    use std::type_name;

    // --- errors ---
    const E_ALREADY_INITIALIZED: u64 = 1;
    const E_NOT_INITIALIZED: u64 = 2;

    // --- structs ---
    public struct COIN_WRAPPER has drop {}

    public struct WrappedAssetData has store {
        metadata: CoinMetadata<COIN_WRAPPER>,
        treasury_cap: TreasuryCap<COIN_WRAPPER>,
        original_coin_type: String,
    }

    public struct WrapperStore has key {
        id: UID,
        coin_to_wrapper: Table<String, WrappedAssetData>,
        wrapper_to_coin: Table<ID, String>,
    }

    public struct WrapperStoreCap has key {
        id: UID
    }

    // init
    public(package) fun initialize(_otw: COIN_WRAPPER, ctx: &mut TxContext) {
        let admin_cap = WrapperStoreCap {
            id: object::new(ctx)
        };

        let registry = WrapperStore {
            id: object::new(ctx),
            coin_to_wrapper: table::new(ctx),
            wrapper_to_coin: table::new(ctx)
        };

        transfer::transfer(admin_cap, tx_context::sender(ctx));
        transfer::share_object(registry);
    }

    public fun register_coin<CoinType>(
        _cap: &WrapperStoreCap,
        otw: COIN_WRAPPER,
        store: &mut WrapperStore,
        ctx: &mut TxContext
    ) {
        // check if the coin is already registered
        let coin_type = type_name::get<CoinType>();
        let coin_type_name = coin_type.into_string();
        assert!(!table::contains(&store.coin_to_wrapper, coin_type_name), E_ALREADY_INITIALIZED);

        // create the new wrapped coin
        //let witness = get_witness();
        let (treasury_cap, metadata) = coin::create_currency<COIN_WRAPPER>(
            otw, 
            9, // decimals
            b"WRAPPED", // symbol
            b"Wrapped Coin", // name
            b"A wrapped version of the original coin", // description
            option::none(), // icon_url
            ctx
        );

        let metadata_id = object::id(&metadata);

        // create WrappedAssetData
        let wrapped_data = WrappedAssetData {
            metadata,
            treasury_cap,
            original_coin_type: coin_type_name
        };
        
        table::add(&mut store.coin_to_wrapper, coin_type_name, wrapped_data);
        table::add(&mut store.wrapper_to_coin, metadata_id, coin_type_name);
    }

    // wrap
    public fun wrap<CoinType>(
        store: &mut WrapperStore,
        coin_in: Coin<CoinType>,
        ctx: &mut TxContext
    ): Coin<COIN_WRAPPER> {
        let coin_type = type_name::get<CoinType>();
        let coin_type_name = coin_type.into_string();
        assert!(is_supported(store, &coin_type_name), E_NOT_INITIALIZED);

        let amount = coin::value(&coin_in);
        let wrapped_data = table::borrow_mut(&mut store.coin_to_wrapper, coin_type_name);

        // store original coin
        dynamic_object_field::add(&mut store.id, coin_type_name, coin_in);

        // mint wrapped coin
        let wrapped_coin = coin::mint(&mut wrapped_data.treasury_cap, amount, ctx);

        wrapped_coin
    }

    // unwrap
    public fun unwrap<CoinType>(
        store: &mut WrapperStore,
        wrapped_coin: Coin<COIN_WRAPPER>,
    ): Coin<CoinType> {
        let coin_type = type_name::get<CoinType>();
        let coin_type_name = coin_type.into_string();
        assert!(is_supported(store, &coin_type_name), E_NOT_INITIALIZED);

        let wrapped_data = table::borrow_mut(&mut store.coin_to_wrapper, coin_type_name);

        // burn wrapped coin
        coin::burn(&mut wrapped_data.treasury_cap, wrapped_coin);

        let exists = sui::dynamic_object_field::exists_<String>(&store.id, coin_type_name);
        assert!(exists, 1);

        let stored_coin = dynamic_object_field::remove<String, Coin<CoinType>>(&mut store.id, coin_type_name);

        stored_coin
    }

    public fun format_coin<T>(): String {
        type_name::get<T>().into_string()
    }

    // --- public view functions ---
    public fun is_supported(store: &mut WrapperStore, coin_type: &String): bool {
        table::contains(&store.coin_to_wrapper, *coin_type)
    }

    public fun is_wrapper(store: &WrapperStore, metadata_id: ID): bool {
        table::contains(&store.wrapper_to_coin, metadata_id)
    }

    public fun get_coin_type(store: &WrapperStore, metadata_id: ID): String {
        *table::borrow(&store.wrapper_to_coin, metadata_id)
    }

    public fun get_wrapper<CoinType>(store: &WrapperStore): &CoinMetadata<COIN_WRAPPER> {
        let coin_type_name = type_name::get<CoinType>().into_string();
        &table::borrow(&store.coin_to_wrapper, coin_type_name).metadata
    }

    public fun format_fungible_asset(id: ID): String {
        let bytes = object::id_to_bytes(&id);

        string::to_ascii(string::utf8(bytes))
    }

    public fun get_original<BaseType>(store: &WrapperStore, metadata_id: ID) : String {
        if (is_wrapper(store, metadata_id)) {
            get_coin_type(store, metadata_id)
        } else {
            type_name::get<BaseType>().into_string()
        }
    }

    public fun borrow_original_coin<CoinType>(store: &mut WrapperStore): &mut Coin<CoinType> {
        let coin_type = type_name::get<CoinType>();
        let coin_type_name = coin_type.into_string();
        let coin = dynamic_object_field::borrow_mut<String, Coin<CoinType>>(&mut store.id, coin_type_name);
        coin
    }

    // --- tests funcs ---
    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        initialize(COIN_WRAPPER {}, ctx);
    }

    #[test_only]
    public fun register_coin_for_testing<COIN_WRAPPER>(        
        cap: &WrapperStoreCap,
        store: &mut WrapperStore,
        ctx: &mut TxContext
    ) {
        let otw = create_witness();
        register_coin<COIN_WRAPPER>(cap, otw,  store, ctx);
    }

    #[test_only]
    public(package) fun get_original_coin_type(wcoin_type: &WrappedAssetData): String {
        wcoin_type.original_coin_type
    }

    #[test_only]
    public fun get_wrapped_data<CoinType>(store: &WrapperStore): &WrappedAssetData {
        let coin_type_name = type_name::get<CoinType>().into_string();
        table::borrow(&store.coin_to_wrapper, coin_type_name)
    }

    #[test_only]
    public fun create_witness(): COIN_WRAPPER {
        COIN_WRAPPER {}
    }

    #[test_only]
    public fun unwrap_for_testing<CoinType>(
        store: &mut WrapperStore,
    ): Coin<CoinType> {
        let coin_type = type_name::get<CoinType>();
        let coin_type_name = coin_type.into_string();
        assert!(is_supported(store, &coin_type_name), E_NOT_INITIALIZED);

        let exists = sui::dynamic_object_field::exists_<String>(&store.id, coin_type_name);
        assert!(exists, 1);

        let stored_coin = dynamic_object_field::remove<String, Coin<CoinType>>(&mut store.id, coin_type_name);

        stored_coin
    }
}