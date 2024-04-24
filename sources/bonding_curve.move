
/// Module: bonding_curve
module bonding_curve::bonding_curve {
    use sui::object::{Self, UID, ID};
    use sui::coin::{Self, Coin, CoinMetadata, get_decimals};
    use sui::balance::{Self, Supply, Balance};
    use sui::sui::SUI;
    use sui::transfer;
    use sui::math;
    use sui::tx_context::{Self, TxContext};
    use bonding_curve::events;

    /// For when supplied Token and Coin are incorrect amounts.
    const EIncorrectAmount: u64 = 0;

    /// For when someone tries to swap in an empty pool.
    const EReservesEmpty: u64 = 1;

    /// For when someone attempts to add more liquidity than u128 Math allows.
    const EPoolFull: u64 = 2;

    /// Trading disabled
    const ETradingDisabled: u64 = 3;

    /// Does not match 9 decimal points
    const EIncorrectDecimalMetadata: u64 = 4;

    /// The integer scaling setting for fees calculation.
    const FEE_SCALING: u128 = 100;

    const DEFAULT_FEE: u128 = 100;

    const DEFAULT_FEE_PERCENTAGE: u128 = 99;

    /// The max value that can be held in one of the Balances of
    /// a Pool. U64 MAX
    const MAX_POOL_VALUE: u64 = {
        18446744073709551615
    };

    const BASE_SUI_AMOUNT: u64 = 4200 * 1_000_000_000;
    const DEFAULT_CREATION_FEE: u64 = 1 * 1_000_000_000;
    const DEFAULT_SUPPLY: u64 = 1_000_000_000 * 1_000_000_000;

