// External imports
use core::num::traits::Zero;
use core::panic_with_felt252;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, interact_with_state,
    start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::storage::StoragePointerReadAccess;
use starknet::{ClassHash, ContractAddress, SyscallResultTrait, get_block_timestamp};

// Internal imports
use starknet_lending_sc::{
    constants::{BASE_INTEREST_RATE, OPTIMAL_UTILIZATION_RATE, RSLOPE_1, RSLOPE_2, ten_pow_decimals},
    errors::Error,
    interfaces::{
        IPoolDispatcher, IPoolDispatcherTrait, IPoolSafeDispatcher, IPoolSafeDispatcherTrait,
        UserBorrowInfo,
    },
    lp_token::LPToken, pool::Pool,
};
use super::test_constants::{
    TEST_ACTUAL_INTEREST_AMOUNT_1, TEST_APPROVE_AMOUNT, TEST_BORROW_AMOUNT_1, TEST_BORROW_AMOUNT_2,
    TEST_BORROW_APR, TEST_COLLATERAL_AMOUNT_1, TEST_EXPECTED_INTEREST_AMOUNT_1, TEST_HF_1,
    TEST_HF_2, TEST_LP_AMOUNT, TEST_MARKET_CONTRACT, TEST_SUPPLY_AMOUNT_1, TEST_USER_1, TEST_USER_2,
    TEST_UTILIZATION_RATE_1, mock_erc20_collateral_token_name, mock_erc20_token_name,
    mock_lp_token_name,
};

fn deploy_contract() -> (ContractAddress, ContractAddress, ContractAddress) {
    // Declare contract
    let mock_erc20_token_contract = declare("MockERC20").unwrap_syscall().contract_class();
    let lp_token_contract = declare("LPToken").unwrap_syscall().contract_class();
    let pool_contract = declare("Pool").unwrap_syscall().contract_class();

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
    let lp_token_class_hash: ClassHash = *lp_token_contract.class_hash;
    let _market_contract: ContractAddress = TEST_MARKET_CONTRACT;
    let mut pool_deploy_data = array![];
    Serde::serialize(@_token, ref pool_deploy_data);
    Serde::serialize(@_collateral_token, ref pool_deploy_data);
    Serde::serialize(@lp_token_class_hash, ref pool_deploy_data);
    Serde::serialize(@_market_contract, ref pool_deploy_data);

    // Deploy contract
    let (pool_contract_address, _) = pool_contract.deploy(@pool_deploy_data).unwrap_syscall();

    // Return
    (pool_contract_address, _token, _collateral_token)
}

#[test]
fn test_deploy_pool() {
    // Setup
    let (pool_contract_address, token_contract_address, collateral_token_contract_address) =
        deploy_contract();

    // Assert
    let lp_token = interact_with_state(
        pool_contract_address,
        || {
            let mut state = Pool::contract_state_for_testing();
            let market_contract = state.market_contract.read();
            let token = state.token.read();
            let collateral_token = state.collateral_token.read();
            let lp_token = state.lp_token.read();
            assert(market_contract == TEST_MARKET_CONTRACT, 'Invalid market contract address');
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
            assert(market_contract == TEST_MARKET_CONTRACT, 'Invalid market contract address');
            assert(pool == pool_contract_address, 'Invalid pool contract address');
            assert(name == mock_lp_token_name(), 'Invalid lp token name');
            assert(symbol == mock_lp_token_name(), 'Invalid lp token symbol');
        },
    );
}

#[test]
fn test_get_token_name() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };

    // Assert
    assert(pool_dispatcher.get_token_name() == mock_erc20_token_name(), 'Invalid token name')
}

#[test]
fn test_get_collateral_token_name() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };

    // Assert
    assert(
        pool_dispatcher.get_collateral_token_name() == mock_erc20_collateral_token_name(),
        'Invalid collateral token name',
    )
}

#[test]
fn test_get_token_symbol() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };

    // Assert
    assert(pool_dispatcher.get_token_symbol() == mock_erc20_token_name(), 'Invalid token symbol')
}

#[test]
fn test_get_collateral_token_symbol() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };

    // Assert
    assert(
        pool_dispatcher.get_collateral_token_symbol() == mock_erc20_collateral_token_name(),
        'Invalid collateral token symbol',
    )
}

