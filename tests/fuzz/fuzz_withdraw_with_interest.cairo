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
    interfaces::{
        ILPTokenDispatcher, ILPTokenDispatcherTrait, IMarketDispatcher, IMarketDispatcherTrait,
        IPoolDispatcher, IPoolDispatcherTrait,
    },
    market::Market::{Event, Withdrew},
};
use super::super::mocks::mock_aggregator::{
    IMockAggregatorDispatcher, IMockAggregatorDispatcherTrait,
};
use super::super::test_constants::{
    MOCK_AGGREGATOR_BLOCK_NUM, MOCK_AGGREGATOR_COLLATERAL_TOKEN_PRICE_ANSWER,
    MOCK_AGGREGATOR_OBSERVATION_TIMESTAMP, MOCK_AGGREGATOR_TOKEN_PRICE_ANSWER,
    MOCK_AGGREGATOR_TRANSMISSION_TIMESTAMP, TEST_BORROW_AMOUNT_1, TEST_BORROW_TIME,
    TEST_SUPPLY_AMOUNT_1, TEST_USER_1, TEST_USER_2, TEST_WITHDRAW_AMOUNT_1,
};
use super::super::test_market::{deploy_contract, deploy_new_pool};

#[test]
#[fuzzer(runs: 100, seed: 23)]
fn fuzz_withdraw_with_interest(seed: u64) {
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
    let test_withdraw_amount_1_hash_span: Span<felt252> = array![
        seed.into(), TEST_WITHDRAW_AMOUNT_1.try_into().unwrap(), 'test_withdraw_amt_1_hash_span',
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
    let test_withdraw_amount_1: u256 = poseidon_hash_span(test_withdraw_amount_1_hash_span)
        .into() % test_supply_amount_1
        + 1;

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

    // Repay
    start_cheat_block_timestamp_global(repay_timestamp);
    market_dispatcher
        .repay(token_contract_address, collateral_token_contract_address, expected_borrow_id);

    // Cache data before
    let lp_token_dispatcher = ILPTokenDispatcher {
        contract_address: pool_dispatcher.get_lp_token_address(),
    };
    let expected_token_withdraw_amount = test_withdraw_amount_1
        * pool_dispatcher.get_total_supply()
        / lp_token_dispatcher.total_supply();
    let expected_additional_token_claim = test_withdraw_amount_1
        * expected_interest_amount
        / lp_token_dispatcher.total_supply();
    let initial_equivalent_token_amount = test_withdraw_amount_1
        * test_supply_amount_1
        / lp_token_dispatcher.total_supply();
    let token_balance_before = mock_token_dispatcher.balance_of(test_user_1);
    let lp_token_balance_before = lp_token_dispatcher.balance_of(test_user_1);
    let lp_owned_before = pool_dispatcher.get_user_to_lp_owned(test_user_1);
    let total_supply_before = pool_dispatcher.get_total_supply();

    //////////////
    // Interact //
    //////////////

    // Spy event
    let mut spy = spy_events();

    // Withdraw
    stop_cheat_caller_address(market_contract_address);
    start_cheat_caller_address(market_contract_address, test_user_1);
    market_dispatcher
        .withdraw(
            token_contract_address, collateral_token_contract_address, test_withdraw_amount_1,
        );
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
                    Event::Withdrew(
                        Withdrew {
                            user: test_user_1,
                            token: token_contract_address,
                            collateral_token: collateral_token_contract_address,
                            lp_amount_withdraw: test_withdraw_amount_1,
                            token_withdraw_amount: expected_token_withdraw_amount,
                        },
                    ),
                ),
            ],
        );

    // Assert token claim amount
    assert(
        expected_token_withdraw_amount == expected_additional_token_claim
            + initial_equivalent_token_amount,
        'Invalid token claim amount',
    );

    // Assert token balance
    assert(
        token_balance_before
            + expected_token_withdraw_amount == mock_token_dispatcher.balance_of(test_user_1),
        'Invalid token balance',
    );

    // Assert lp token balance
    assert(
        lp_token_balance_before
            - test_withdraw_amount_1 == lp_token_dispatcher.balance_of(test_user_1),
        'Invalid lp token balance',
    );

    // Assert lp owned
    assert(
        lp_owned_before
            - test_withdraw_amount_1 == pool_dispatcher.get_user_to_lp_owned(test_user_1),
        'Invalid lp owned',
    );

    // Assert total supply
    assert(
        total_supply_before - expected_token_withdraw_amount == pool_dispatcher.get_total_supply(),
        'Invalid total supply',
    );
}
