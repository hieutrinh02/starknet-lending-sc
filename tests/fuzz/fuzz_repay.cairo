// External imports
use core::num::traits::Bounded;
use core::poseidon::poseidon_hash_span;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    EventSpyAssertionsTrait, spy_events, start_cheat_block_timestamp_global,
    start_cheat_caller_address, stop_cheat_block_timestamp_global, stop_cheat_caller_address,
};
use starknet::syscalls::call_contract_syscall;
use starknet::{ContractAddress, SyscallResultTrait, get_block_timestamp};

// Internal imports
use starknet_lending_sc::{
    constants::{YEAR_TIMESTAMPS, ten_pow_decimals},
    interfaces::{IMarketDispatcher, IMarketDispatcherTrait, IPoolDispatcher, IPoolDispatcherTrait},
    market::Market::{Event, Repaid},
};
use super::super::mocks::mock_aggregator::{
    IMockAggregatorDispatcher, IMockAggregatorDispatcherTrait,
};
use super::super::test_constants::{
    MOCK_AGGREGATOR_BLOCK_NUM, MOCK_AGGREGATOR_COLLATERAL_TOKEN_PRICE_ANSWER,
    MOCK_AGGREGATOR_OBSERVATION_TIMESTAMP, MOCK_AGGREGATOR_TOKEN_PRICE_ANSWER,
    MOCK_AGGREGATOR_TRANSMISSION_TIMESTAMP, TEST_BORROW_AMOUNT_1, TEST_BORROW_TIME,
    TEST_SUPPLY_AMOUNT_1, TEST_USER_1, TEST_USER_2,
};
use super::super::test_market::{deploy_contract, deploy_new_pool};