#[test]
fn test_lp_token_address() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };

    // Assert
    assert(pool_dispatcher.get_lp_token_address().is_non_zero(), 'Invalid lp token')
}

#[test]
fn test_calculate_utilization_rate() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    let utilization_rate_before = pool_dispatcher.calculate_utilization_rate();
    start_cheat_caller_address(pool_contract_address, TEST_MARKET_CONTRACT);
    pool_dispatcher.add_total_supply(TEST_SUPPLY_AMOUNT_1);
    pool_dispatcher.add_total_borrow(TEST_BORROW_AMOUNT_1);
    stop_cheat_caller_address(pool_contract_address);

    // Assert
    assert(utilization_rate_before == 0, 'Invalid utilization rate');
    assert(
        pool_dispatcher.calculate_utilization_rate() == TEST_UTILIZATION_RATE_1,
        'Invalid utilization rate',
    );
}

#[test]
fn test_calculate_borrow_apr() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    let base_borrow_apr: u256 = BASE_INTEREST_RATE.into() * ten_pow_decimals().into();
    let borrow_apr_before = pool_dispatcher.calculate_borrow_apr();
    start_cheat_caller_address(pool_contract_address, TEST_MARKET_CONTRACT);
    pool_dispatcher.add_total_supply(TEST_SUPPLY_AMOUNT_1);
    pool_dispatcher.add_total_borrow(TEST_BORROW_AMOUNT_1);
    let borrow_apr_low_charge = pool_dispatcher.calculate_borrow_apr();
    let utilization_rate_low_charge = pool_dispatcher.calculate_utilization_rate();
    pool_dispatcher.add_total_borrow(TEST_BORROW_AMOUNT_2);
    let borrow_apr_high_charge = pool_dispatcher.calculate_borrow_apr();
    let utilization_rate_high_charge = pool_dispatcher.calculate_utilization_rate();
    stop_cheat_caller_address(pool_contract_address);

    // Assert
    assert(borrow_apr_before == base_borrow_apr, 'Invalid borrow apr');
    assert(
        borrow_apr_low_charge == base_borrow_apr
            + RSLOPE_1.into() * utilization_rate_low_charge / ten_pow_decimals().into(),
        'Invalid borrow apr',
    );
    assert(
        borrow_apr_high_charge == base_borrow_apr
            + RSLOPE_1.into() * OPTIMAL_UTILIZATION_RATE.into()
            + RSLOPE_2.into()
                * ((utilization_rate_high_charge
                    - (OPTIMAL_UTILIZATION_RATE.into() * ten_pow_decimals().into()))
                    / ten_pow_decimals().into()),
        'Invalid borrow apr',
    );
}

#[test]
fn test_calculate_supply_apy() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    let supply_apy_before = pool_dispatcher.calculate_supply_apy();
    start_cheat_caller_address(pool_contract_address, TEST_MARKET_CONTRACT);
    pool_dispatcher.add_total_supply(TEST_SUPPLY_AMOUNT_1 + TEST_ACTUAL_INTEREST_AMOUNT_1);
    pool_dispatcher.add_total_borrow(TEST_BORROW_AMOUNT_1);
    pool_dispatcher.add_expected_interest_amount_per_year(TEST_EXPECTED_INTEREST_AMOUNT_1);
    pool_dispatcher.add_actual_interest_amount(TEST_ACTUAL_INTEREST_AMOUNT_1);
    stop_cheat_caller_address(pool_contract_address);

    // Assert
    assert(supply_apy_before == 0, 'Invalid supply apy');
    assert(
        pool_dispatcher.calculate_supply_apy() == TEST_EXPECTED_INTEREST_AMOUNT_1
            * ten_pow_decimals().into()
            * ten_pow_decimals().into()
            / ((TEST_SUPPLY_AMOUNT_1 + TEST_ACTUAL_INTEREST_AMOUNT_1)
                - TEST_ACTUAL_INTEREST_AMOUNT_1),
        'Invalid supply apy',
    );
}

