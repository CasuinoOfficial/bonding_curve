#[test_only]
module bonding_curve::meme {

    use std::option;
    use sui::coin;
    use sui::tx_context::TxContext;
    use sui::transfer;
    use sui::url;

    public struct MEME has drop {}
    const ADMIN: address = @0xAAA;

    fun init(otw: MEME, ctx: &mut TxContext) {
        let (mut meme_treasury_cap, meme_metadata) = coin::create_currency(
            otw,
            9,
            b"MEME",
            b"MEME USD",
            b"the meme used to mint",
            option::some(url::new_unsafe_from_bytes(
                b"https://ipfs.io/ipfs/QmYH4seo7K9CiFqHGDmhbZmzewHEapAhN9aqLRA7af2vMW"),
            ),
            ctx,
        );
        transfer::public_freeze_object(meme_treasury_cap);
        transfer::public_freeze_object(meme_metadata);
    }
}

#[test_only]
module bonding_curve::bonding_curve_tests {
    // uncomment this line to import the module
    // use bonding_curve::bonding_curve;
    use sui::test_scenario::{Self as ts, Scenario};
    use bonding_curve::meme::MEME;
    use sui::coin::{Self};
    use bonding_curve::bonding_curve::{Self, Pool, Pooler};
    use sui::sui::SUI;

    const ENotImplemented: u64 = 0;
    const ADMIN: address = @0xAAA;
    const COIN_SCALER: u64 = 1_000_000_000;

    #[test_only]
    fun setup_for_testing(): Scenario {
        let mut scenario_val = ts::begin(ADMIN);
        let scenario = &mut scenario_val;
        // Create the pool
        ts::next_tx(scenario, ADMIN);
        {
            bonding_curve::init_for_testing(ts::ctx(scenario));
            // let meme_coin = ts::take_from_sender<Coin<MEME>>(scenario);
            let init_fund = coin::mint_for_testing<MEME>(1_000_000_000 * COIN_SCALER, ts::ctx(scenario));
            let init_sui = coin::mint_for_testing<SUI>(1 * COIN_SCALER, ts::ctx(scenario));

            bonding_curve::create_pool<MEME>(
                init_fund,
                init_sui,
                ts::ctx(scenario)
            );

        };
        
        scenario_val
    }

    #[test]
    fun test_bonding_curve() {
        let scenario_val = setup_for_testing();
        ts::end(scenario_val);
    }

    // #[test, expected_failure(abort_code = bonding_curve::bonding_curve_tests::ENotImplemented)]
    // fun test_bonding_curve_fail() {
    //     abort ENotImplemented
    // }

    #[test]
    fun test_remove_liquidity() {
        let mut scenario_val = setup_for_testing();
        let scenario = &mut scenario_val;
        let bob = @0xbb;
        ts::next_tx(scenario, bob);
        {
            let mut pool = ts::take_shared<Pool<MEME>>(scenario);
            let mut pooler = ts::take_shared<Pooler>(scenario);

            let result_meme = bonding_curve::swap_sui<MEME>(
                &mut pooler,
                &mut pool,
                coin::mint_for_testing<SUI>(25000 * COIN_SCALER, ts::ctx(scenario)),
                ts::ctx(scenario),
            );
            let (sui_reserve, tok_reserve) = bonding_curve::get_amounts<MEME>(&pool);

            let result_sui = bonding_curve::swap_token<MEME>(
                &mut pooler,
                &mut pool,
                result_meme,
                ts::ctx(scenario),
            );

            // std::debug::print(&result_meme);
            transfer::public_transfer(result_sui, bob);
            // std::debug::print(&sui_reserve);
            // std::debug::print(&tok_reserve);
            ts::return_shared(pool);
            ts::return_shared(pooler);
        };
        ts::end(scenario_val);

        // assert removing from pool works

        // set liquidity to 0
        // assert removing from pool fails
    }
}

// 


// add liquidity / remove liquidity removes all amounts from the pool

// add -> swap -> remove
// add -> swap -> swap -> remove

// remove when no share in pool



// pause trading button for migration

// assert that get_input_price parameters always have BASE_SUI_AMOUNT added where needed, either to input_reserve or output_reserve
