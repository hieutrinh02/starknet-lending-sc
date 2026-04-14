// External imports
use core::num::traits::Zero;
use core::panic_with_felt252;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, EventSpyAssertionsTrait, declare, interact_with_state,
    spy_events, start_cheat_block_timestamp_global, start_cheat_caller_address,
    stop_cheat_block_timestamp_global, stop_cheat_caller_address,
};
use starknet::storage::{StoragePathEntry, StoragePointerReadAccess};
use starknet::syscalls::call_contract_syscall;
#[feature("deprecated-starknet-consts")]
use starknet::{
    ClassHash, ContractAddress, SyscallResultTrait, contract_address_const, get_block_timestamp,
};

// Internal imports
use starknet_lending_sc::{
    constants::{
        BASE_INTEREST_RATE, BORROW_LIMIT, OPTIMAL_UTILIZATION_RATE, RSLOPE_1, RSLOPE_2,
        THRESHOLD_LIQUIDATION, YEAR_TIMESTAMPS, ten_pow_decimals,
    },
    errors::Error,
    interfaces::{
        ILPTokenDispatcher, ILPTokenDispatcherTrait, IMarketDispatcher, IMarketDispatcherTrait,
        IMarketSafeDispatcher, IMarketSafeDispatcherTrait, IPoolDispatcher, IPoolDispatcherTrait,
    },
    lp_token::LPToken,
    market::{
        Market,
        Market::{
            Borrowed, Event, Liquidated, NewPoolDeployed, PriceFeedUpdated, Repaid, Supplied,
            Withdrew,
        },
    },
    pool::Pool,
};
use super::mocks::mock_aggregator::{IMockAggregatorDispatcher, IMockAggregatorDispatcherTrait};
use super::test_constants::{
    MOCK_AGGREGATOR_BLOCK_NUM, MOCK_AGGREGATOR_COLLATERAL_TOKEN_LIQUIDATION_PRICE_ANSWER,
    MOCK_AGGREGATOR_COLLATERAL_TOKEN_PRICE_ANSWER, MOCK_AGGREGATOR_DECIMALS,
    MOCK_AGGREGATOR_OBSERVATION_TIMESTAMP, MOCK_AGGREGATOR_TOKEN_PRICE_ANSWER,
    MOCK_AGGREGATOR_TRANSMISSION_TIMESTAMP, TEST_BORROW_AMOUNT_1, TEST_BORROW_AMOUNT_2,
    TEST_BORROW_TIME, TEST_COLLATERAL_AMOUNT_1, TEST_COLLATERAL_AMOUNT_2, TEST_OWNER,
    TEST_SUPPLY_AMOUNT_1, TEST_SUPPLY_AMOUNT_2, TEST_TOKEN, TEST_USER_1, TEST_USER_2,
    TEST_WITHDRAW_AMOUNT_1, mock_erc20_collateral_token_name, mock_erc20_token_name,
    mock_lp_token_name,
};

pub fn deploy_contract() -> (
    ContractAddress,
    ClassHash,
    ClassHash,
    ContractAddress,
    ContractAddress,
    ContractAddress,
    ContractAddress,
) {
    // Declare contract
    let pool_contract = declare("Pool").unwrap_syscall().contract_class();
    let lp_token_contract = declare("LPToken").unwrap_syscall().contract_class();
    let mock_erc20_token_contract = declare("MockERC20").unwrap_syscall().contract_class();
    let mock_aggregator_contract = declare("MockAggregator").unwrap_syscall().contract_class();
    let market_contract = declare("Market").unwrap_syscall().contract_class();

    // Prepare pool deploy data
    let mock_erc20_token_name: ByteArray = mock_erc20_token_name();
    let mock_erc20_collateral_token_name: ByteArray = mock_erc20_collateral_token_name();
    let mut mock_erc20_token_deploy_data: Array<felt252> = array![];
    let mut mock_erc20_collateral_token_deploy_data: Array<felt252> = array![];
    Serde::serialize(@mock_erc20_token_name, ref mock_erc20_token_deploy_data);
    Serde::serialize(@mock_erc20_token_name, ref mock_erc20_token_deploy_data);
    Serde::serialize(
        @mock_erc20_collateral_token_name, ref mock_erc20_collateral_token_deploy_data,
    );
    Serde::serialize(
        @mock_erc20_collateral_token_name, ref mock_erc20_collateral_token_deploy_data,
    );
    let (_token, _) = mock_erc20_token_contract
        .deploy(@mock_erc20_token_deploy_data)
        .unwrap_syscall();
    let (_collateral_token, _) = mock_erc20_token_contract
        .deploy(@mock_erc20_collateral_token_deploy_data)
        .unwrap_syscall();
    let mut mock_aggregator_deploy_data: Array<felt252> = array![];
    Serde::serialize(@MOCK_AGGREGATOR_DECIMALS, ref mock_aggregator_deploy_data);
    let (_mock_token_aggregator, _) = mock_aggregator_contract
        .deploy(@mock_aggregator_deploy_data)
        .unwrap_syscall();
    let (_mock_collateral_token_aggregator, _) = mock_aggregator_contract
        .deploy(@mock_aggregator_deploy_data)
        .unwrap_syscall();
    let _pool_contract_class_hash: ClassHash = *pool_contract.class_hash;
    let _lp_token_class_hash: ClassHash = *lp_token_contract.class_hash;
    let mut market_deploy_data = array![];
    Serde::serialize(@TEST_OWNER, ref market_deploy_data);
    Serde::serialize(@_pool_contract_class_hash, ref market_deploy_data);
    Serde::serialize(@_lp_token_class_hash, ref market_deploy_data);
    Serde::serialize(@array![_token, _collateral_token].span(), ref market_deploy_data);
    Serde::serialize(
        @array![_mock_token_aggregator, _mock_collateral_token_aggregator].span(),
        ref market_deploy_data,
    );

    // Deploy contract
    let (market_contract_address, _) = market_contract.deploy(@market_deploy_data).unwrap_syscall();

    // Return
    (
        market_contract_address,
        _pool_contract_class_hash,
        _lp_token_class_hash,
        _token,
        _collateral_token,
        _mock_token_aggregator,
        _mock_collateral_token_aggregator,
    )
}

pub fn deploy_new_pool(
    market_contract_address: ContractAddress,
    token: ContractAddress,
    collateral_token: ContractAddress,
) {
    // Setup
    let market_dispatcher = IMarketDispatcher { contract_address: market_contract_address };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_OWNER);
    market_dispatcher.deploy_new_pool(token, collateral_token);
    stop_cheat_caller_address(market_contract_address);
}

#[test]
fn test_deploy_market() {
    // Setup
    let (
        market_contract_address,
        _pool_contract_class_hash,
        _lp_token_class_hash,
        token,
        collateral_token,
        _mock_token_aggregator,
        _mock_collateral_token_aggregator,
    ) =
        deploy_contract();

    // Assert
    interact_with_state(
        market_contract_address,
        || {
            let mut state = Market::contract_state_for_testing();
            let owner = state.owner.read();
            let pool_class_hash = state.pool_class_hash.read();
            let lp_token_class_hash = state.lp_token_class_hash.read();
            let token_aggregator = state.chainlink_price_feed_address.entry(token).read();
            let collateral_token_aggregator = state
                .chainlink_price_feed_address
                .entry(collateral_token)
                .read();
            assert(owner == TEST_OWNER, 'Invalid owner');
            assert(pool_class_hash == _pool_contract_class_hash, 'Invalid class hash');
            assert(lp_token_class_hash == _lp_token_class_hash, 'Invalid class hash');
            assert(token_aggregator == _mock_token_aggregator, 'Invalid address');
            assert(
                collateral_token_aggregator == _mock_collateral_token_aggregator, 'Invalid address',
            );
        },
    );
}

#[test]
fn test_get_price_usd() {
    // Setup
    let (
        market_contract_address,
        _,
        _,
        token,
        collateral_token,
        mock_token_aggregator,
        mock_collateral_token_aggregator,
    ) =
        deploy_contract();
    let mock_token_aggregator_dispatcher = IMockAggregatorDispatcher {
        contract_address: mock_token_aggregator,
    };
    let mock_collateral_token_aggregator_dispatcher = IMockAggregatorDispatcher {
        contract_address: mock_collateral_token_aggregator,
    };
    let market_dispatcher = IMarketDispatcher { contract_address: market_contract_address };

    // Interact
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
    let (token_price, token_price_decimals) = market_dispatcher.get_price_usd(token);
    let (collateral_token_price, collateral_token_price_decimals) = market_dispatcher
        .get_price_usd(collateral_token);

    // Assert
    assert(token_price == MOCK_AGGREGATOR_TOKEN_PRICE_ANSWER, 'Invalid price answer');
    assert(token_price_decimals == MOCK_AGGREGATOR_DECIMALS, 'Invalid price decimals');
    assert(
        collateral_token_price == MOCK_AGGREGATOR_COLLATERAL_TOKEN_PRICE_ANSWER,
        'Invalid price answer',
    );
    assert(collateral_token_price_decimals == MOCK_AGGREGATOR_DECIMALS, 'Invalid price decimals');
}

#[test]
#[feature("safe_dispatcher")]
fn test_get_price_usd_revert_unknown_token_address() {
    // Setup
    let (market_contract_address, _, _, _, _, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    match market_safe_dispatcher.get_price_usd(TEST_TOKEN) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::UNKNOWN_TOKEN_ADDRESS, *panic_data.at(0))
        },
    }
}

#[test]
#[feature("safe_dispatcher")]
fn test_get_pools_revert_pool_not_exist() {
    // Setup
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    match market_safe_dispatcher.get_pools(token, collateral_token) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::POOL_NOT_EXIST, *panic_data.at(0))
        },
    }
}

#[test]
fn test_deploy_new_pool() {
    // Setup
    let (
        market_contract_address,
        _,
        _,
        token_contract_address,
        collateral_token_contract_address,
        _,
        _,
    ) =
        deploy_contract();
    let market_dispatcher = IMarketDispatcher { contract_address: market_contract_address };

    // Interact
    let mut spy = spy_events();
    deploy_new_pool(
        market_contract_address, token_contract_address, collateral_token_contract_address,
    );

    // Assert
    let pool_contract_address = market_dispatcher
        .get_pools(token_contract_address, collateral_token_contract_address);
    spy
        .assert_emitted(
            @array![
                (
                    market_contract_address,
                    Event::NewPoolDeployed(
                        NewPoolDeployed {
                            token: token_contract_address,
                            collateral_token: collateral_token_contract_address,
                            pool_address: pool_contract_address,
                        },
                    ),
                ),
            ],
        );
    let lp_token = interact_with_state(
        pool_contract_address,
        || {
            let mut state = Pool::contract_state_for_testing();
            let market_contract = state.market_contract.read();
            let token = state.token.read();
            let collateral_token = state.collateral_token.read();
            let lp_token = state.lp_token.read();
            assert(market_contract == market_contract_address, 'Invalid market contract address');
            assert(token == token_contract_address, 'Invalid token');
            assert(
                collateral_token == collateral_token_contract_address, 'Invalid collateral token',
            );
            assert(lp_token.is_non_zero(), 'Invalid lp token');
            lp_token
        },
    );
    interact_with_state(
        lp_token,
        || {
            let mut state = LPToken::contract_state_for_testing();
            let market_contract = state.market_contract.read();
            let pool = state.pool.read();
            let name = state.erc20.ERC20_name.read();
            let symbol = state.erc20.ERC20_symbol.read();
            assert(market_contract == market_contract_address, 'Invalid market contract address');
            assert(pool == pool_contract_address, 'Invalid pool contract address');
            assert(name == mock_lp_token_name(), 'Invalid lp token name');
            assert(symbol == mock_lp_token_name(), 'Invalid lp token symbol');
        },
    );
    assert(pool_contract_address.is_non_zero(), 'Invalid pool address');
}