    /// The pool of this contract to store all fees
    /// The fee is always taken in SUI
    public struct Pooler has key {
        id: UID,
        sui: Balance<SUI>,
        creation_fee: u64
    }

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
        let pool = Pooler {
            id: object::new(ctx),
            sui: balance::zero(),
            creation_fee: DEFAULT_CREATION_FEE
        };
        transfer::share_object(pool);
    }

    public fun withdraw_fees(
        admin_cap: &AdminCap, 
        pooler: &mut Pooler, 
        ctx: &mut TxContext
    ): Coin<SUI> {
        let sui_amt = balance::value(&pooler.sui);
        coin::take(&mut pooler.sui, sui_amt, ctx)
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
        pooler: &mut Pooler,
        token: Coin<T>,
        token_metadata: &CoinMetadata<T>,
        sui: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        let sui_amt = coin::value(&sui);
        let tok_amt = coin::value(&token);
        let creator = tx_context::sender(ctx);
        let token_metadata_decimal = get_decimals(token_metadata);

        assert!(token_metadata_decimal == 9, EIncorrectDecimalMetadata);
        assert!(tok_amt == DEFAULT_SUPPLY, EIncorrectAmount);
        assert!(sui_amt > pooler.creation_fee && tok_amt == DEFAULT_SUPPLY, EIncorrectAmount);
        assert!(sui_amt < MAX_POOL_VALUE && tok_amt < MAX_POOL_VALUE, EPoolFull);

        // Deposit creation fee into pool
        let mut sui_balance = coin::into_balance(sui);
        let fee_balance = balance::split(&mut sui_balance, pooler.creation_fee);
        balance::join(&mut pooler.sui, fee_balance);

        let new_pool = Pool<T> {
            id: object::new(ctx),
            token: coin::into_balance(token),
            sui: sui_balance,
            trading_enabled: true
        };

        let pool_uid = object::id(&new_pool);
        events::emit_pool_created<T>(pool_uid, creator);
        transfer::share_object(new_pool);
    }

    // Creates the pool, but also swaps for the intial liquidity of the pool to prevent MEV attacks
    public fun create_pool_and_buy_liquidity<T>(
        pooler: &mut Pooler,
        token: Coin<T>,
        token_metadata: &CoinMetadata<T>,
        sui: Coin<SUI>,
        ctx: &mut TxContext
    ): Coin<T> {
        let sui_amt = coin::value(&sui);
        let tok_amt = coin::value(&token);
        let creator = tx_context::sender(ctx);
        let token_metadata_decimal = get_decimals(token_metadata);

        assert!(token_metadata_decimal == 9, EIncorrectDecimalMetadata);
        assert!(tok_amt == DEFAULT_SUPPLY, EIncorrectAmount);
        assert!(sui_amt > pooler.creation_fee && tok_amt == DEFAULT_SUPPLY, EIncorrectAmount);
        assert!(sui_amt < MAX_POOL_VALUE && tok_amt < MAX_POOL_VALUE, EPoolFull);

        // Deposit creation fee into pool
        let mut sui_balance = coin::into_balance(sui);
        let fee_balance = balance::split(&mut sui_balance, pooler.creation_fee);
        balance::join(&mut pooler.sui, fee_balance);
        let mut pool_creation_amount = balance::split(&mut sui_balance, 1);

        let mut new_pool = Pool<T> {
            id: object::new(ctx),
            token: coin::into_balance(token),
            sui: pool_creation_amount,
            trading_enabled: true
        };

        let pool_uid = object::id(&new_pool);
        events::emit_pool_created<T>(pool_uid, creator);
        
        let remaining_amt = balance::value(&sui_balance);
        let swap_coin = coin::take(&mut sui_balance, remaining_amt, ctx);
        balance::destroy_zero(sui_balance);
        // Buy liquidity
        let buy_token_coin = swap_sui<T>(
            pooler,
            &mut new_pool,
            swap_coin,
            ctx
        );

        let tok_amt = coin::value(&buy_token_coin);
        events::emit_swap_sui_event<T>(
            pool_uid, 
            creator,
            remaining_amt,
            tok_amt
        );

        transfer::share_object(new_pool);
        buy_token_coin
    }

    public fun swap_token<T>(
        pooler: &mut Pooler,
        pool: &mut Pool<T>, 
        token: Coin<T>, 
        ctx: &mut TxContext
    ): Coin<SUI> {
        assert!(coin::value(&token) > 0, EIncorrectAmount);
        assert!(pool.trading_enabled, ETradingDisabled);

        let tok_balance = coin::into_balance(token);
        let (sui_reserve, token_reserve) = get_amounts(pool);

        assert!(sui_reserve > 0 && token_reserve > 0, EReservesEmpty);
        let tok_balance_amt = balance::value(&tok_balance);

        let output_amount = get_input_price(
            tok_balance_amt,
            token_reserve,
            sui_reserve + BASE_SUI_AMOUNT,
        );

        balance::join(&mut pool.token, tok_balance);
        let mut sui_result_balance = balance::split(&mut pool.sui, output_amount);
        let sui_amt = balance::value(&sui_result_balance);
        let after_fee_sui = (((sui_amt as u128) * 99 / 100) as u64);
        let return_coin = coin::take(&mut sui_result_balance, after_fee_sui, ctx);
        balance::join(&mut pooler.sui, sui_result_balance);
        
        let user = tx_context::sender(ctx);

        // Emit event
        events::emit_swap_token_event<T>(
            object::id(pool), 
            user,
            after_fee_sui,
            tok_balance_amt
        );
        return_coin
    }

    /// Swap `Coin<SUI>` for the `Coin<T>`.
    /// Returns Coin<T>.
    public fun swap_sui<T>(
        pooler: &mut Pooler,
        pool: &mut Pool<T>, 
        sui: Coin<SUI>, 
        ctx: &mut TxContext
    ): Coin<T> {
        assert!(coin::value(&sui) > 0, EIncorrectAmount);
        assert!(pool.trading_enabled, ETradingDisabled);

        let mut sui_balance = coin::into_balance(sui);
        let sui_amt = balance::value(&sui_balance);
        // Calculate the output amount
        let (sui_reserve, token_reserve) = get_amounts(pool);

        // Take the fee on sui
        let after_fee_sui = (((sui_amt as u128) * 99 / 100) as u64);
        let after_fee_balance = balance::split(&mut sui_balance, after_fee_sui);
        std::debug::print(&after_fee_sui);

        assert!(sui_reserve > 0 && token_reserve > 0, EReservesEmpty);

        let output_amount = get_input_price(
            balance::value(&after_fee_balance),
            sui_reserve + BASE_SUI_AMOUNT,
            token_reserve
        );

        balance::join(&mut pool.sui, after_fee_balance);
        // The rest of the fees
        balance::join(&mut pooler.sui, sui_balance);
        let user = tx_context::sender(ctx);

        // Emit event
        events::emit_swap_sui_event<T>(
            object::id(pool), 
            user,
            sui_amt,
            output_amount
        );

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
        assert!(coin::value(&sui) > 0, EIncorrectAmount);
        assert!(coin::value(&token) > 0, EIncorrectAmount);

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
        // Emit event
        events::emit_pool_migrated<T>(
            object::id(pool), 
            sui_amt,
            tok_amt
        );

        (
            coin::take(&mut pool.sui, sui_amt, ctx),
            coin::take(&mut pool.token, tok_amt, ctx)
        )
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx)
    }

    /// Create new `Pool` for token `T`. Each Pool holds a `Coin<T>`
    /// and a `Coin<SUI>`. Swaps are available in both directions.
    ///
    /// Share is calculated based on Uniswap's constant product formula:
    ///  liquidity = sqrt( X * Y )
    #[test_only]
    public fun create_pool_for_testing<T>(
        pooler: &mut Pooler,
        token: Coin<T>,
        sui: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        let sui_amt = coin::value(&sui);
        let tok_amt = coin::value(&token);
        let creator = tx_context::sender(ctx);
        // let token_metadata_decimal = get_decimals(token_metadata);

        // assert!(token_metadata_decimal == 9, EIncorrectDecimalMetadata);
        assert!(tok_amt == DEFAULT_SUPPLY, EIncorrectAmount);
        assert!(sui_amt > pooler.creation_fee && tok_amt == DEFAULT_SUPPLY, EIncorrectAmount);
        assert!(sui_amt < MAX_POOL_VALUE && tok_amt < MAX_POOL_VALUE, EPoolFull);

        // Deposit creation fee into pool
        let mut sui_balance = coin::into_balance(sui);
        let fee_balance = balance::split(&mut sui_balance, pooler.creation_fee);
        balance::join(&mut pooler.sui, fee_balance);

        let new_pool = Pool<T> {
            id: object::new(ctx),
            token: coin::into_balance(token),
            sui: sui_balance,
            trading_enabled: true
        };

        let pool_uid = object::id(&new_pool);
        events::emit_pool_created<T>(pool_uid, creator);
        transfer::share_object(new_pool);
    }

    // Creates the pool, but also swaps for the intial liquidity of the pool to prevent MEV attacks
    #[test_only]
    public fun create_pool_and_buy_liquidity_for_testing<T>(
        pooler: &mut Pooler,
        token: Coin<T>,
        // token_metadata: &CoinMetadata<T>,
        sui: Coin<SUI>,
        ctx: &mut TxContext
    ): Coin<T> {
        let sui_amt = coin::value(&sui);
        let tok_amt = coin::value(&token);
        let creator = tx_context::sender(ctx);
        // let token_metadata_decimal = get_decimals(token_metadata);

        // assert!(token_metadata_decimal == 9, EIncorrectDecimalMetadata);
        assert!(tok_amt == DEFAULT_SUPPLY, EIncorrectAmount);
        assert!(sui_amt > pooler.creation_fee && tok_amt == DEFAULT_SUPPLY, EIncorrectAmount);
        assert!(sui_amt < MAX_POOL_VALUE && tok_amt < MAX_POOL_VALUE, EPoolFull);

        // Deposit creation fee into pool
        let mut sui_balance = coin::into_balance(sui);
        let fee_balance = balance::split(&mut sui_balance, pooler.creation_fee);
        balance::join(&mut pooler.sui, fee_balance);
        let mut pool_creation_amount = balance::split(&mut sui_balance, 1);

        let mut new_pool = Pool<T> {
            id: object::new(ctx),
            token: coin::into_balance(token),
            sui: pool_creation_amount,
            trading_enabled: true
        };

        let pool_uid = object::id(&new_pool);
        events::emit_pool_created<T>(pool_uid, creator);
        
        let remaining_amt = balance::value(&sui_balance);
        let swap_coin = coin::take(&mut sui_balance, remaining_amt, ctx);
        balance::destroy_zero(sui_balance);
        // Buy liquidity
        let buy_token_coin = swap_sui<T>(
            pooler,
            &mut new_pool,
            swap_coin,
            ctx
        );

        transfer::share_object(new_pool);
        buy_token_coin
    }
}