#[test]
fn test_add_user_lp_owned() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    let lp_owned_before = pool_dispatcher.get_user_to_lp_owned(TEST_USER_1);

    // Interact
    start_cheat_caller_address(pool_contract_address, TEST_MARKET_CONTRACT);
    pool_dispatcher.add_user_lp_owned(TEST_USER_1, TEST_LP_AMOUNT);
    stop_cheat_caller_address(pool_contract_address);

    // Assert
    assert(
        lp_owned_before + TEST_LP_AMOUNT == pool_dispatcher.get_user_to_lp_owned(TEST_USER_1),
        'Invalid lp owned',
    );
}

#[test]
#[feature("safe_dispatcher")]
fn test_add_user_lp_owned_revert_not_market_contract() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_safe_dispatcher = IPoolSafeDispatcher { contract_address: pool_contract_address };

    // Interact
    start_cheat_caller_address(pool_contract_address, TEST_USER_1);
    match pool_safe_dispatcher.add_user_lp_owned(TEST_USER_1, TEST_LP_AMOUNT) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_MARKET_OR_LP_CONTRACT, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(pool_contract_address);
}

#[test]
fn test_subtract_user_lp_owned() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    start_cheat_caller_address(pool_contract_address, TEST_MARKET_CONTRACT);
    pool_dispatcher.add_user_lp_owned(TEST_USER_1, TEST_LP_AMOUNT);
    let lp_owned_before = pool_dispatcher.get_user_to_lp_owned(TEST_USER_1);

    // Interact
    pool_dispatcher.subtract_user_lp_owned(TEST_USER_1, TEST_LP_AMOUNT);
    stop_cheat_caller_address(pool_contract_address);

    // Assert
    assert(
        lp_owned_before - TEST_LP_AMOUNT == pool_dispatcher.get_user_to_lp_owned(TEST_USER_1),
        'Invalid lp owned',
    );
}

#[test]
#[feature("safe_dispatcher")]
fn test_subtract_user_lp_owned_revert_not_market_contract() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_safe_dispatcher = IPoolSafeDispatcher { contract_address: pool_contract_address };
    start_cheat_caller_address(pool_contract_address, TEST_MARKET_CONTRACT);
    pool_safe_dispatcher.add_user_lp_owned(TEST_USER_1, TEST_LP_AMOUNT).unwrap();
    stop_cheat_caller_address(pool_contract_address);

    // Interact
    start_cheat_caller_address(pool_contract_address, TEST_USER_1);
    match pool_safe_dispatcher.subtract_user_lp_owned(TEST_USER_1, TEST_LP_AMOUNT) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_MARKET_OR_LP_CONTRACT, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(pool_contract_address);
}

#[test]
fn test_add_total_supply() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    let total_supply_before = pool_dispatcher.get_total_supply();

    // Interact
    start_cheat_caller_address(pool_contract_address, TEST_MARKET_CONTRACT);
    pool_dispatcher.add_total_supply(TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(pool_contract_address);

    // Assert
    assert(
        total_supply_before + TEST_SUPPLY_AMOUNT_1 == pool_dispatcher.get_total_supply(),
        'Invalid total supply',
    );
}

#[test]
#[feature("safe_dispatcher")]
fn test_add_total_supply_revert_not_market_contract() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_safe_dispatcher = IPoolSafeDispatcher { contract_address: pool_contract_address };

    // Interact
    start_cheat_caller_address(pool_contract_address, TEST_USER_1);
    match pool_safe_dispatcher.add_total_supply(TEST_SUPPLY_AMOUNT_1) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_MARKET_CONTRACT, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(pool_contract_address);
}

#[test]
fn test_subtract_total_supply() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    start_cheat_caller_address(pool_contract_address, TEST_MARKET_CONTRACT);
    pool_dispatcher.add_total_supply(TEST_SUPPLY_AMOUNT_1);
    let total_supply_before = pool_dispatcher.get_total_supply();

    // Interact
    pool_dispatcher.subtract_total_supply(TEST_SUPPLY_AMOUNT_1);
    stop_cheat_caller_address(pool_contract_address);

    // Assert
    assert(
        total_supply_before - TEST_SUPPLY_AMOUNT_1 == pool_dispatcher.get_total_supply(),
        'Invalid total supply',
    );
}