#[test]
#[feature("safe_dispatcher")]
fn test_deploy_new_pool_revert_not_owner() {
    // Setup
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher.deploy_new_pool(token, collateral_token) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_OWNER, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_deploy_new_pool_revert_pool_already_existed() {
    // Setup
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };
    deploy_new_pool(market_contract_address, token, collateral_token);

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_OWNER);
    match market_safe_dispatcher.deploy_new_pool(token, collateral_token) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::POOL_ALREADY_EXISTED, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
fn test_update_price_feed_address() {
    // Setup
    let (market_contract_address, _, _, token_contract_address, _, _, _) = deploy_contract();
    let market_dispatcher = IMarketDispatcher { contract_address: market_contract_address };

    // Interact
    let mut spy = spy_events();
    start_cheat_caller_address(market_contract_address, TEST_OWNER);
    market_dispatcher
        .update_price_feed_address(token_contract_address, contract_address_const::<0>());
    stop_cheat_caller_address(market_contract_address);

    // Assert
    spy
        .assert_emitted(
            @array![
                (
                    market_contract_address,
                    Event::PriceFeedUpdated(
                        PriceFeedUpdated {
                            token: token_contract_address,
                            feed_address: contract_address_const::<0>(),
                        },
                    ),
                ),
            ],
        );
    interact_with_state(
        market_contract_address,
        || {
            let mut state = Market::contract_state_for_testing();
            let feed_address = state
                .chainlink_price_feed_address
                .entry(token_contract_address)
                .read();
            assert(feed_address == contract_address_const::<0>(), 'Invalid address');
        },
    );
}

