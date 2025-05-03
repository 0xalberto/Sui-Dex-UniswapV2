module sui_dex::epoch {
    use sui::clock::{Self, Clock};

    public fun now(clock: &Clock): u64 {
        clock::timestamp_ms(clock) / (604800 * 1000)
    }
}