#[test]
#[feature("safe_dispatcher")]
fn test_subtract_total_supply_revert_not_market_contract() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_safe_dispatcher = IPoolSafeDispatcher { contract_address: pool_contract_address };
    start_cheat_caller_address(pool_contract_address, TEST_MARKET_CONTRACT);
    pool_safe_dispatcher.add_total_supply(TEST_SUPPLY_AMOUNT_1).unwrap();
    stop_cheat_caller_address(pool_contract_address);

    // Interact
    start_cheat_caller_address(pool_contract_address, TEST_USER_1);
    match pool_safe_dispatcher.subtract_total_supply(TEST_SUPPLY_AMOUNT_1) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_MARKET_CONTRACT, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(pool_contract_address);
}

#[test]
fn test_add_total_borrow() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    let total_borrow_before = pool_dispatcher.get_total_borrow();

    // Interact
    start_cheat_caller_address(pool_contract_address, TEST_MARKET_CONTRACT);
    pool_dispatcher.add_total_borrow(TEST_BORROW_AMOUNT_1);
    stop_cheat_caller_address(pool_contract_address);

    // Assert
    assert(
        total_borrow_before + TEST_BORROW_AMOUNT_1 == pool_dispatcher.get_total_borrow(),
        'Invalid total borrow',
    );
}

#[test]
#[feature("safe_dispatcher")]
fn test_add_total_borrow_revert_not_market_contract() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_safe_dispatcher = IPoolSafeDispatcher { contract_address: pool_contract_address };

    // Interact
    start_cheat_caller_address(pool_contract_address, TEST_USER_1);
    match pool_safe_dispatcher.add_total_borrow(TEST_BORROW_AMOUNT_1) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_MARKET_CONTRACT, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(pool_contract_address);
}

#[test]
fn test_subtract_total_borrow() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    start_cheat_caller_address(pool_contract_address, TEST_MARKET_CONTRACT);
    pool_dispatcher.add_total_borrow(TEST_BORROW_AMOUNT_1);
    let total_borrow_before = pool_dispatcher.get_total_borrow();

    // Interact
    pool_dispatcher.subtract_total_borrow(TEST_BORROW_AMOUNT_1);
    stop_cheat_caller_address(pool_contract_address);

    // Assert
    assert(
        total_borrow_before - TEST_BORROW_AMOUNT_1 == pool_dispatcher.get_total_borrow(),
        'Invalid total borrow',
    );
}

#[test]
#[feature("safe_dispatcher")]
fn test_subtract_total_borrow_revert_not_market_contract() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_safe_dispatcher = IPoolSafeDispatcher { contract_address: pool_contract_address };
    start_cheat_caller_address(pool_contract_address, TEST_MARKET_CONTRACT);
    pool_safe_dispatcher.add_total_borrow(TEST_BORROW_AMOUNT_1).unwrap();
    stop_cheat_caller_address(pool_contract_address);

    // Interact
    start_cheat_caller_address(pool_contract_address, TEST_USER_1);
    match pool_safe_dispatcher.subtract_total_borrow(TEST_BORROW_AMOUNT_1) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_MARKET_CONTRACT, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(pool_contract_address);
}

#[test]
fn test_add_user_borrow_info() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    let user_borrow_info = UserBorrowInfo {
        borrow_amount: TEST_BORROW_AMOUNT_1,
        collateral_amount: TEST_COLLATERAL_AMOUNT_1,
        hf: TEST_HF_1,
        borrow_apr: TEST_BORROW_APR,
        borrow_start_time: get_block_timestamp(),
    };
    let user_borrow_quantity_before = pool_dispatcher.get_user_borrow_quantity(TEST_USER_1);
    let active_borrower_num_before = pool_dispatcher.get_active_borrower_num();

    // Interact
    start_cheat_caller_address(pool_contract_address, TEST_MARKET_CONTRACT);
    pool_dispatcher.add_user_borrow_info(TEST_USER_1, user_borrow_info);
    stop_cheat_caller_address(pool_contract_address);

    // Assert
    assert(
        pool_dispatcher
            .get_user_borrow_info(TEST_USER_1, user_borrow_quantity_before) == user_borrow_info,
        'Invalid user borrow info',
    );
    assert(
        user_borrow_quantity_before + 1 == pool_dispatcher.get_user_borrow_quantity(TEST_USER_1),
        'Invalid user borrow quantity',
    );
    assert(
        active_borrower_num_before + 1 == pool_dispatcher.get_active_borrower_num(),
        'Invalid active borrower num',
    );
    assert(
        pool_dispatcher.get_active_borrower(active_borrower_num_before) == TEST_USER_1,
        'Invalid active borrower',
    );
    assert(
        pool_dispatcher.get_active_borrower_index(TEST_USER_1) == active_borrower_num_before,
        'Invalid active borrower index',
    );
}