#[test]
#[feature("safe_dispatcher")]
fn test_update_price_feed_address_revert_not_owner() {
    // Setup
    let (market_contract_address, _, _, token_contract_address, _, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher
        .update_price_feed_address(token_contract_address, contract_address_const::<0>()) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_OWNER, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_update_price_feed_address_revert_invalid_token_address() {
    // Setup
    let (market_contract_address, _, _, _, _, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_OWNER);
    match market_safe_dispatcher
        .update_price_feed_address(contract_address_const::<0>(), contract_address_const::<0>()) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::INVALID_TOKEN_ADDRESS, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

////////////////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////// SUPPLY ////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////
#[test]
fn test_supply_first_supply_case() {
    ///////////
    // Setup //
    ///////////

    // Deploy market
    let (
        market_contract_address,
        _,
        _,
        token_contract_address,
        collateral_token_contract_address,
        _,
        _,
    ) =
        deploy_contract();
    let market_dispatcher = IMarketDispatcher { contract_address: market_contract_address };

    // Deploy pool
    deploy_new_pool(
        market_contract_address, token_contract_address, collateral_token_contract_address,
    );

    // Mint mock token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_1, ref mint_calldata);
    Serde::serialize(@TEST_SUPPLY_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(
        token_contract_address, selector!("mint"), mint_calldata.span(),
    )
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token_contract_address };
    start_cheat_caller_address(token_contract_address, TEST_USER_1);
    mock_token_dispatcher.approve(market_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(token_contract_address);

    // Cache data before
    let pool_contract_address = market_dispatcher
        .get_pools(token_contract_address, collateral_token_contract_address);
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    let lp_token_dispatcher = ILPTokenDispatcher {
        contract_address: pool_dispatcher.get_lp_token_address(),
    };
    let token_balance_before = mock_token_dispatcher.balance_of(TEST_USER_1);
    let token_allowance_before = mock_token_dispatcher
        .allowance(TEST_USER_1, market_contract_address);
    let lp_token_balance_before = lp_token_dispatcher.balance_of(TEST_USER_1);
    let lp_owned_before = pool_dispatcher.get_user_to_lp_owned(TEST_USER_1);
    let total_supply_before = pool_dispatcher.get_total_supply();

    //////////////
    // Interact //
    //////////////

    // Spy event
    let mut spy = spy_events();

    // Supply
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    market_dispatcher
        .supply(token_contract_address, collateral_token_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(market_contract_address);

    ////////////
    // Assert //
    ////////////
    let lp_owned = pool_dispatcher.get_user_to_lp_owned(TEST_USER_1);

    // Assert event emitted
    spy
        .assert_emitted(
            @array![
                (
                    market_contract_address,
                    Event::Supplied(
                        Supplied {
                            user: TEST_USER_1,
                            token: token_contract_address,
                            collateral_token: collateral_token_contract_address,
                            supply_amount: TEST_SUPPLY_AMOUNT_1,
                            lp_token_mint: lp_owned,
                        },
                    ),
                ),
            ],
        );

    // Assert token balance
    assert(
        token_balance_before
            - TEST_SUPPLY_AMOUNT_1 == mock_token_dispatcher.balance_of(TEST_USER_1),
        'Invalid token balance',
    );

    // Assert token allowance
    assert(
        token_allowance_before
            - TEST_SUPPLY_AMOUNT_1 == mock_token_dispatcher
                .allowance(TEST_USER_1, market_contract_address),
        'Invalid token allowance',
    );

    // Assert lp token balance
    assert(
        lp_token_balance_before
            + TEST_SUPPLY_AMOUNT_1 == lp_token_dispatcher.balance_of(TEST_USER_1),
        'Invalid lp token balance',
    );

    // Assert lp owned
    assert(lp_owned_before + TEST_SUPPLY_AMOUNT_1 == lp_owned, 'Invalid lp owned');

    // Assert total supply
    assert(
        total_supply_before + TEST_SUPPLY_AMOUNT_1 == pool_dispatcher.get_total_supply(),
        'Invalid total supply',
    );
}

#[test]
fn test_supply_normal_supply_case() {
    ///////////
    // Setup //
    ///////////

    // Deploy market
    let (
        market_contract_address,
        _,
        _,
        token_contract_address,
        collateral_token_contract_address,
        _,
        _,
    ) =
        deploy_contract();
    let market_dispatcher = IMarketDispatcher { contract_address: market_contract_address };

    // Deploy pool
    deploy_new_pool(
        market_contract_address, token_contract_address, collateral_token_contract_address,
    );

    // Mint mock token
    let mut user_1_mint_calldata: Array<felt252> = array![];
    let mut user_2_mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_1, ref user_1_mint_calldata);
    Serde::serialize(@TEST_SUPPLY_AMOUNT_1, ref user_1_mint_calldata);
    Serde::serialize(@TEST_USER_2, ref user_2_mint_calldata);
    Serde::serialize(@TEST_SUPPLY_AMOUNT_2, ref user_2_mint_calldata);
    let mut res_1 = call_contract_syscall(
        token_contract_address, selector!("mint"), user_1_mint_calldata.span(),
    )
        .unwrap_syscall();
    let mut res_2 = call_contract_syscall(
        token_contract_address, selector!("mint"), user_2_mint_calldata.span(),
    )
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res_1).unwrap(), 'Mock mint failed');
    assert(Serde::<bool>::deserialize(ref res_2).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token_contract_address };
    start_cheat_caller_address(token_contract_address, TEST_USER_1);
    mock_token_dispatcher.approve(market_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(token_contract_address);
    start_cheat_caller_address(token_contract_address, TEST_USER_2);
    mock_token_dispatcher.approve(market_contract_address, TEST_SUPPLY_AMOUNT_2);
    stop_cheat_caller_address(token_contract_address);

    // User 1 supply first
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    market_dispatcher
        .supply(token_contract_address, collateral_token_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(market_contract_address);

    // Cache data before
    let pool_contract_address = market_dispatcher
        .get_pools(token_contract_address, collateral_token_contract_address);
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    let lp_token_dispatcher = ILPTokenDispatcher {
        contract_address: pool_dispatcher.get_lp_token_address(),
    };
    let token_balance_before = mock_token_dispatcher.balance_of(TEST_USER_2);
    let token_allowance_before = mock_token_dispatcher
        .allowance(TEST_USER_2, market_contract_address);
    let lp_token_balance_before = lp_token_dispatcher.balance_of(TEST_USER_2);
    let lp_owned_before = pool_dispatcher.get_user_to_lp_owned(TEST_USER_2);
    let total_supply_before = pool_dispatcher.get_total_supply();
    let expected_lp_minted = TEST_SUPPLY_AMOUNT_2
        * lp_token_dispatcher.total_supply()
        / total_supply_before;

    //////////////
    // Interact //
    //////////////

    // Spy event
    let mut spy = spy_events();

    // Supply
    start_cheat_caller_address(market_contract_address, TEST_USER_2);
    market_dispatcher
        .supply(token_contract_address, collateral_token_contract_address, TEST_SUPPLY_AMOUNT_2);
    stop_cheat_caller_address(market_contract_address);

    ////////////
    // Assert //
    ////////////
    let lp_owned = pool_dispatcher.get_user_to_lp_owned(TEST_USER_2);

    // Assert lp minted
    assert(expected_lp_minted == lp_owned - lp_owned_before, 'Invalid lp minted');

    // Assert event emitted
    spy
        .assert_emitted(
            @array![
                (
                    market_contract_address,
                    Event::Supplied(
                        Supplied {
                            user: TEST_USER_2,
                            token: token_contract_address,
                            collateral_token: collateral_token_contract_address,
                            supply_amount: TEST_SUPPLY_AMOUNT_2,
                            lp_token_mint: expected_lp_minted,
                        },
                    ),
                ),
            ],
        );

    // Assert token balance
    assert(
        token_balance_before
            - TEST_SUPPLY_AMOUNT_2 == mock_token_dispatcher.balance_of(TEST_USER_2),
        'Invalid token balance',
    );

    // Assert token allowance
    assert(
        token_allowance_before
            - TEST_SUPPLY_AMOUNT_2 == mock_token_dispatcher
                .allowance(TEST_USER_2, market_contract_address),
        'Invalid token allowance',
    );

    // Assert lp token balance
    assert(
        lp_token_balance_before + expected_lp_minted == lp_token_dispatcher.balance_of(TEST_USER_2),
        'Invalid lp token balance',
    );

    // Assert total supply
    assert(
        total_supply_before + TEST_SUPPLY_AMOUNT_2 == pool_dispatcher.get_total_supply(),
        'Invalid total supply',
    );
}

#[test]
#[feature("safe_dispatcher")]
fn test_supply_revert_invalid_token_address() {
    // Setup
    let (market_contract_address, _, _, _, _, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher
        .supply(contract_address_const::<0>(), contract_address_const::<0>(), 0) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::INVALID_TOKEN_ADDRESS, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_supply_revert_invalid_collateral_token_address() {
    // Setup
    let (market_contract_address, _, _, token, _, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher.supply(token, contract_address_const::<0>(), 0) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::INVALID_COLLATERAL_ADDRESS, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_supply_revert_invalid_supply_amount() {
    // Setup
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher.supply(token, collateral_token, 0) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::INVALID_AMOUNT, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_supply_revert_pool_not_exist() {
    // Setup
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher.supply(token, collateral_token, TEST_SUPPLY_AMOUNT_1) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::POOL_NOT_EXIST, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_supply_revert_not_enough_balance_to_supply() {
    // Setup
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };
    deploy_new_pool(market_contract_address, token, collateral_token);

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher.supply(token, collateral_token, TEST_SUPPLY_AMOUNT_1) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_ENOUGH_BALANCE_TO_SUPPLY, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_supply_revert_not_enough_allowance_to_supply() {
    // Setup
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };
    deploy_new_pool(market_contract_address, token, collateral_token);
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_1, ref mint_calldata);
    Serde::serialize(@TEST_SUPPLY_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher.supply(token, collateral_token, TEST_SUPPLY_AMOUNT_1) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_ENOUGH_ALLOWANCE, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////// WITHDRAW ///////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////
#[test]
fn test_withdraw() {
    ///////////
    // Setup //
    ///////////

    // Deploy market
    let (
        market_contract_address,
        _,
        _,
        token_contract_address,
        collateral_token_contract_address,
        _,
        _,
    ) =
        deploy_contract();
    let market_dispatcher = IMarketDispatcher { contract_address: market_contract_address };

    // Deploy pool
    deploy_new_pool(
        market_contract_address, token_contract_address, collateral_token_contract_address,
    );

    // Mint mock token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_1, ref mint_calldata);
    Serde::serialize(@TEST_SUPPLY_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(
        token_contract_address, selector!("mint"), mint_calldata.span(),
    )
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token_contract_address };
    start_cheat_caller_address(token_contract_address, TEST_USER_1);
    mock_token_dispatcher.approve(market_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(token_contract_address);

    // Supply
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    market_dispatcher
        .supply(token_contract_address, collateral_token_contract_address, TEST_SUPPLY_AMOUNT_1);

    // Cache data before
    let pool_contract_address = market_dispatcher
        .get_pools(token_contract_address, collateral_token_contract_address);
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    let lp_token_dispatcher = ILPTokenDispatcher {
        contract_address: pool_dispatcher.get_lp_token_address(),
    };
    let expected_token_withdraw_amount = TEST_WITHDRAW_AMOUNT_1
        * pool_dispatcher.get_total_supply()
        / lp_token_dispatcher.total_supply();
    let token_balance_before = mock_token_dispatcher.balance_of(TEST_USER_1);
    let lp_token_balance_before = lp_token_dispatcher.balance_of(TEST_USER_1);
    let lp_owned_before = pool_dispatcher.get_user_to_lp_owned(TEST_USER_1);
    let total_supply_before = pool_dispatcher.get_total_supply();

    //////////////
    // Interact //
    //////////////

    // Spy event
    let mut spy = spy_events();

    // Withdraw
    market_dispatcher
        .withdraw(
            token_contract_address, collateral_token_contract_address, TEST_WITHDRAW_AMOUNT_1,
        );
    stop_cheat_caller_address(market_contract_address);

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
                            user: TEST_USER_1,
                            token: token_contract_address,
                            collateral_token: collateral_token_contract_address,
                            lp_amount_withdraw: TEST_WITHDRAW_AMOUNT_1,
                            token_withdraw_amount: expected_token_withdraw_amount,
                        },
                    ),
                ),
            ],
        );

    // Assert token balance
    assert(
        token_balance_before
            + expected_token_withdraw_amount == mock_token_dispatcher.balance_of(TEST_USER_1),
        'Invalid token balance',
    );

    // Assert lp token balance
    assert(
        lp_token_balance_before
            - TEST_WITHDRAW_AMOUNT_1 == lp_token_dispatcher.balance_of(TEST_USER_1),
        'Invalid lp token balance',
    );

    // Assert lp owned
    assert(
        lp_owned_before
            - TEST_WITHDRAW_AMOUNT_1 == pool_dispatcher.get_user_to_lp_owned(TEST_USER_1),
        'Invalid lp owned',
    );

    // Assert total supply
    assert(
        total_supply_before - expected_token_withdraw_amount == pool_dispatcher.get_total_supply(),
        'Invalid total supply',
    );
}

#[test]
fn test_withdraw_with_interest() {
    ///////////
    // Setup //
    ///////////

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
    Serde::serialize(@TEST_USER_1, ref mint_calldata);
    Serde::serialize(@TEST_SUPPLY_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(
        token_contract_address, selector!("mint"), mint_calldata.span(),
    )
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token_contract_address };
    start_cheat_caller_address(token_contract_address, TEST_USER_1);
    mock_token_dispatcher.approve(market_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(token_contract_address);

    // Supply
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    market_dispatcher
        .supply(token_contract_address, collateral_token_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(market_contract_address);

    // Mint mock collateral token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_2, ref mint_calldata);
    Serde::serialize(@TEST_COLLATERAL_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(
        collateral_token_contract_address, selector!("mint"), mint_calldata.span(),
    )
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock collateral token
    let mock_collateral_token_dispatcher = IERC20Dispatcher {
        contract_address: collateral_token_contract_address,
    };
    start_cheat_caller_address(collateral_token_contract_address, TEST_USER_2);
    mock_collateral_token_dispatcher.approve(market_contract_address, TEST_COLLATERAL_AMOUNT_1);
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
    start_cheat_caller_address(market_contract_address, TEST_USER_2);
    market_dispatcher
        .borrow(
            token_contract_address,
            TEST_BORROW_AMOUNT_1,
            collateral_token_contract_address,
            TEST_COLLATERAL_AMOUNT_1,
        );

    // Cache data before
    let pool_contract_address = market_dispatcher
        .get_pools(token_contract_address, collateral_token_contract_address);
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    let expected_borrow_id = pool_dispatcher.get_user_borrow_quantity(TEST_USER_2) - 1;
    let expected_user_borrow_info = pool_dispatcher
        .get_user_borrow_info(TEST_USER_2, expected_borrow_id);
    let expected_user_borrow_apr = expected_user_borrow_info.borrow_apr;
    let expected_user_borrow_start_time = expected_user_borrow_info.borrow_start_time;
    let repay_timestamp = borrow_timestamp + TEST_BORROW_TIME;
    let expected_interest_amount = TEST_BORROW_AMOUNT_1
        * expected_user_borrow_apr
        * (repay_timestamp - expected_user_borrow_start_time).into()
        / (YEAR_TIMESTAMPS.into() * ten_pow_decimals().into() * ten_pow_decimals().into());
    let expected_total_repay_amount = TEST_BORROW_AMOUNT_1 + expected_interest_amount;

    // Mint `expected_interest_amount` of mock token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_2, ref mint_calldata);
    Serde::serialize(@expected_interest_amount, ref mint_calldata);
    let mut res = call_contract_syscall(
        token_contract_address, selector!("mint"), mint_calldata.span(),
    )
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token_contract_address };
    start_cheat_caller_address(token_contract_address, TEST_USER_2);
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
    let expected_token_withdraw_amount = TEST_WITHDRAW_AMOUNT_1
        * pool_dispatcher.get_total_supply()
        / lp_token_dispatcher.total_supply();
    let expected_additional_token_claim = TEST_WITHDRAW_AMOUNT_1
        * expected_interest_amount
        / lp_token_dispatcher.total_supply();
    let initial_equivalent_token_amount = TEST_WITHDRAW_AMOUNT_1
        * TEST_SUPPLY_AMOUNT_1
        / lp_token_dispatcher.total_supply();
    let token_balance_before = mock_token_dispatcher.balance_of(TEST_USER_1);
    let lp_token_balance_before = lp_token_dispatcher.balance_of(TEST_USER_1);
    let lp_owned_before = pool_dispatcher.get_user_to_lp_owned(TEST_USER_1);
    let total_supply_before = pool_dispatcher.get_total_supply();

    //////////////
    // Interact //
    //////////////

    // Spy event
    let mut spy = spy_events();

    // Withdraw
    stop_cheat_caller_address(market_contract_address);
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    market_dispatcher
        .withdraw(
            token_contract_address, collateral_token_contract_address, TEST_WITHDRAW_AMOUNT_1,
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
                            user: TEST_USER_1,
                            token: token_contract_address,
                            collateral_token: collateral_token_contract_address,
                            lp_amount_withdraw: TEST_WITHDRAW_AMOUNT_1,
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
            + expected_token_withdraw_amount == mock_token_dispatcher.balance_of(TEST_USER_1),
        'Invalid token balance',
    );

    // Assert lp token balance
    assert(
        lp_token_balance_before
            - TEST_WITHDRAW_AMOUNT_1 == lp_token_dispatcher.balance_of(TEST_USER_1),
        'Invalid lp token balance',
    );

    // Assert lp owned
    assert(
        lp_owned_before
            - TEST_WITHDRAW_AMOUNT_1 == pool_dispatcher.get_user_to_lp_owned(TEST_USER_1),
        'Invalid lp owned',
    );

    // Assert total supply
    assert(
        total_supply_before - expected_token_withdraw_amount == pool_dispatcher.get_total_supply(),
        'Invalid total supply',
    );
}

#[test]
#[feature("safe_dispatcher")]
fn test_withdraw_revert_invalid_token_address() {
    // Setup
    let (market_contract_address, _, _, _, _, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher
        .withdraw(contract_address_const::<0>(), contract_address_const::<0>(), 0) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::INVALID_TOKEN_ADDRESS, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_withdraw_revert_invalid_collateral_token_address() {
    // Setup
    let (market_contract_address, _, _, token, _, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher.withdraw(token, contract_address_const::<0>(), 0) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::INVALID_COLLATERAL_ADDRESS, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_withdraw_revert_zero_lp_amount_withdraw() {
    // Setup
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher.withdraw(token, collateral_token, 0) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::INVALID_AMOUNT, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_withdraw_revert_pool_not_exist() {
    // Setup
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher.withdraw(token, collateral_token, TEST_WITHDRAW_AMOUNT_1) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::POOL_NOT_EXIST, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_withdraw_revert_exceed_lp_amount_available() {
    // Setup
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };
    deploy_new_pool(market_contract_address, token, collateral_token);
    let pool_address = match market_safe_dispatcher.get_pools(token, collateral_token) {
        Result::Ok(pool_address) => pool_address,
        Result::Err(_) => panic_with_felt252('Should not panicked'),
    };
    start_cheat_caller_address(pool_address, market_contract_address);
    IPoolDispatcher { contract_address: pool_address }
        .add_user_lp_owned(TEST_USER_1, TEST_WITHDRAW_AMOUNT_1);
    stop_cheat_caller_address(pool_address);

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher.withdraw(token, collateral_token, TEST_WITHDRAW_AMOUNT_1 + 1) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::INVALID_AMOUNT, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_withdraw_revert_not_enough_lp_token_amount() {
    // Setup
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };
    deploy_new_pool(market_contract_address, token, collateral_token);
    let pool_address = match market_safe_dispatcher.get_pools(token, collateral_token) {
        Result::Ok(pool_address) => pool_address,
        Result::Err(_) => panic_with_felt252('Should not panicked'),
    };
    start_cheat_caller_address(pool_address, market_contract_address);
    IPoolDispatcher { contract_address: pool_address }
        .add_user_lp_owned(TEST_USER_1, TEST_WITHDRAW_AMOUNT_1);
    stop_cheat_caller_address(pool_address);

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher.withdraw(token, collateral_token, TEST_WITHDRAW_AMOUNT_1) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_ENOUGH_LP_TOKEN_AMOUNT, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

////////////////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////// BORROW ////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////
#[test]
fn test_borrow_low_charge() {
    ///////////
    // Setup //
    ///////////

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
    Serde::serialize(@TEST_USER_1, ref mint_calldata);
    Serde::serialize(@TEST_SUPPLY_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(
        token_contract_address, selector!("mint"), mint_calldata.span(),
    )
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token_contract_address };
    start_cheat_caller_address(token_contract_address, TEST_USER_1);
    mock_token_dispatcher.approve(market_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(token_contract_address);

    // Supply
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    market_dispatcher
        .supply(token_contract_address, collateral_token_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(market_contract_address);

    // Mint mock collateral token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_2, ref mint_calldata);
    Serde::serialize(@TEST_COLLATERAL_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(
        collateral_token_contract_address, selector!("mint"), mint_calldata.span(),
    )
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock collateral token
    let mock_collateral_token_dispatcher = IERC20Dispatcher {
        contract_address: collateral_token_contract_address,
    };
    start_cheat_caller_address(collateral_token_contract_address, TEST_USER_2);
    mock_collateral_token_dispatcher.approve(market_contract_address, TEST_COLLATERAL_AMOUNT_1);
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

    // Cache data before
    let pool_contract_address = market_dispatcher
        .get_pools(token_contract_address, collateral_token_contract_address);
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    let expected_borrow_id = pool_dispatcher.get_user_borrow_quantity(TEST_USER_2);
    let expected_hf: u256 = MOCK_AGGREGATOR_COLLATERAL_TOKEN_PRICE_ANSWER.into()
        * TEST_COLLATERAL_AMOUNT_1
        * MOCK_AGGREGATOR_DECIMALS.into()
        * THRESHOLD_LIQUIDATION.into()
        / (MOCK_AGGREGATOR_TOKEN_PRICE_ANSWER.into()
            * TEST_BORROW_AMOUNT_1
            * MOCK_AGGREGATOR_DECIMALS.into());
    let expected_borrow_start_time = get_block_timestamp();
    let collateral_token_balance_before = mock_collateral_token_dispatcher.balance_of(TEST_USER_2);
    let user_borrow_quantity_before = pool_dispatcher.get_user_borrow_quantity(TEST_USER_2);
    let active_borrower_num_before = pool_dispatcher.get_active_borrower_num();
    let total_borrow_before = pool_dispatcher.get_total_borrow();
    let token_balance_before = mock_token_dispatcher.balance_of(TEST_USER_2);

    //////////////
    // Interact //
    //////////////

    // Spy event
    let mut spy = spy_events();

    // Borrow
    start_cheat_caller_address(market_contract_address, TEST_USER_2);
    market_dispatcher
        .borrow(
            token_contract_address,
            TEST_BORROW_AMOUNT_1,
            collateral_token_contract_address,
            TEST_COLLATERAL_AMOUNT_1,
        );
    stop_cheat_caller_address(market_contract_address);

    ////////////
    // Assert //
    ////////////
    let new_ur = pool_dispatcher.calculate_utilization_rate();
    let expected_borrow_apr = BASE_INTEREST_RATE.into() * ten_pow_decimals().into()
        + RSLOPE_1.into() * new_ur / ten_pow_decimals().into();
    let expected_interest_amount_per_year = TEST_BORROW_AMOUNT_1
        * expected_borrow_apr
        / (ten_pow_decimals().into() * ten_pow_decimals().into());

    // Assert event emitted
    spy
        .assert_emitted(
            @array![
                (
                    market_contract_address,
                    Event::Borrowed(
                        Borrowed {
                            user: TEST_USER_2,
                            borrow_token: token_contract_address,
                            collateral_token: collateral_token_contract_address,
                            borrow_amount: TEST_BORROW_AMOUNT_1,
                            collateral_amount: TEST_COLLATERAL_AMOUNT_1,
                            borrow_id: expected_borrow_id,
                        },
                    ),
                ),
            ],
        );

    // Assert collateral token balance
    assert(
        collateral_token_balance_before
            - TEST_COLLATERAL_AMOUNT_1 == mock_collateral_token_dispatcher.balance_of(TEST_USER_2),
        'Invalid token balance',
    );

    // Assert user borrow info
    let user_borrow_info = pool_dispatcher.get_user_borrow_info(TEST_USER_2, expected_borrow_id);
    assert(user_borrow_info.borrow_amount == TEST_BORROW_AMOUNT_1, 'Invalid borrow amount');
    assert(
        user_borrow_info.collateral_amount == TEST_COLLATERAL_AMOUNT_1, 'Invalid collateral amount',
    );
    assert(user_borrow_info.hf == expected_hf, 'Invalid health factor');
    assert(user_borrow_info.borrow_apr == expected_borrow_apr, 'Invalid borrow apr');
    assert(
        user_borrow_info.borrow_start_time == expected_borrow_start_time,
        'Invalid borrow start time',
    );

    // Assert user borrow quantity
    assert(
        user_borrow_quantity_before + 1 == pool_dispatcher.get_user_borrow_quantity(TEST_USER_2),
        'Invalid borrow quantity',
    );

    // Assert active borrower num
    assert(
        active_borrower_num_before + 1 == pool_dispatcher.get_active_borrower_num(),
        'Invalid active borrower num',
    );

    // Assert active borrower
    assert(
        pool_dispatcher.get_active_borrower(active_borrower_num_before) == TEST_USER_2,
        'Invalid active borrower',
    );

    // Assert active borrower index
    assert(
        pool_dispatcher.get_active_borrower_index(TEST_USER_2) == active_borrower_num_before,
        'Invalid active borrower index',
    );

    // Assert expected interest amount per year
    assert(
        pool_dispatcher
            .get_expected_interest_amount_per_year() == expected_interest_amount_per_year,
        'Invalid amount',
    );

    // Assert total borrow
    assert(
        total_borrow_before + TEST_BORROW_AMOUNT_1 == pool_dispatcher.get_total_borrow(),
        'Invalid total borrow',
    );

    // Assert token balance
    assert(
        token_balance_before
            + TEST_BORROW_AMOUNT_1 == mock_token_dispatcher.balance_of(TEST_USER_2),
        'Invalid token balance',
    );
}

#[test]
fn test_borrow_high_charge() {
    ///////////
    // Setup //
    ///////////

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
    Serde::serialize(@TEST_USER_1, ref mint_calldata);
    Serde::serialize(@TEST_SUPPLY_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(
        token_contract_address, selector!("mint"), mint_calldata.span(),
    )
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token_contract_address };
    start_cheat_caller_address(token_contract_address, TEST_USER_1);
    mock_token_dispatcher.approve(market_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(token_contract_address);

    // Supply
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    market_dispatcher
        .supply(token_contract_address, collateral_token_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(market_contract_address);

    // Mint mock collateral token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_2, ref mint_calldata);
    Serde::serialize(@(TEST_COLLATERAL_AMOUNT_1 + TEST_COLLATERAL_AMOUNT_2), ref mint_calldata);
    let mut res = call_contract_syscall(
        collateral_token_contract_address, selector!("mint"), mint_calldata.span(),
    )
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock collateral token
    let mock_collateral_token_dispatcher = IERC20Dispatcher {
        contract_address: collateral_token_contract_address,
    };
    start_cheat_caller_address(collateral_token_contract_address, TEST_USER_2);
    mock_collateral_token_dispatcher
        .approve(market_contract_address, TEST_COLLATERAL_AMOUNT_1 + TEST_COLLATERAL_AMOUNT_2);
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

    // Borrow low charge
    start_cheat_caller_address(market_contract_address, TEST_USER_2);
    market_dispatcher
        .borrow(
            token_contract_address,
            TEST_BORROW_AMOUNT_1,
            collateral_token_contract_address,
            TEST_COLLATERAL_AMOUNT_1,
        );

    // Cache data before
    let pool_contract_address = market_dispatcher
        .get_pools(token_contract_address, collateral_token_contract_address);
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    let expected_borrow_id = pool_dispatcher.get_user_borrow_quantity(TEST_USER_2);
    let expected_hf: u256 = MOCK_AGGREGATOR_COLLATERAL_TOKEN_PRICE_ANSWER.into()
        * TEST_COLLATERAL_AMOUNT_2
        * MOCK_AGGREGATOR_DECIMALS.into()
        * THRESHOLD_LIQUIDATION.into()
        / (MOCK_AGGREGATOR_TOKEN_PRICE_ANSWER.into()
            * TEST_BORROW_AMOUNT_2
            * MOCK_AGGREGATOR_DECIMALS.into());
    let expected_borrow_start_time = get_block_timestamp();
    let collateral_token_balance_before = mock_collateral_token_dispatcher.balance_of(TEST_USER_2);
    let user_borrow_quantity_before = pool_dispatcher.get_user_borrow_quantity(TEST_USER_2);
    let active_borrower_num_before = pool_dispatcher.get_active_borrower_num();
    let expected_interest_amount_per_year_before = pool_dispatcher
        .get_expected_interest_amount_per_year();
    let total_borrow_before = pool_dispatcher.get_total_borrow();
    let token_balance_before = mock_token_dispatcher.balance_of(TEST_USER_2);

    //////////////
    // Interact //
    //////////////

    // Spy event
    let mut spy = spy_events();

    // Borrow
    market_dispatcher
        .borrow(
            token_contract_address,
            TEST_BORROW_AMOUNT_2,
            collateral_token_contract_address,
            TEST_COLLATERAL_AMOUNT_2,
        );
    stop_cheat_caller_address(market_contract_address);

    ////////////
    // Assert //
    ////////////
    let new_ur = pool_dispatcher.calculate_utilization_rate();
    let expected_borrow_apr = BASE_INTEREST_RATE.into() * ten_pow_decimals().into()
        + RSLOPE_1.into() * OPTIMAL_UTILIZATION_RATE.into()
        + RSLOPE_2.into()
            * ((new_ur - (OPTIMAL_UTILIZATION_RATE.into() * ten_pow_decimals().into()))
                / ten_pow_decimals().into());
    let expected_interest_amount_per_year = TEST_BORROW_AMOUNT_2
        * expected_borrow_apr
        / (ten_pow_decimals().into() * ten_pow_decimals().into());

    // Assert event emitted
    spy
        .assert_emitted(
            @array![
                (
                    market_contract_address,
                    Event::Borrowed(
                        Borrowed {
                            user: TEST_USER_2,
                            borrow_token: token_contract_address,
                            collateral_token: collateral_token_contract_address,
                            borrow_amount: TEST_BORROW_AMOUNT_2,
                            collateral_amount: TEST_COLLATERAL_AMOUNT_2,
                            borrow_id: expected_borrow_id,
                        },
                    ),
                ),
            ],
        );

    // Assert collateral token balance
    assert(
        collateral_token_balance_before
            - TEST_COLLATERAL_AMOUNT_2 == mock_collateral_token_dispatcher.balance_of(TEST_USER_2),
        'Invalid token balance',
    );

    // Assert user borrow info
    let user_borrow_info = pool_dispatcher.get_user_borrow_info(TEST_USER_2, expected_borrow_id);
    assert(user_borrow_info.borrow_amount == TEST_BORROW_AMOUNT_2, 'Invalid borrow amount');
    assert(
        user_borrow_info.collateral_amount == TEST_COLLATERAL_AMOUNT_2, 'Invalid collateral amount',
    );
    assert(user_borrow_info.hf == expected_hf, 'Invalid health factor');
    assert(user_borrow_info.borrow_apr == expected_borrow_apr, 'Invalid borrow apr');
    assert(
        user_borrow_info.borrow_start_time == expected_borrow_start_time,
        'Invalid borrow start time',
    );

    // Assert user borrow quantity
    assert(
        user_borrow_quantity_before + 1 == pool_dispatcher.get_user_borrow_quantity(TEST_USER_2),
        'Invalid borrow quantity',
    );

    // Assert active borrower num
    assert(
        active_borrower_num_before == pool_dispatcher.get_active_borrower_num(),
        'Invalid active borrower num',
    );

    // Assert expected interest amount per year
    assert(
        pool_dispatcher.get_expected_interest_amount_per_year()
            - expected_interest_amount_per_year_before == expected_interest_amount_per_year,
        'Invalid amount',
    );

    // Assert total borrow
    assert(
        total_borrow_before + TEST_BORROW_AMOUNT_2 == pool_dispatcher.get_total_borrow(),
        'Invalid total borrow',
    );

    // Assert token balance
    assert(
        token_balance_before
            + TEST_BORROW_AMOUNT_2 == mock_token_dispatcher.balance_of(TEST_USER_2),
        'Invalid token balance',
    );
}

#[test]
#[feature("safe_dispatcher")]
fn test_borrow_revert_invalid_token_address() {
    // Setup
    let (market_contract_address, _, _, _, _, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher
        .borrow(contract_address_const::<0>(), 0, contract_address_const::<0>(), 0) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::INVALID_TOKEN_ADDRESS, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_borrow_revert_invalid_collateral_token_address() {
    // Setup
    let (market_contract_address, _, _, token, _, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher.borrow(token, 0, contract_address_const::<0>(), 0) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::INVALID_COLLATERAL_ADDRESS, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_borrow_revert_invalid_amount() {
    // Setup
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher.borrow(token, 0, collateral_token, 0) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::INVALID_AMOUNT, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_borrow_revert_pool_not_exist() {
    // Setup
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher
        .borrow(token, TEST_BORROW_AMOUNT_1, collateral_token, TEST_COLLATERAL_AMOUNT_1) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::POOL_NOT_EXIST, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_borrow_revert_not_enough_collateral_balance() {
    ///////////
    // Setup //
    ///////////
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Deploy pool
    deploy_new_pool(market_contract_address, token, collateral_token);

    //////////////
    // Interact //
    //////////////
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher
        .borrow(token, TEST_BORROW_AMOUNT_1, collateral_token, TEST_COLLATERAL_AMOUNT_1) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_ENOUGH_COLLATERAL_BALANCE, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_borrow_revert_not_enough_allowance() {
    ///////////
    // Setup //
    ///////////
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Deploy pool
    deploy_new_pool(market_contract_address, token, collateral_token);

    // Mint mock collateral token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_1, ref mint_calldata);
    Serde::serialize(@TEST_COLLATERAL_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(collateral_token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    //////////////
    // Interact //
    //////////////
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher
        .borrow(token, TEST_BORROW_AMOUNT_1, collateral_token, TEST_COLLATERAL_AMOUNT_1) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_ENOUGH_ALLOWANCE, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_borrow_revert_not_enough_supply() {
    ///////////
    // Setup //
    ///////////
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Deploy pool
    deploy_new_pool(market_contract_address, token, collateral_token);

    // Mint mock collateral token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_1, ref mint_calldata);
    Serde::serialize(@TEST_COLLATERAL_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(collateral_token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock collateral token
    let mock_collateral_token_dispatcher = IERC20Dispatcher { contract_address: collateral_token };
    start_cheat_caller_address(collateral_token, TEST_USER_1);
    mock_collateral_token_dispatcher.approve(market_contract_address, TEST_COLLATERAL_AMOUNT_1);
    stop_cheat_caller_address(collateral_token);

    //////////////
    // Interact //
    //////////////
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher
        .borrow(token, TEST_BORROW_AMOUNT_1, collateral_token, TEST_COLLATERAL_AMOUNT_1) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_ENOUGH_SUPPLY, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_borrow_revert_exceeds_borrow_limit() {
    ///////////
    // Setup //
    ///////////
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Deploy pool
    deploy_new_pool(market_contract_address, token, collateral_token);

    // Mint mock token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_1, ref mint_calldata);
    Serde::serialize(@TEST_SUPPLY_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, TEST_USER_1);
    mock_token_dispatcher.approve(market_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(token);

    // Supply
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    market_safe_dispatcher.supply(token, collateral_token, TEST_SUPPLY_AMOUNT_1).unwrap();
    stop_cheat_caller_address(market_contract_address);

    // Increase total borrow
    let pool_address = match market_safe_dispatcher.get_pools(token, collateral_token) {
        Result::Ok(pool_address) => pool_address,
        Result::Err(_) => panic_with_felt252('Should not panicked'),
    };
    let total_borrow = TEST_SUPPLY_AMOUNT_1 * BORROW_LIMIT.into() / ten_pow_decimals().into();
    let borrow_amount = TEST_SUPPLY_AMOUNT_1 - total_borrow;
    start_cheat_caller_address(pool_address, market_contract_address);
    IPoolDispatcher { contract_address: pool_address }.add_total_borrow(total_borrow);
    stop_cheat_caller_address(pool_address);

    // Mint mock collateral token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_2, ref mint_calldata);
    Serde::serialize(@TEST_COLLATERAL_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(collateral_token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock collateral token
    let mock_collateral_token_dispatcher = IERC20Dispatcher { contract_address: collateral_token };
    start_cheat_caller_address(collateral_token, TEST_USER_2);
    mock_collateral_token_dispatcher.approve(market_contract_address, TEST_COLLATERAL_AMOUNT_1);
    stop_cheat_caller_address(collateral_token);

    //////////////
    // Interact //
    //////////////
    start_cheat_caller_address(market_contract_address, TEST_USER_2);
    match market_safe_dispatcher
        .borrow(token, borrow_amount, collateral_token, TEST_COLLATERAL_AMOUNT_1) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::EXCEEDS_BORROW_LIMIT, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_borrow_revert_unsecured_loan() {
    ///////////
    // Setup //
    ///////////
    let (
        market_contract_address,
        _,
        _,
        token,
        collateral_token,
        mock_token_aggregator,
        mock_collateral_token_aggregator,
    ) =
        deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Deploy pool
    deploy_new_pool(market_contract_address, token, collateral_token);

    // Mint mock token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_1, ref mint_calldata);
    Serde::serialize(@TEST_SUPPLY_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, TEST_USER_1);
    mock_token_dispatcher.approve(market_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(token);

    // Supply
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    market_safe_dispatcher.supply(token, collateral_token, TEST_SUPPLY_AMOUNT_1).unwrap();
    stop_cheat_caller_address(market_contract_address);

    // Mint mock collateral token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_2, ref mint_calldata);
    Serde::serialize(@TEST_COLLATERAL_AMOUNT_2, ref mint_calldata);
    let mut res = call_contract_syscall(collateral_token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock collateral token
    let mock_collateral_token_dispatcher = IERC20Dispatcher { contract_address: collateral_token };
    start_cheat_caller_address(collateral_token, TEST_USER_2);
    mock_collateral_token_dispatcher.approve(market_contract_address, TEST_COLLATERAL_AMOUNT_2);
    stop_cheat_caller_address(collateral_token);

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

    //////////////
    // Interact //
    //////////////
    start_cheat_caller_address(market_contract_address, TEST_USER_2);

    // Expected HF
    // expected_hf = MOCK_AGGREGATOR_COLLATERAL_TOKEN_PRICE_ANSWER
    //             * TEST_COLLATERAL_AMOUNT_2
    //             * MOCK_AGGREGATOR_DECIMALS
    //             * THRESHOLD_LIQUIDATION
    //             / MOCK_AGGREGATOR_TOKEN_PRICE_ANSWER
    //             / TEST_BORROW_AMOUNT_1
    //             / MOCK_AGGREGATOR_DECIMALS
    //             = 400_000_000_000
    //             * 400_000e18
    //             * 8
    //             * 80
    //             / 300_000_000_000
    //             / 500_000e18
    //             / 8
    //             = ~85 < MIN_HF_WITH_DECIMALS = 120
    match market_safe_dispatcher
        .borrow(token, TEST_BORROW_AMOUNT_1, collateral_token, TEST_COLLATERAL_AMOUNT_2) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::UNSECURED_LOAN, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_borrow_revert_exceeds_borrow_limit_after_loan() {
    ///////////
    // Setup //
    ///////////
    let (
        market_contract_address,
        _,
        _,
        token,
        collateral_token,
        mock_token_aggregator,
        mock_collateral_token_aggregator,
    ) =
        deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Deploy pool
    deploy_new_pool(market_contract_address, token, collateral_token);

    // Mint mock token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_1, ref mint_calldata);
    Serde::serialize(@TEST_SUPPLY_AMOUNT_2, ref mint_calldata);
    let mut res = call_contract_syscall(token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, TEST_USER_1);
    mock_token_dispatcher.approve(market_contract_address, TEST_SUPPLY_AMOUNT_2);
    stop_cheat_caller_address(token);

    // Supply
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    market_safe_dispatcher.supply(token, collateral_token, TEST_SUPPLY_AMOUNT_2).unwrap();
    stop_cheat_caller_address(market_contract_address);

    // Mint mock collateral token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_2, ref mint_calldata);
    Serde::serialize(@TEST_COLLATERAL_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(collateral_token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock collateral token
    let mock_collateral_token_dispatcher = IERC20Dispatcher { contract_address: collateral_token };
    start_cheat_caller_address(collateral_token, TEST_USER_2);
    mock_collateral_token_dispatcher.approve(market_contract_address, TEST_COLLATERAL_AMOUNT_1);
    stop_cheat_caller_address(collateral_token);

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

    //////////////
    // Interact //
    //////////////
    start_cheat_caller_address(market_contract_address, TEST_USER_2);
    match market_safe_dispatcher
        .borrow(token, TEST_BORROW_AMOUNT_1, collateral_token, TEST_COLLATERAL_AMOUNT_1) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::EXCEEDS_BORROW_LIMIT, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

////////////////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////// REPAY ////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////
#[test]
fn test_repay() {
    ///////////
    // Setup //
    ///////////

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
    Serde::serialize(@TEST_USER_1, ref mint_calldata);
    Serde::serialize(@TEST_SUPPLY_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(
        token_contract_address, selector!("mint"), mint_calldata.span(),
    )
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token_contract_address };
    start_cheat_caller_address(token_contract_address, TEST_USER_1);
    mock_token_dispatcher.approve(market_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(token_contract_address);

    // Supply
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    market_dispatcher
        .supply(token_contract_address, collateral_token_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(market_contract_address);

    // Mint mock collateral token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_2, ref mint_calldata);
    Serde::serialize(@TEST_COLLATERAL_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(
        collateral_token_contract_address, selector!("mint"), mint_calldata.span(),
    )
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock collateral token
    let mock_collateral_token_dispatcher = IERC20Dispatcher {
        contract_address: collateral_token_contract_address,
    };
    start_cheat_caller_address(collateral_token_contract_address, TEST_USER_2);
    mock_collateral_token_dispatcher.approve(market_contract_address, TEST_COLLATERAL_AMOUNT_1);
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
    start_cheat_caller_address(market_contract_address, TEST_USER_2);
    market_dispatcher
        .borrow(
            token_contract_address,
            TEST_BORROW_AMOUNT_1,
            collateral_token_contract_address,
            TEST_COLLATERAL_AMOUNT_1,
        );

    // Cache data before
    let pool_contract_address = market_dispatcher
        .get_pools(token_contract_address, collateral_token_contract_address);
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    let expected_borrow_id = pool_dispatcher.get_user_borrow_quantity(TEST_USER_2) - 1;
    let expected_user_borrow_info = pool_dispatcher
        .get_user_borrow_info(TEST_USER_2, expected_borrow_id);
    let expected_user_borrow_apr = expected_user_borrow_info.borrow_apr;
    let expected_user_borrow_start_time = expected_user_borrow_info.borrow_start_time;
    let repay_timestamp = borrow_timestamp + TEST_BORROW_TIME;
    let expected_interest_amount = TEST_BORROW_AMOUNT_1
        * expected_user_borrow_apr
        * (repay_timestamp - expected_user_borrow_start_time).into()
        / (YEAR_TIMESTAMPS.into() * ten_pow_decimals().into() * ten_pow_decimals().into());
    let expected_total_repay_amount = TEST_BORROW_AMOUNT_1 + expected_interest_amount;

    // Mint `expected_interest_amount` of mock token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_2, ref mint_calldata);
    Serde::serialize(@expected_interest_amount, ref mint_calldata);
    let mut res = call_contract_syscall(
        token_contract_address, selector!("mint"), mint_calldata.span(),
    )
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token_contract_address };
    start_cheat_caller_address(token_contract_address, TEST_USER_2);
    mock_token_dispatcher.approve(market_contract_address, expected_total_repay_amount);
    stop_cheat_caller_address(token_contract_address);

    // Cache data before
    let token_balance_before = mock_token_dispatcher.balance_of(TEST_USER_2);
    let token_allowance_before = mock_token_dispatcher
        .allowance(TEST_USER_2, market_contract_address);
    let total_supply_before = pool_dispatcher.get_total_supply();
    let actual_interest_amount_before = pool_dispatcher.get_actual_interest_amount();
    let total_borrow_before = pool_dispatcher.get_total_borrow();
    let user_borrow_quantity_before = pool_dispatcher.get_user_borrow_quantity(TEST_USER_2);
    let active_borrower_num_before = pool_dispatcher.get_active_borrower_num();
    let collateral_token_balance_before = mock_collateral_token_dispatcher.balance_of(TEST_USER_2);

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
                            user: TEST_USER_2,
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
            - expected_total_repay_amount == mock_token_dispatcher.balance_of(TEST_USER_2),
        'Invalid token balance',
    );

    // Assert token allowance
    assert(
        token_allowance_before
            - expected_total_repay_amount == mock_token_dispatcher
                .allowance(TEST_USER_2, market_contract_address),
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
        total_borrow_before - TEST_BORROW_AMOUNT_1 == pool_dispatcher.get_total_borrow(),
        'Invalid total borrow',
    );

    // Assert user borrow quantity
    assert(
        user_borrow_quantity_before - 1 == pool_dispatcher.get_user_borrow_quantity(TEST_USER_2),
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
                .balance_of(TEST_USER_2),
        'Invalid token balance',
    );
}

#[test]
#[feature("safe_dispatcher")]
fn test_repay_revert_invalid_token_address() {
    // Setup
    let (market_contract_address, _, _, _, _, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher
        .repay(contract_address_const::<0>(), contract_address_const::<0>(), 0) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::INVALID_TOKEN_ADDRESS, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_repay_revert_invalid_collateral_token_address() {
    // Setup
    let (market_contract_address, _, _, token, _, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher.repay(token, contract_address_const::<0>(), 0) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::INVALID_COLLATERAL_ADDRESS, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_repay_revert_pool_not_exist() {
    // Setup
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher.repay(token, collateral_token, 0) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::POOL_NOT_EXIST, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_repay_revert_havent_borrow_yet() {
    ///////////
    // Setup //
    ///////////
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Deploy pool
    deploy_new_pool(market_contract_address, token, collateral_token);

    //////////////
    // Interact //
    //////////////
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher.repay(token, collateral_token, 0) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::HAVENT_BORROW_YET, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_repay_revert_invalid_borrow_id() {
    ///////////
    // Setup //
    ///////////
    let (
        market_contract_address,
        _,
        _,
        token,
        collateral_token,
        mock_token_aggregator,
        mock_collateral_token_aggregator,
    ) =
        deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Deploy pool
    deploy_new_pool(market_contract_address, token, collateral_token);

    // Mint mock token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_1, ref mint_calldata);
    Serde::serialize(@TEST_SUPPLY_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, TEST_USER_1);
    mock_token_dispatcher.approve(market_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(token);

    // Supply
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    market_safe_dispatcher.supply(token, collateral_token, TEST_SUPPLY_AMOUNT_1).unwrap();
    stop_cheat_caller_address(market_contract_address);

    // Mint mock collateral token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_2, ref mint_calldata);
    Serde::serialize(@TEST_COLLATERAL_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(collateral_token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock collateral token
    let mock_collateral_token_dispatcher = IERC20Dispatcher { contract_address: collateral_token };
    start_cheat_caller_address(collateral_token, TEST_USER_2);
    mock_collateral_token_dispatcher.approve(market_contract_address, TEST_COLLATERAL_AMOUNT_1);
    stop_cheat_caller_address(collateral_token);

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
    start_cheat_caller_address(market_contract_address, TEST_USER_2);
    market_safe_dispatcher
        .borrow(token, TEST_BORROW_AMOUNT_1, collateral_token, TEST_COLLATERAL_AMOUNT_1)
        .unwrap();

    // Cache data before
    let pool_address = match market_safe_dispatcher.get_pools(token, collateral_token) {
        Result::Ok(pool_address) => pool_address,
        Result::Err(_) => panic_with_felt252('Should not panicked'),
    };
    let expected_borrow_id = IPoolDispatcher { contract_address: pool_address }
        .get_user_borrow_quantity(TEST_USER_2)
        - 1;

    //////////////
    // Interact //
    //////////////
    start_cheat_caller_address(market_contract_address, TEST_USER_2);
    match market_safe_dispatcher.repay(token, collateral_token, expected_borrow_id + 1) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::INVALID_BORROW_ID, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_repay_revert_not_enough_balance_to_repay() {
    ///////////
    // Setup //
    ///////////
    let (
        market_contract_address,
        _,
        _,
        token,
        collateral_token,
        mock_token_aggregator,
        mock_collateral_token_aggregator,
    ) =
        deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Deploy pool
    deploy_new_pool(market_contract_address, token, collateral_token);

    // Mint mock token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_1, ref mint_calldata);
    Serde::serialize(@TEST_SUPPLY_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, TEST_USER_1);
    mock_token_dispatcher.approve(market_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(token);

    // Supply
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    market_safe_dispatcher.supply(token, collateral_token, TEST_SUPPLY_AMOUNT_1).unwrap();
    stop_cheat_caller_address(market_contract_address);

    // Mint mock collateral token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_2, ref mint_calldata);
    Serde::serialize(@TEST_COLLATERAL_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(collateral_token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock collateral token
    let mock_collateral_token_dispatcher = IERC20Dispatcher { contract_address: collateral_token };
    start_cheat_caller_address(collateral_token, TEST_USER_2);
    mock_collateral_token_dispatcher.approve(market_contract_address, TEST_COLLATERAL_AMOUNT_1);
    stop_cheat_caller_address(collateral_token);

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
    start_cheat_caller_address(market_contract_address, TEST_USER_2);
    market_safe_dispatcher
        .borrow(token, TEST_BORROW_AMOUNT_1, collateral_token, TEST_COLLATERAL_AMOUNT_1)
        .unwrap();

    // Cache data before
    let pool_address = match market_safe_dispatcher.get_pools(token, collateral_token) {
        Result::Ok(pool_address) => pool_address,
        Result::Err(_) => panic_with_felt252('Should not panicked'),
    };
    let expected_borrow_id = IPoolDispatcher { contract_address: pool_address }
        .get_user_borrow_quantity(TEST_USER_2)
        - 1;
    let repay_timestamp = borrow_timestamp + TEST_BORROW_TIME;

    //////////////
    // Interact //
    //////////////
    start_cheat_caller_address(market_contract_address, TEST_USER_2);
    start_cheat_block_timestamp_global(repay_timestamp);
    match market_safe_dispatcher.repay(token, collateral_token, expected_borrow_id) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_ENOUGH_BALANCE_TO_REPAY, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
    stop_cheat_block_timestamp_global();
}

#[test]
#[feature("safe_dispatcher")]
fn test_repay_revert_not_enough_allowance() {
    ///////////
    // Setup //
    ///////////
    let (
        market_contract_address,
        _,
        _,
        token,
        collateral_token,
        mock_token_aggregator,
        mock_collateral_token_aggregator,
    ) =
        deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Deploy pool
    deploy_new_pool(market_contract_address, token, collateral_token);

    // Mint mock token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_1, ref mint_calldata);
    Serde::serialize(@TEST_SUPPLY_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, TEST_USER_1);
    mock_token_dispatcher.approve(market_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(token);

    // Supply
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    market_safe_dispatcher.supply(token, collateral_token, TEST_SUPPLY_AMOUNT_1).unwrap();
    stop_cheat_caller_address(market_contract_address);

    // Mint mock collateral token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_2, ref mint_calldata);
    Serde::serialize(@TEST_COLLATERAL_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(collateral_token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock collateral token
    let mock_collateral_token_dispatcher = IERC20Dispatcher { contract_address: collateral_token };
    start_cheat_caller_address(collateral_token, TEST_USER_2);
    mock_collateral_token_dispatcher.approve(market_contract_address, TEST_COLLATERAL_AMOUNT_1);
    stop_cheat_caller_address(collateral_token);

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
    start_cheat_caller_address(market_contract_address, TEST_USER_2);
    market_safe_dispatcher
        .borrow(token, TEST_BORROW_AMOUNT_1, collateral_token, TEST_COLLATERAL_AMOUNT_1)
        .unwrap();

    // Cache data before
    let pool_address = match market_safe_dispatcher.get_pools(token, collateral_token) {
        Result::Ok(pool_address) => pool_address,
        Result::Err(_) => panic_with_felt252('Should not panicked'),
    };
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_address };
    let expected_borrow_id = pool_dispatcher.get_user_borrow_quantity(TEST_USER_2) - 1;
    let expected_user_borrow_info = pool_dispatcher
        .get_user_borrow_info(TEST_USER_2, expected_borrow_id);
    let expected_user_borrow_apr = expected_user_borrow_info.borrow_apr;
    let expected_user_borrow_start_time = expected_user_borrow_info.borrow_start_time;
    let repay_timestamp = borrow_timestamp + TEST_BORROW_TIME;
    let expected_interest_amount = TEST_BORROW_AMOUNT_1
        * expected_user_borrow_apr
        * (repay_timestamp - expected_user_borrow_start_time).into()
        / (YEAR_TIMESTAMPS.into() * ten_pow_decimals().into() * ten_pow_decimals().into());

    // Mint `expected_interest_amount` of mock token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_2, ref mint_calldata);
    Serde::serialize(@expected_interest_amount, ref mint_calldata);
    let mut res = call_contract_syscall(token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    //////////////
    // Interact //
    //////////////
    start_cheat_caller_address(market_contract_address, TEST_USER_2);
    start_cheat_block_timestamp_global(repay_timestamp);
    match market_safe_dispatcher.repay(token, collateral_token, expected_borrow_id) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_ENOUGH_ALLOWANCE, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
    stop_cheat_block_timestamp_global();
}

////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////// LIQUIDATE //////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////
#[test]
fn test_liquidate() {
    ///////////
    // Setup //
    ///////////

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
    Serde::serialize(@TEST_USER_1, ref mint_calldata);
    Serde::serialize(@TEST_SUPPLY_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(
        token_contract_address, selector!("mint"), mint_calldata.span(),
    )
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token_contract_address };
    start_cheat_caller_address(token_contract_address, TEST_USER_1);
    mock_token_dispatcher.approve(market_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(token_contract_address);

    // Supply
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    market_dispatcher
        .supply(token_contract_address, collateral_token_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(market_contract_address);

    // Mint mock collateral token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_2, ref mint_calldata);
    Serde::serialize(@TEST_COLLATERAL_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(
        collateral_token_contract_address, selector!("mint"), mint_calldata.span(),
    )
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock collateral token
    let mock_collateral_token_dispatcher = IERC20Dispatcher {
        contract_address: collateral_token_contract_address,
    };
    start_cheat_caller_address(collateral_token_contract_address, TEST_USER_2);
    mock_collateral_token_dispatcher.approve(market_contract_address, TEST_COLLATERAL_AMOUNT_1);
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
    start_cheat_caller_address(market_contract_address, TEST_USER_2);
    market_dispatcher
        .borrow(
            token_contract_address,
            TEST_BORROW_AMOUNT_1,
            collateral_token_contract_address,
            TEST_COLLATERAL_AMOUNT_1,
        );

    // Re setup price feed
    mock_collateral_token_aggregator_dispatcher
        .set_latest_round_data(
            MOCK_AGGREGATOR_COLLATERAL_TOKEN_LIQUIDATION_PRICE_ANSWER,
            MOCK_AGGREGATOR_BLOCK_NUM,
            MOCK_AGGREGATOR_OBSERVATION_TIMESTAMP,
            MOCK_AGGREGATOR_TRANSMISSION_TIMESTAMP,
        );

    // Cache data before
    let pool_contract_address = market_dispatcher
        .get_pools(token_contract_address, collateral_token_contract_address);
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    let expected_borrow_id = pool_dispatcher.get_user_borrow_quantity(TEST_USER_2) - 1;
    let expected_user_borrow_info = pool_dispatcher
        .get_user_borrow_info(TEST_USER_2, expected_borrow_id);
    let expected_user_borrow_apr = expected_user_borrow_info.borrow_apr;
    let expected_user_borrow_start_time = expected_user_borrow_info.borrow_start_time;
    let liquidation_timestamp = borrow_timestamp + YEAR_TIMESTAMPS.into();
    let expected_interest_amount = TEST_BORROW_AMOUNT_1
        * expected_user_borrow_apr
        * (liquidation_timestamp - expected_user_borrow_start_time).into()
        / (YEAR_TIMESTAMPS.into() * ten_pow_decimals().into() * ten_pow_decimals().into());
    let expected_total_repay_amount = TEST_BORROW_AMOUNT_1 + expected_interest_amount;

    // Mint `expected_total_repay_amount` of mock token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_1, ref mint_calldata);
    Serde::serialize(@expected_total_repay_amount, ref mint_calldata);
    let mut res = call_contract_syscall(
        token_contract_address, selector!("mint"), mint_calldata.span(),
    )
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token_contract_address };
    start_cheat_caller_address(token_contract_address, TEST_USER_1);
    mock_token_dispatcher.approve(market_contract_address, expected_total_repay_amount);
    stop_cheat_caller_address(token_contract_address);

    // Cache data before
    let token_balance_before = mock_token_dispatcher.balance_of(TEST_USER_1);
    let token_allowance_before = mock_token_dispatcher
        .allowance(TEST_USER_1, market_contract_address);
    let total_supply_before = pool_dispatcher.get_total_supply();
    let actual_interest_amount_before = pool_dispatcher.get_actual_interest_amount();
    let total_borrow_before = pool_dispatcher.get_total_borrow();
    let user_borrow_quantity_before = pool_dispatcher.get_user_borrow_quantity(TEST_USER_2);
    let active_borrower_num_before = pool_dispatcher.get_active_borrower_num();
    let collateral_token_balance_before = mock_collateral_token_dispatcher.balance_of(TEST_USER_1);

    // Expected borrow APR = base APR + low charge APR
    //                     = 3% + (RSLOPE_1 * ur)
    //                     = 3% + (25% * (TEST_BORROW_AMOUNT_1 / TEST_SUPPLY_AMOUNT_1))
    //                     = 3% + (25% * 0.5)
    //                     = 15.5%
    // Expected 1 year interest amount = 500_000e18 * 15.5% = 77_500e18
    // Expected HF = MOCK_AGGREGATOR_COLLATERAL_TOKEN_LIQUIDATION_PRICE_ANSWER
    //             * TEST_COLLATERAL_AMOUNT_1
    //             * MOCK_AGGREGATOR_DECIMALS
    //             * THRESHOLD_LIQUIDATION
    //             / MOCK_AGGREGATOR_TOKEN_PRICE_ANSWER
    //             / TEST_BORROW_AMOUNT_1 + expected interest amount
    //             / MOCK_AGGREGATOR_DECIMALS
    //             = 200_000_000_000
    //             * 1_000_000e18
    //             * 8
    //             * 80
    //             / 300_000_000_000
    //             / (500_000e18 + 77_500e18)
    //             / 8
    //             = (2/3) * (1_000_000/577_500) * 80
    //             = ~92 < UPPER_LIQUIDATE_HF_WITH_DECIMALS = 100

    //////////////
    // Interact //
    //////////////

    // Spy event
    let mut spy = spy_events();

    // Liquidate
    stop_cheat_caller_address(market_contract_address);
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    start_cheat_block_timestamp_global(liquidation_timestamp);
    market_dispatcher
        .liquidate(
            token_contract_address,
            collateral_token_contract_address,
            TEST_USER_2,
            expected_borrow_id,
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
                    Event::Liquidated(
                        Liquidated {
                            borrower: TEST_USER_2,
                            repay_token: token_contract_address,
                            collateral_token: collateral_token_contract_address,
                            borrow_id: expected_borrow_id,
                            caller: TEST_USER_1,
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
            - expected_total_repay_amount == mock_token_dispatcher.balance_of(TEST_USER_1),
        'Invalid token balance',
    );

    // Assert token allowance
    assert(
        token_allowance_before
            - expected_total_repay_amount == mock_token_dispatcher
                .allowance(TEST_USER_1, market_contract_address),
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
        total_borrow_before - TEST_BORROW_AMOUNT_1 == pool_dispatcher.get_total_borrow(),
        'Invalid total borrow',
    );

    // Assert user borrow quantity
    assert(
        user_borrow_quantity_before - 1 == pool_dispatcher.get_user_borrow_quantity(TEST_USER_2),
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
                .balance_of(TEST_USER_1),
        'Invalid token balance',
    );
}

#[test]
#[feature("safe_dispatcher")]
fn test_liquidate_revert_invalid_token_address() {
    // Setup
    let (market_contract_address, _, _, _, _, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher
        .liquidate(
            contract_address_const::<0>(),
            contract_address_const::<0>(),
            contract_address_const::<0>(),
            0,
        ) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::INVALID_TOKEN_ADDRESS, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_liquidate_revert_invalid_collateral_token_address() {
    // Setup
    let (market_contract_address, _, _, token, _, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher
        .liquidate(token, contract_address_const::<0>(), contract_address_const::<0>(), 0) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::INVALID_COLLATERAL_ADDRESS, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_liquidate_revert_invalid_borrower_address() {
    // Setup
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher
        .liquidate(token, collateral_token, contract_address_const::<0>(), 0) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::INVALID_BORROWER_ADDRESS, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_liquidate_revert_cannot_self_liquidate() {
    // Setup
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher.liquidate(token, collateral_token, TEST_USER_1, 0) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::CANNOT_SELF_LIQUIDATE, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_liquidate_revert_pool_not_exist() {
    // Setup
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Interact
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher.liquidate(token, collateral_token, TEST_USER_2, 0) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::POOL_NOT_EXIST, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_liquidate_revert_havent_borrow_yet() {
    ///////////
    // Setup //
    ///////////
    let (market_contract_address, _, _, token, collateral_token, _, _) = deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Deploy pool
    deploy_new_pool(market_contract_address, token, collateral_token);

    //////////////
    // Interact //
    //////////////
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher.liquidate(token, collateral_token, TEST_USER_2, 0) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::HAVENT_BORROW_YET, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_liquidate_revert_invalid_borrow_id() {
    ///////////
    // Setup //
    ///////////
    let (
        market_contract_address,
        _,
        _,
        token,
        collateral_token,
        mock_token_aggregator,
        mock_collateral_token_aggregator,
    ) =
        deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Deploy pool
    deploy_new_pool(market_contract_address, token, collateral_token);

    // Mint mock token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_1, ref mint_calldata);
    Serde::serialize(@TEST_SUPPLY_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, TEST_USER_1);
    mock_token_dispatcher.approve(market_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(token);

    // Supply
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    market_safe_dispatcher.supply(token, collateral_token, TEST_SUPPLY_AMOUNT_1).unwrap();
    stop_cheat_caller_address(market_contract_address);

    // Mint mock collateral token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_2, ref mint_calldata);
    Serde::serialize(@TEST_COLLATERAL_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(collateral_token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock collateral token
    let mock_collateral_token_dispatcher = IERC20Dispatcher { contract_address: collateral_token };
    start_cheat_caller_address(collateral_token, TEST_USER_2);
    mock_collateral_token_dispatcher.approve(market_contract_address, TEST_COLLATERAL_AMOUNT_1);
    stop_cheat_caller_address(collateral_token);

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
    start_cheat_caller_address(market_contract_address, TEST_USER_2);
    market_safe_dispatcher
        .borrow(token, TEST_BORROW_AMOUNT_1, collateral_token, TEST_COLLATERAL_AMOUNT_1)
        .unwrap();
    stop_cheat_caller_address(market_contract_address);

    // Cache data before
    let pool_address = match market_safe_dispatcher.get_pools(token, collateral_token) {
        Result::Ok(pool_address) => pool_address,
        Result::Err(_) => panic_with_felt252('Should not panicked'),
    };
    let expected_borrow_id = IPoolDispatcher { contract_address: pool_address }
        .get_user_borrow_quantity(TEST_USER_2)
        - 1;

    //////////////
    // Interact //
    //////////////
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher
        .liquidate(token, collateral_token, TEST_USER_2, expected_borrow_id + 1) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::INVALID_BORROW_ID, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_liquidate_revert_liquidate_not_allowed() {
    ///////////
    // Setup //
    ///////////
    let (
        market_contract_address,
        _,
        _,
        token,
        collateral_token,
        mock_token_aggregator,
        mock_collateral_token_aggregator,
    ) =
        deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Deploy pool
    deploy_new_pool(market_contract_address, token, collateral_token);

    // Mint mock token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_1, ref mint_calldata);
    Serde::serialize(@TEST_SUPPLY_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, TEST_USER_1);
    mock_token_dispatcher.approve(market_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(token);

    // Supply
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    market_safe_dispatcher.supply(token, collateral_token, TEST_SUPPLY_AMOUNT_1).unwrap();
    stop_cheat_caller_address(market_contract_address);

    // Mint mock collateral token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_2, ref mint_calldata);
    Serde::serialize(@TEST_COLLATERAL_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(collateral_token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock collateral token
    let mock_collateral_token_dispatcher = IERC20Dispatcher { contract_address: collateral_token };
    start_cheat_caller_address(collateral_token, TEST_USER_2);
    mock_collateral_token_dispatcher.approve(market_contract_address, TEST_COLLATERAL_AMOUNT_1);
    stop_cheat_caller_address(collateral_token);

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
    start_cheat_caller_address(market_contract_address, TEST_USER_2);
    market_safe_dispatcher
        .borrow(token, TEST_BORROW_AMOUNT_1, collateral_token, TEST_COLLATERAL_AMOUNT_1)
        .unwrap();
    stop_cheat_caller_address(market_contract_address);

    // Cache data before
    let pool_address = match market_safe_dispatcher.get_pools(token, collateral_token) {
        Result::Ok(pool_address) => pool_address,
        Result::Err(_) => panic_with_felt252('Should not panicked'),
    };
    let expected_borrow_id = IPoolDispatcher { contract_address: pool_address }
        .get_user_borrow_quantity(TEST_USER_2)
        - 1;

    //////////////
    // Interact //
    //////////////

    // Expected HF = MOCK_AGGREGATOR_COLLATERAL_TOKEN_PRICE_ANSWER
    //             * TEST_COLLATERAL_AMOUNT_1
    //             * MOCK_AGGREGATOR_DECIMALS
    //             * THRESHOLD_LIQUIDATION
    //             / MOCK_AGGREGATOR_TOKEN_PRICE_ANSWER
    //             / TEST_BORROW_AMOUNT_1 + expected interest amount
    //             / MOCK_AGGREGATOR_DECIMALS
    //             = 400_000_000_000
    //             * 1_000_000e18
    //             * 8
    //             * 80
    //             / 300_000_000_000
    //             / (500_000e18 + 0)
    //             / 8
    //             = (4/3) * (1_000_000/500_000) * 80
    //             = ~213 > UPPER_LIQUIDATE_HF_WITH_DECIMALS = 100

    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    match market_safe_dispatcher
        .liquidate(token, collateral_token, TEST_USER_2, expected_borrow_id) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::LIQUIDATE_NOT_ALLOWED, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
}

#[test]
#[feature("safe_dispatcher")]
fn test_liquidate_revert_not_enough_balance_to_repay() {
    ///////////
    // Setup //
    ///////////
    let (
        market_contract_address,
        _,
        _,
        token,
        collateral_token,
        mock_token_aggregator,
        mock_collateral_token_aggregator,
    ) =
        deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Deploy pool
    deploy_new_pool(market_contract_address, token, collateral_token);

    // Mint mock token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_1, ref mint_calldata);
    Serde::serialize(@TEST_SUPPLY_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, TEST_USER_1);
    mock_token_dispatcher.approve(market_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(token);

    // Supply
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    market_safe_dispatcher.supply(token, collateral_token, TEST_SUPPLY_AMOUNT_1).unwrap();
    stop_cheat_caller_address(market_contract_address);

    // Mint mock collateral token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_2, ref mint_calldata);
    Serde::serialize(@TEST_COLLATERAL_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(collateral_token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock collateral token
    let mock_collateral_token_dispatcher = IERC20Dispatcher { contract_address: collateral_token };
    start_cheat_caller_address(collateral_token, TEST_USER_2);
    mock_collateral_token_dispatcher.approve(market_contract_address, TEST_COLLATERAL_AMOUNT_1);
    stop_cheat_caller_address(collateral_token);

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
    start_cheat_caller_address(market_contract_address, TEST_USER_2);
    market_safe_dispatcher
        .borrow(token, TEST_BORROW_AMOUNT_1, collateral_token, TEST_COLLATERAL_AMOUNT_1)
        .unwrap();
    stop_cheat_caller_address(market_contract_address);

    // Re setup price feed
    mock_collateral_token_aggregator_dispatcher
        .set_latest_round_data(
            MOCK_AGGREGATOR_COLLATERAL_TOKEN_LIQUIDATION_PRICE_ANSWER,
            MOCK_AGGREGATOR_BLOCK_NUM,
            MOCK_AGGREGATOR_OBSERVATION_TIMESTAMP,
            MOCK_AGGREGATOR_TRANSMISSION_TIMESTAMP,
        );

    // Cache data before
    let pool_address = match market_safe_dispatcher.get_pools(token, collateral_token) {
        Result::Ok(pool_address) => pool_address,
        Result::Err(_) => panic_with_felt252('Should not panicked'),
    };
    let expected_borrow_id = IPoolDispatcher { contract_address: pool_address }
        .get_user_borrow_quantity(TEST_USER_2)
        - 1;
    let liquidation_timestamp = borrow_timestamp + YEAR_TIMESTAMPS.into();

    //////////////
    // Interact //
    //////////////

    // Expected HF = ~92 < UPPER_LIQUIDATE_HF_WITH_DECIMALS = 100

    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    start_cheat_block_timestamp_global(liquidation_timestamp);
    match market_safe_dispatcher
        .liquidate(token, collateral_token, TEST_USER_2, expected_borrow_id) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_ENOUGH_BALANCE_TO_REPAY, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
    stop_cheat_block_timestamp_global();
}

#[test]
#[feature("safe_dispatcher")]
fn test_liquidate_revert_not_enough_allowance() {
    ///////////
    // Setup //
    ///////////
    let (
        market_contract_address,
        _,
        _,
        token,
        collateral_token,
        mock_token_aggregator,
        mock_collateral_token_aggregator,
    ) =
        deploy_contract();
    let market_safe_dispatcher = IMarketSafeDispatcher {
        contract_address: market_contract_address,
    };

    // Deploy pool
    deploy_new_pool(market_contract_address, token, collateral_token);

    // Mint mock token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_1, ref mint_calldata);
    Serde::serialize(@TEST_SUPPLY_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock token
    let mock_token_dispatcher = IERC20Dispatcher { contract_address: token };
    start_cheat_caller_address(token, TEST_USER_1);
    mock_token_dispatcher.approve(market_contract_address, TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(token);

    // Supply
    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    market_safe_dispatcher.supply(token, collateral_token, TEST_SUPPLY_AMOUNT_1).unwrap();
    stop_cheat_caller_address(market_contract_address);

    // Mint mock collateral token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_2, ref mint_calldata);
    Serde::serialize(@TEST_COLLATERAL_AMOUNT_1, ref mint_calldata);
    let mut res = call_contract_syscall(collateral_token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    // Approve mock collateral token
    let mock_collateral_token_dispatcher = IERC20Dispatcher { contract_address: collateral_token };
    start_cheat_caller_address(collateral_token, TEST_USER_2);
    mock_collateral_token_dispatcher.approve(market_contract_address, TEST_COLLATERAL_AMOUNT_1);
    stop_cheat_caller_address(collateral_token);

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
    start_cheat_caller_address(market_contract_address, TEST_USER_2);
    market_safe_dispatcher
        .borrow(token, TEST_BORROW_AMOUNT_1, collateral_token, TEST_COLLATERAL_AMOUNT_1)
        .unwrap();
    stop_cheat_caller_address(market_contract_address);

    // Re setup price feed
    mock_collateral_token_aggregator_dispatcher
        .set_latest_round_data(
            MOCK_AGGREGATOR_COLLATERAL_TOKEN_LIQUIDATION_PRICE_ANSWER,
            MOCK_AGGREGATOR_BLOCK_NUM,
            MOCK_AGGREGATOR_OBSERVATION_TIMESTAMP,
            MOCK_AGGREGATOR_TRANSMISSION_TIMESTAMP,
        );

    // Cache data before
    let pool_address = match market_safe_dispatcher.get_pools(token, collateral_token) {
        Result::Ok(pool_address) => pool_address,
        Result::Err(_) => panic_with_felt252('Should not panicked'),
    };
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_address };
    let expected_borrow_id = pool_dispatcher.get_user_borrow_quantity(TEST_USER_2) - 1;
    let expected_user_borrow_info = pool_dispatcher
        .get_user_borrow_info(TEST_USER_2, expected_borrow_id);
    let expected_user_borrow_apr = expected_user_borrow_info.borrow_apr;
    let expected_user_borrow_start_time = expected_user_borrow_info.borrow_start_time;
    let liquidation_timestamp = borrow_timestamp + YEAR_TIMESTAMPS.into();
    let expected_interest_amount = TEST_BORROW_AMOUNT_1
        * expected_user_borrow_apr
        * (liquidation_timestamp - expected_user_borrow_start_time).into()
        / (YEAR_TIMESTAMPS.into() * ten_pow_decimals().into() * ten_pow_decimals().into());
    let expected_total_repay_amount = TEST_BORROW_AMOUNT_1 + expected_interest_amount;

    // Mint `expected_total_repay_amount` of mock token
    let mut mint_calldata: Array<felt252> = array![];
    Serde::serialize(@TEST_USER_1, ref mint_calldata);
    Serde::serialize(@expected_total_repay_amount, ref mint_calldata);
    let mut res = call_contract_syscall(token, selector!("mint"), mint_calldata.span())
        .unwrap_syscall();
    assert(Serde::<bool>::deserialize(ref res).unwrap(), 'Mock mint failed');

    //////////////
    // Interact //
    //////////////

    // Expected HF = ~92 < UPPER_LIQUIDATE_HF_WITH_DECIMALS = 100

    start_cheat_caller_address(market_contract_address, TEST_USER_1);
    start_cheat_block_timestamp_global(liquidation_timestamp);
    match market_safe_dispatcher
        .liquidate(token, collateral_token, TEST_USER_2, expected_borrow_id) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_ENOUGH_ALLOWANCE, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(market_contract_address);
    stop_cheat_block_timestamp_global();
}

