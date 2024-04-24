module bonding_curve::events {
    
    use sui::event;
    
    public struct PoolCreated<phantom T> has copy, drop {
        pool_id: ID,
        creator: address,
    }

    // Pool Created Event
    public(package) fun emit_pool_created<T>(
        pool_id: ID,
        creator: address
    ) {
        event::emit(PoolCreated<T> { pool_id, creator });
    }

    // Pool Migrated Event
    public struct PoolMigrated<phantom T> has copy, drop {
        pool_id: ID,
        sui_amount: u64,
        token_amount: u64
    }

    public(package) fun emit_pool_migrated<T>(
        pool_id: ID,
        sui_amount: u64,
        token_amount: u64
    ) {
        event::emit(PoolMigrated<T> { pool_id, sui_amount, token_amount });
    }

    // Trade SUI event
    public struct SwapSuiEvent<phantom T> has copy, drop {
        pool_id: ID,
        user: address,
        sui_amount: u64,
        token_amount: u64
    }

    public(package) fun emit_swap_sui_event<T>(
        pool_id: ID,
        user: address,
        sui_amount: u64,
        token_amount: u64
    ) {
        event::emit(SwapSuiEvent<T> { pool_id, user, sui_amount, token_amount });
    }

    // Trade Token event
    public struct SwapTokenEvent<phantom T> has copy, drop {
        pool_id: ID,
        user: address,
        sui_amount: u64,
        token_amount: u64
    }

    public(package) fun emit_swap_token_event<T>(
        pool_id: ID,
        user: address,
        sui_amount: u64,
        token_amount: u64
    ) {
        event::emit(SwapSuiEvent<T> { pool_id, user, sui_amount, token_amount });
    }
}