#[test]
#[feature("safe_dispatcher")]
fn test_add_user_borrow_info_revert_not_market_contract() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_safe_dispatcher = IPoolSafeDispatcher { contract_address: pool_contract_address };
    let user_borrow_info = UserBorrowInfo {
        borrow_amount: TEST_BORROW_AMOUNT_1,
        collateral_amount: TEST_COLLATERAL_AMOUNT_1,
        hf: TEST_HF_1,
        borrow_apr: TEST_BORROW_APR,
        borrow_start_time: get_block_timestamp(),
    };

    // Interact
    start_cheat_caller_address(pool_contract_address, TEST_USER_1);
    match pool_safe_dispatcher.add_user_borrow_info(TEST_USER_1, user_borrow_info) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_MARKET_CONTRACT, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(pool_contract_address);
}

#[test]
fn test_remove_user_borrow_info() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    let user_borrow_info_1 = UserBorrowInfo {
        borrow_amount: TEST_BORROW_AMOUNT_1,
        collateral_amount: TEST_COLLATERAL_AMOUNT_1,
        hf: TEST_HF_1,
        borrow_apr: TEST_BORROW_APR,
        borrow_start_time: get_block_timestamp(),
    };
    let user_borrow_info_2 = UserBorrowInfo {
        borrow_amount: TEST_BORROW_AMOUNT_2,
        collateral_amount: TEST_COLLATERAL_AMOUNT_1,
        hf: TEST_HF_2,
        borrow_apr: TEST_BORROW_APR,
        borrow_start_time: get_block_timestamp(),
    };
    start_cheat_caller_address(pool_contract_address, TEST_MARKET_CONTRACT);
    pool_dispatcher
        .add_user_borrow_info(TEST_USER_2, user_borrow_info_1); // borrow id 0, borrower index 0
    pool_dispatcher
        .add_user_borrow_info(TEST_USER_1, user_borrow_info_1); // borrow id 0, borrower index 1
    pool_dispatcher
        .add_user_borrow_info(TEST_USER_1, user_borrow_info_2); // borrow id 1, borrower index 1
    let user_borrow_quantity_before = pool_dispatcher.get_user_borrow_quantity(TEST_USER_1);
    let active_borrower_num_before = pool_dispatcher.get_active_borrower_num();

    // Interact
    pool_dispatcher.remove_borrow_info(TEST_USER_2, 0); // remove borrow id 0, borrower index 0
    pool_dispatcher.remove_borrow_info(TEST_USER_1, 0); // remove borrow id 0
    stop_cheat_caller_address(pool_contract_address);

    // Assert
    assert(
        pool_dispatcher.get_user_borrow_info(TEST_USER_1, 0) == user_borrow_info_2,
        'Invalid borrow info',
    );
    assert(
        user_borrow_quantity_before - 1 == pool_dispatcher.get_user_borrow_quantity(TEST_USER_1),
        'Invalid user borrow quantity',
    );
    assert(pool_dispatcher.get_active_borrower(0) == TEST_USER_1, 'Invalid active borrower');
    assert(
        pool_dispatcher.get_active_borrower_index(TEST_USER_1) == 0,
        'Invalid active borrower index',
    );
    assert(
        active_borrower_num_before - 1 == pool_dispatcher.get_active_borrower_num(),
        'Invalid active borrower num',
    );
}

#[test]
#[feature("safe_dispatcher")]
fn test_remove_user_borrow_info_revert_not_market_contract() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_safe_dispatcher = IPoolSafeDispatcher { contract_address: pool_contract_address };
    let user_borrow_info = UserBorrowInfo {
        borrow_amount: TEST_BORROW_AMOUNT_1,
        collateral_amount: TEST_COLLATERAL_AMOUNT_1,
        hf: TEST_HF_1,
        borrow_apr: TEST_BORROW_APR,
        borrow_start_time: get_block_timestamp(),
    };
    start_cheat_caller_address(pool_contract_address, TEST_MARKET_CONTRACT);
    pool_safe_dispatcher.add_user_borrow_info(TEST_USER_1, user_borrow_info).unwrap();
    stop_cheat_caller_address(pool_contract_address);

    // Interact
    start_cheat_caller_address(pool_contract_address, TEST_USER_1);
    match pool_safe_dispatcher.remove_borrow_info(TEST_USER_1, 0) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_MARKET_CONTRACT, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(pool_contract_address);
}