#[test]
#[fuzzer(runs: 100, seed: 23)]
fn fuzz_repay(seed: u64) {
    ///////////
    // Setup //
    ///////////

    // Seed generate value
    let test_user_1_hash_span: Span<felt252> = array![
        seed.into(), TEST_USER_1.into(), 'test_user_1_hash_span',
    ]
        .span();
    let test_user_2_hash_span: Span<felt252> = array![
        seed.into(), TEST_USER_2.into(), 'test_user_2_hash_span',
    ]
        .span();
    let test_supply_amount_1_hash_span: Span<felt252> = array![
        seed.into(), TEST_SUPPLY_AMOUNT_1.try_into().unwrap(), 'test_supply_amount_1_hash_span',
    ]
        .span();
    let test_borrow_amount_1_hash_span: Span<felt252> = array![
        seed.into(), TEST_BORROW_AMOUNT_1.try_into().unwrap(), 'test_borrow_amount_1_hash_span',
    ]
        .span();
    let test_user_1: ContractAddress = poseidon_hash_span(test_user_1_hash_span)
        .try_into()
        .unwrap();
    let test_user_2: ContractAddress = poseidon_hash_span(test_user_2_hash_span)
        .try_into()
        .unwrap();
    let test_supply_amount_1: u256 = poseidon_hash_span(test_supply_amount_1_hash_span)
        .into() % Bounded::<u64>::MAX
        .into()
        + 1;
    let test_borrow_amount_1: u256 = poseidon_hash_span(test_borrow_amount_1_hash_span)
        .into() % (test_supply_amount_1 / 2)
        + 1;
    let test_collateral_amount_1: u256 = test_borrow_amount_1 * 2;

    // Deploy market
    let (
        market_contract_address,
        _,
        _,
        token_contract_address,
        collateral_token_contract_address,
        mock_token_aggregator,
        mock_collateral_token_aggregator,
    ) =
        deploy_contract();
    let market_dispatcher = IMarketDispatcher { contract_address: market_contract_address };

    // Deploy pool
    deploy_new_pool(
        market_contract_address, token_contract_address, collateral_token_contract_address,
    );

    // Mint mock token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@test_user_1, ref mint_calldata);
    Serde::serialize(@test_supply_amount_1, ref mint_calldata);
    let mut res = call_contract_syscall(
        token_contract_address, selector!("mint"), mint_calldata.span(),
    )
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token_contract_address };
    start_cheat_caller_address(token_contract_address, test_user_1);
    mock_token_dispatcher.approve(market_contract_address, test_supply_amount_1);
    stop_cheat_caller_address(token_contract_address);

    // Supply
    start_cheat_caller_address(market_contract_address, test_user_1);
    market_dispatcher
        .supply(token_contract_address, collateral_token_contract_address, test_supply_amount_1);
    stop_cheat_caller_address(market_contract_address);

    // Mint mock collateral token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@test_user_2, ref mint_calldata);
    Serde::serialize(@test_collateral_amount_1, ref mint_calldata);
    let mut res = call_contract_syscall(
        collateral_token_contract_address, selector!("mint"), mint_calldata.span(),
    )
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock collateral token
    let mock_collateral_token_dispatcher = IERC20Dispatcher {
        contract_address: collateral_token_contract_address,
    };
    start_cheat_caller_address(collateral_token_contract_address, test_user_2);
    mock_collateral_token_dispatcher.approve(market_contract_address, test_collateral_amount_1);
    stop_cheat_caller_address(collateral_token_contract_address);

    // Setup price feed
    let mock_token_aggregator_dispatcher = IMockAggregatorDispatcher {
        contract_address: mock_token_aggregator,
    };
    let mock_collateral_token_aggregator_dispatcher = IMockAggregatorDispatcher {
        contract_address: mock_collateral_token_aggregator,
    };
    mock_token_aggregator_dispatcher
        .set_latest_round_data(
            MOCK_AGGREGATOR_TOKEN_PRICE_ANSWER,
            MOCK_AGGREGATOR_BLOCK_NUM,
            MOCK_AGGREGATOR_OBSERVATION_TIMESTAMP,
            MOCK_AGGREGATOR_TRANSMISSION_TIMESTAMP,
        );
    mock_collateral_token_aggregator_dispatcher
        .set_latest_round_data(
            MOCK_AGGREGATOR_COLLATERAL_TOKEN_PRICE_ANSWER,
            MOCK_AGGREGATOR_BLOCK_NUM,
            MOCK_AGGREGATOR_OBSERVATION_TIMESTAMP,
            MOCK_AGGREGATOR_TRANSMISSION_TIMESTAMP,
        );

    // Borrow
    let borrow_timestamp = get_block_timestamp();
    start_cheat_caller_address(market_contract_address, test_user_2);
    market_dispatcher
        .borrow(
            token_contract_address,
            test_borrow_amount_1,
            collateral_token_contract_address,
            test_collateral_amount_1,
        );

    // Cache data before
    let pool_contract_address = market_dispatcher
        .get_pools(token_contract_address, collateral_token_contract_address);
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    let expected_borrow_id = pool_dispatcher.get_user_borrow_quantity(test_user_2) - 1;
    let expected_user_borrow_info = pool_dispatcher
        .get_user_borrow_info(test_user_2, expected_borrow_id);
    let expected_user_borrow_apr = expected_user_borrow_info.borrow_apr;
    let expected_user_borrow_start_time = expected_user_borrow_info.borrow_start_time;
    let repay_timestamp = borrow_timestamp + TEST_BORROW_TIME;
    let expected_interest_amount = test_borrow_amount_1
        * expected_user_borrow_apr
        * (repay_timestamp - expected_user_borrow_start_time).into()
        / (YEAR_TIMESTAMPS.into() * ten_pow_decimals().into() * ten_pow_decimals().into());
    let expected_total_repay_amount = test_borrow_amount_1 + expected_interest_amount;

    // Mint `expected_interest_amount` of mock token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@test_user_2, ref mint_calldata);
    Serde::serialize(@expected_interest_amount, ref mint_calldata);
    let mut res = call_contract_syscall(
        token_contract_address, selector!("mint"), mint_calldata.span(),
    )
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token_contract_address };
    start_cheat_caller_address(token_contract_address, test_user_2);
    mock_token_dispatcher.approve(market_contract_address, expected_total_repay_amount);
    stop_cheat_caller_address(token_contract_address);

    // Cache data before
    let token_balance_before = mock_token_dispatcher.balance_of(test_user_2);
    let token_allowance_before = mock_token_dispatcher
        .allowance(test_user_2, market_contract_address);
    let total_supply_before = pool_dispatcher.get_total_supply();
    let actual_interest_amount_before = pool_dispatcher.get_actual_interest_amount();
    let total_borrow_before = pool_dispatcher.get_total_borrow();
    let user_borrow_quantity_before = pool_dispatcher.get_user_borrow_quantity(test_user_2);
    let active_borrower_num_before = pool_dispatcher.get_active_borrower_num();
    let collateral_token_balance_before = mock_collateral_token_dispatcher.balance_of(test_user_2);

    //////////////
    // Interact //
    //////////////

    // Spy event
    let mut spy = spy_events();

    // Repay
    start_cheat_block_timestamp_global(repay_timestamp);
    market_dispatcher
        .repay(token_contract_address, collateral_token_contract_address, expected_borrow_id);
    stop_cheat_caller_address(market_contract_address);
    stop_cheat_block_timestamp_global();

    ////////////
    // Assert //
    ////////////

    // Assert event emitted
    spy
        .assert_emitted(
            @array![
                (
                    market_contract_address,
                    Event::Repaid(
                        Repaid {
                            user: test_user_2,
                            repay_token: token_contract_address,
                            collateral_token: collateral_token_contract_address,
                            borrow_id: expected_borrow_id,
                            interest_amount: expected_interest_amount,
                            total_repay_amount: expected_total_repay_amount,
                        },
                    ),
                ),
            ],
        );

    // Assert token balance
    assert(
        token_balance_before
            - expected_total_repay_amount == mock_token_dispatcher.balance_of(test_user_2),
        'Invalid token balance',
    );

    // Assert token allowance
    assert(
        token_allowance_before
            - expected_total_repay_amount == mock_token_dispatcher
                .allowance(test_user_2, market_contract_address),
        'Invalid token allowance',
    );

    // Assert total supply
    assert(
        total_supply_before + expected_interest_amount == pool_dispatcher.get_total_supply(),
        'Invalid total supply',
    );

    // Assert actual interest amount
    assert(
        actual_interest_amount_before
            + expected_interest_amount == pool_dispatcher.get_actual_interest_amount(),
        'Invalid amount',
    );

    // Assert total borrow
    assert(
        total_borrow_before - test_borrow_amount_1 == pool_dispatcher.get_total_borrow(),
        'Invalid total borrow',
    );

    // Assert user borrow quantity
    assert(
        user_borrow_quantity_before - 1 == pool_dispatcher.get_user_borrow_quantity(test_user_2),
        'Invalid borrow quantity',
    );

    // Assert active borrower num
    assert(
        active_borrower_num_before - 1 == pool_dispatcher.get_active_borrower_num(),
        'Invalid active borrower num',
    );

    // Assert collateral token balance
    assert(
        collateral_token_balance_before
            + expected_user_borrow_info
                .collateral_amount == mock_collateral_token_dispatcher
                .balance_of(test_user_2),
        'Invalid token balance',
    );
}
