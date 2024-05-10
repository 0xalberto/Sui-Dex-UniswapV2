A simple Sui Move version AMM Dex based on the logic of UniswapV2.

## Introduction
+ This module implements the factory and pool logic of UniswapV2 where anyone can freely create pair of two coin types, add or remove liquidity, and swap.
+ After a `Pool` of two coin types is created, a `PoolItem` will be added to `Factory`'s `table` field, which guarantees there is at most one pool for a pair.
+ The two coin types of a pair are first sorted according to their `type_name`, and then assigned to `PoolItem`'s `a` and `b` fields respectively.
+ Users can add liquidity to the pool according to the current ratio of coin balances. The remaining coin will be returned to the users as well as the LP coin.
+ Each pool are set with a `0.3%` swap fee by default which is actually distributed to all LP holders.
+ Core functions like `create_pool`, `add_liquidity`, `remove_liquidity`, `swap_a_for_b`, `swap_b_for_a` are all provided with three kind of interfaces (call with `Balance`, call with `Coin` and return `Coin`,  call with `Coin` and transfer the output `Coin` to the sender in that entry function) considering both composability and convenience.

## Structs
1. LP witness
+ LP witness `LP<A, B>` is used as unique identifier of `Coin<LP<A, B>>` type.

2. Pool
+ A `Pool<A, B>` is a global shared object that is created by the one who calls the `create_pool` function.
+ It records its `Balance<A>`, `Balance<B>`, `Supply<LP<A, B>>`, and default fee.

3. Factory
+ A `Factory` is a global shared object that is created only once during the package publishment.
+ It has a `table` field recording each `PoolItem`.

4. PoolItem
+ A `PoolItem` is used to record the pool info in the `Factory`.
+ It guarantees each pair is unique and the coin types it records are sorted.

## Core functions
1. create_pool<A, B>
+ Create a new `Pool<A, B>` with initial liquidity.
+ Input with `Factory`, `Balance<A>` and `Balance<B>`, return `Balance<LP<A, B>>`.

2. create_pool_with_coins<A, B>
+ Input with `Factory`, `Coin<A>` and `Coin<B>`, return `Coin<LP<A, B>>`.

3. create_pool_with_coins_and_transfer_lp_to_sender<A, B>
+ Input with `Factory`, `Coin<A>` and `Coin<B>`, and transfer `Coin<LP<A, B>>` to sender in the function.

4. add_liquidity<A, B>
+ Add liquidity to `Pool<A, B>` to get LP coin.
+ Input with `Pool<A, B>`, `Balance<A>`, `Balance<B>` and minimal LP output amount, return remaining `Balance<A>`, `Balance<B>`, and `Balance<LP<A, B>>`.

5. add_liquidity_with_coins<A, B>
+ Input with `Pool<A, B>`, `Coin<A>`, `Coin<B>` and minimal LP output amount, return remaining `Coin<A>`, `Coin<B>`, and `Coin<LP<A, B>>`.

6. add_liquidity_with_coins_and_transfer_to_sender<A, B>
+ Input with `Pool<A, B>`, `Coin<A>`, `Coin<B>` and minimal LP output amount, and transfer remaining `Coin<A>`, `Coin<B>`, and `Coin<LP<A, B>>` to sender in the function.

7. remove_liquidity<A, B>
+ Remove liquidity from `Pool<A, B>` and burn LP coin.
+ Input with `Pool<A, B>`, `Balance<LP<A, B>>` and minimal A output amount, minimal B output amount, return `Balance<A>` and `Balance<B>`.

8. remove_liquidity_with_coins<A, B>
+ Input with `Pool<A, B>`, `Coin<LP<A, B>>` and minimal A output amount, minimal B output amount, return `Coin<A>` and `Coin<B>`.

9. remove_liquidity_with_coins_and_transfer_to_sender<A, B>
+ Input with `Pool<A, B>`, `Coin<LP<A, B>>` and minimal A output amount, minimal B output amount, and transfer `Coin<A>` and `Coin<B>` to sender in the function.

10. swap_a_for_b<A, B>
+ Swap exact `Balance<A>` for `Balance<B>`.
+ Input with `Pool<A, B>`, `Balance<A>` and minimal B output amount, return `Balance<B>`.

11. swap_a_for_b_with_coin<A, B>
+ Input with `Pool<A, B>`, `Coin<A>` and minimal B output amount, return `Coin<B>`.

12. swap_a_for_b_with_coin_and_transfer_to_sender<A, B>
+ Input with `Pool<A, B>`, `Coin<A>` and minimal B output amount, and transfer `Coin<B>` to sender in the function.

13. swap_b_for_a<A, B>
+ Swap exact `Balance<B>` for `Balance<A>`.
+ Input with `Pool<A, B>`, `Balance<B>` and minimal A output amount, return `Balance<A>`.

14. swap_b_for_a_with_coin<A, B>
+ Input with `Pool<A, B>`, `Coin<B>` and minimal A output amount, return `Coin<A>`.

15. swap_b_for_a_with_coin_and_transfer_to_sender<A, B>
+ Input with `Pool<A, B>`, `Coin<B>` and minimal A output amount, and transfer `Coin<A>` to sender in the function.

## Unit test
![](<unit test.png>)