#[test]
fn test_add_expected_interest_amount_per_year() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    let expect_interest_amount_per_year_before = pool_dispatcher
        .get_expected_interest_amount_per_year();

    // Interact
    start_cheat_caller_address(pool_contract_address, TEST_MARKET_CONTRACT);
    pool_dispatcher.add_expected_interest_amount_per_year(TEST_EXPECTED_INTEREST_AMOUNT_1);
    stop_cheat_caller_address(pool_contract_address);

    // Assert
    assert(
        expect_interest_amount_per_year_before
            + TEST_EXPECTED_INTEREST_AMOUNT_1 == pool_dispatcher
                .get_expected_interest_amount_per_year(),
        'Invalid amount',
    );
}

#[test]
#[feature("safe_dispatcher")]
fn test_add_expected_interest_amount_per_year_revert_not_market_contract() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_safe_dispatcher = IPoolSafeDispatcher { contract_address: pool_contract_address };

    // Interact
    start_cheat_caller_address(pool_contract_address, TEST_USER_1);
    match pool_safe_dispatcher
        .add_expected_interest_amount_per_year(TEST_EXPECTED_INTEREST_AMOUNT_1) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_MARKET_CONTRACT, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(pool_contract_address);
}

#[test]
fn test_add_actual_interest_amount() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    let actual_interest_amount_before = pool_dispatcher.get_actual_interest_amount();

    // Interact
    start_cheat_caller_address(pool_contract_address, TEST_MARKET_CONTRACT);
    pool_dispatcher.add_actual_interest_amount(TEST_ACTUAL_INTEREST_AMOUNT_1);
    stop_cheat_caller_address(pool_contract_address);

    // Assert
    assert(
        actual_interest_amount_before
            + TEST_ACTUAL_INTEREST_AMOUNT_1 == pool_dispatcher.get_actual_interest_amount(),
        'Invalid amount',
    );
}

#[test]
#[feature("safe_dispatcher")]
fn test_add_actual_interest_amount_revert_not_market_contract() {
    // Setup
    let (pool_contract_address, _, _) = deploy_contract();
    let pool_safe_dispatcher = IPoolSafeDispatcher { contract_address: pool_contract_address };

    // Interact
    start_cheat_caller_address(pool_contract_address, TEST_USER_1);
    match pool_safe_dispatcher.add_actual_interest_amount(TEST_ACTUAL_INTEREST_AMOUNT_1) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_MARKET_CONTRACT, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(pool_contract_address);
}

#[test]
fn test_approve_transfer() {
    // Setup
    let (pool_contract_address, token, _) = deploy_contract();
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    let token_dispatcher = IERC20Dispatcher { contract_address: token };
    let allowance_before = token_dispatcher.allowance(pool_contract_address, TEST_MARKET_CONTRACT);

    // Interact
    start_cheat_caller_address(pool_contract_address, TEST_MARKET_CONTRACT);
    pool_dispatcher.approve_transfer(token, TEST_APPROVE_AMOUNT);
    stop_cheat_caller_address(pool_contract_address);

    // Assert
    assert(
        allowance_before
            + TEST_APPROVE_AMOUNT == token_dispatcher
                .allowance(pool_contract_address, TEST_MARKET_CONTRACT),
        'Invalid allowance amount',
    );
}

#[test]
#[feature("safe_dispatcher")]
fn test_approve_transfer_revert_not_market_contract() {
    // Setup
    let (pool_contract_address, token, _) = deploy_contract();
    let pool_safe_dispatcher = IPoolSafeDispatcher { contract_address: pool_contract_address };

    // Interact
    start_cheat_caller_address(pool_contract_address, TEST_USER_1);
    match pool_safe_dispatcher.approve_transfer(token, TEST_APPROVE_AMOUNT) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_MARKET_CONTRACT, *panic_data.at(0))
        },
    }
    stop_cheat_caller_address(pool_contract_address);
}
