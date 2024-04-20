
/// Module: bonding_curve
module bonding_curve::bonding_curve {
    use sui::object::{Self, UID};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Supply, Balance};
    use sui::sui::SUI;
    use sui::transfer;
    use sui::math;
    use sui::tx_context::{Self, TxContext};

    /// For when supplied Coin is zero.
    const EZeroAmount: u64 = 0;

    /// For when someone tries to swap in an empty pool.
    const EReservesEmpty: u64 = 1;

    /// For when someone attempts to add more liquidity than u128 Math allows.
    const EPoolFull: u64 = 2;

    /// Trading disabled
    const ETradingDisabled: u64 = 3;

    /// The max value that can be held in one of the Balances of
    /// a Pool. U64 MAX
    const MAX_POOL_VALUE: u64 = {
        18446744073709551615
    };

    const BASE_SUI_AMOUNT: u64 = 4200 * 1_000_000_000;

    /// The pool with exchange.
    public struct Pool<phantom T> has key {
        id: UID,
        sui: Balance<SUI>,
        token: Balance<T>,
        trading_enabled: bool
    }

    public struct AdminCap has key, store {
        id: UID,
    }

    #[allow(unused_function)]
    /// Mark the creator of this as an admin
    fun init(ctx: &mut TxContext) {
        let admin = tx_context::sender(ctx);
        let admin_cap = AdminCap { id: object::new(ctx) };
        transfer::transfer(admin_cap, admin);
    }

    public fun set_trading_enabled<T>(
        _: &AdminCap,
        pool: &mut Pool<T>,
        trading_enabled: bool
    ) {
        pool.trading_enabled = trading_enabled
    }

    /// Create new `Pool` for token `T`. Each Pool holds a `Coin<T>`
    /// and a `Coin<SUI>`. Swaps are available in both directions.
    ///
    /// Share is calculated based on Uniswap's constant product formula:
    ///  liquidity = sqrt( X * Y )
    public fun create_pool<T>(
        token: Coin<T>,
        sui: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        let sui_amt = coin::value(&sui);
        let tok_amt = coin::value(&token);

        assert!(sui_amt > 0 && tok_amt > 0, EZeroAmount);
        assert!(sui_amt < MAX_POOL_VALUE && tok_amt < MAX_POOL_VALUE, EPoolFull);

        transfer::share_object(Pool<T> {
            id: object::new(ctx),
            token: coin::into_balance(token),
            sui: coin::into_balance(sui),
            trading_enabled: true
        });
    }

    public fun swap_token<T>(
        pool: &mut Pool<T>, token: Coin<T>, ctx: &mut TxContext
    ): Coin<SUI> {
        assert!(coin::value(&token) > 0, EZeroAmount);
        assert!(pool.trading_enabled, ETradingDisabled);

        let tok_balance = coin::into_balance(token);
        let (sui_reserve, token_reserve) = get_amounts(pool);

        assert!(sui_reserve > 0 && token_reserve > 0, EReservesEmpty);

        let output_amount = get_input_price(
            balance::value(&tok_balance),
            token_reserve,
            sui_reserve + BASE_SUI_AMOUNT,
        );

        balance::join(&mut pool.token, tok_balance);
        coin::take(&mut pool.sui, output_amount, ctx)
    }

    /// Swap `Coin<SUI>` for the `Coin<T>`.
    /// Returns Coin<T>.
    public fun swap_sui<T>(
        pool: &mut Pool<T>, sui: Coin<SUI>, ctx: &mut TxContext
    ): Coin<T> {
        assert!(coin::value(&sui) > 0, EZeroAmount);
        assert!(pool.trading_enabled, ETradingDisabled);

        let sui_balance = coin::into_balance(sui);

        // Calculate the output amount
        let (sui_reserve, token_reserve) = get_amounts(pool);

        assert!(sui_reserve > 0 && token_reserve > 0, EReservesEmpty);

        let output_amount = get_input_price(
            balance::value(&sui_balance),
            sui_reserve + BASE_SUI_AMOUNT,
            token_reserve
        );

        balance::join(&mut pool.sui, sui_balance);
        coin::take(&mut pool.token, output_amount, ctx)
    }

    /// Get most used values in a handy way:
    /// - amount of SUI
    /// - amount of token
    public fun get_amounts<T>(pool: &Pool<T>): (u64, u64) {
        (
            balance::value(&pool.sui),
            balance::value(&pool.token),
        )
    }

    /// Calculate the output amount
    public fun get_input_price(
        input_amount: u64, input_reserve: u64, output_reserve: u64
    ): u64 {
        // up casts
        let (
            input_amount,
            input_reserve,
            output_reserve,
        ) = (
            (input_amount as u128),
            (input_reserve as u128),
            (output_reserve as u128),
        );

        let numerator = input_amount * output_reserve;
        let denominator = (input_reserve) + input_amount;

        (numerator / denominator as u64)
    }

    /// Public getter for the price of SUI in token T.
    /// - How much SUI one will get if they send `to_sell` amount of T;
    public fun sui_price<P, T>(pool: &Pool<T>, to_sell: u64): u64 {
        let (sui_amt, tok_amt) = get_amounts(pool);
        get_input_price(to_sell, tok_amt, sui_amt + BASE_SUI_AMOUNT)
    }

    /// Public getter for the price of token T in SUI.
    /// - How much T one will get if they send `to_sell` amount of SUI;
    public fun token_price<T>(pool: &Pool<T>, to_sell: u64): u64 {
        let (sui_amt, tok_amt) = get_amounts(pool);
        get_input_price(to_sell, sui_amt + BASE_SUI_AMOUNT, tok_amt)
    }

   /// Add liquidity to the `Pool`. Sender needs to provide both
    /// `Coin<SUI>` and `Coin<T>`, and in exchange he gets `Coin<LSP>` -
    /// liquidity provider tokens.
    public fun add_liquidity<T>(
        pool: &mut Pool<T>, sui: Coin<SUI>, token: Coin<T>, ctx: &mut TxContext
    ) {
        assert!(coin::value(&sui) > 0, EZeroAmount);
        assert!(coin::value(&token) > 0, EZeroAmount);

        let sui_balance = coin::into_balance(sui);
        let tok_balance = coin::into_balance(token);

        let (sui_amount, tok_amount) = get_amounts(pool);

        let sui_added = balance::value(&sui_balance);
        let tok_added = balance::value(&tok_balance);

        let sui_amt = balance::join(&mut pool.sui, sui_balance);
        let tok_amt = balance::join(&mut pool.token, tok_balance);

        assert!(sui_amt < MAX_POOL_VALUE, EPoolFull);
        assert!(tok_amt < MAX_POOL_VALUE, EPoolFull);
    }

    public fun remove_liquidity<T>(
        _: &AdminCap, 
        pool: &mut Pool<T>,
        ctx: &mut TxContext
    ): (Coin<SUI>, Coin<T>) {
        let (sui_amt, tok_amt) = get_amounts(pool);
        (
            coin::take(&mut pool.sui, sui_amt, ctx),
            coin::take(&mut pool.token, tok_amt, ctx)
        )
    }


}

