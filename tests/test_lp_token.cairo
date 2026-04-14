// External imports
use core::panic_with_felt252;
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, interact_with_state,
    start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::storage::StoragePointerReadAccess;
use starknet::{ClassHash, ContractAddress, SyscallResultTrait};

// Internal imports
use starknet_lending_sc::{
    errors::Error,
    interfaces::{
        ILPTokenDispatcher, ILPTokenDispatcherTrait, ILPTokenSafeDispatcher,
        ILPTokenSafeDispatcherTrait, IPoolDispatcher, IPoolDispatcherTrait, LPTokenDeployData,
    },
    lp_token::LPToken, pool::Pool,
};
use super::test_constants::{
    TEST_BURN_AMOUNT, TEST_MARKET_CONTRACT, TEST_MINT_AMOUNT, TEST_POOL_CONTRACT,
    TEST_TRANSFER_AMOUNT, TEST_USER_1, TEST_USER_2, mock_erc20_collateral_token_name,
    mock_erc20_token_name, mock_lp_token_name,
};

fn deploy_lp_token_contract() -> ContractAddress {
    // Declare contract
    let contract = declare("LPToken").unwrap_syscall().contract_class();

    // Prepare LP token deploy data
    let lp_token_name: ByteArray = mock_lp_token_name();
    let lp_token_symbol = lp_token_name.clone();
    let _market_contract: ContractAddress = TEST_MARKET_CONTRACT;
    let _pool_contract: ContractAddress = TEST_POOL_CONTRACT;
    let mut calldata: Array<felt252> = array![];
    let mut deploy_data = LPTokenDeployData {
        name: lp_token_name,
        symbol: lp_token_symbol,
        _market_contract: _market_contract,
        _pool: _pool_contract,
    };
    Serde::serialize(@deploy_data, ref calldata);

    // Deploy contract
    let (contract_address, _) = contract.deploy(@calldata).unwrap_syscall();

    // Return
    contract_address
}

fn deploy_pool_contract() -> ContractAddress {
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
    let (contract_address, _) = pool_contract.deploy(@pool_deploy_data).unwrap_syscall();

    // Return
    contract_address
}

#[test]
fn test_deploy_lp_token() {
    // Setup
    let contract_address = deploy_lp_token_contract();

    // Assert
    interact_with_state(
        contract_address,
        || {
            let mut state = LPToken::contract_state_for_testing();
            let market_contract = state.market_contract.read();
            let pool = state.pool.read();
            let name = state.erc20.ERC20_name.read();
            let symbol = state.erc20.ERC20_symbol.read();
            assert(market_contract == TEST_MARKET_CONTRACT, 'Invalid market contract address');
            assert(pool == TEST_POOL_CONTRACT, 'Invalid pool contract address');
            assert(name == mock_lp_token_name(), 'Invalid token name');
            assert(symbol == mock_lp_token_name(), 'Invalid token symbol');
        },
    )
}

#[test]
fn test_mint() {
    // Setup
    let contract_address = deploy_lp_token_contract();
    let dispatcher = ILPTokenDispatcher { contract_address };
    let balance_before = dispatcher.balance_of(TEST_USER_1);
    let total_supply_before = dispatcher.total_supply();

    // Interact
    start_cheat_caller_address(contract_address, TEST_MARKET_CONTRACT);
    dispatcher.mint(TEST_USER_1, TEST_MINT_AMOUNT);
    stop_cheat_caller_address(contract_address);

    // Assert
    assert(
        balance_before + TEST_MINT_AMOUNT == dispatcher.balance_of(TEST_USER_1), 'Invalid balance',
    );
    assert(
        total_supply_before + TEST_MINT_AMOUNT == dispatcher.total_supply(), 'Invalid total supply',
    );
}

#[test]
#[feature("safe_dispatcher")]
fn test_mint_revert_not_market_contract() {
    // Setup
    let contract_address = deploy_lp_token_contract();
    let safe_dispatcher = ILPTokenSafeDispatcher { contract_address };

    // Interact
    start_cheat_caller_address(contract_address, TEST_USER_1);
    match safe_dispatcher.mint(TEST_USER_1, TEST_MINT_AMOUNT) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_MARKET_CONTRACT, *panic_data.at(0));
        },
    }
    stop_cheat_caller_address(contract_address);
}

#[test]
fn test_burn() {
    // Setup
    let contract_address = deploy_lp_token_contract();
    let dispatcher = ILPTokenDispatcher { contract_address };
    start_cheat_caller_address(contract_address, TEST_MARKET_CONTRACT);
    dispatcher.mint(TEST_USER_1, TEST_MINT_AMOUNT);
    let balance_before = dispatcher.balance_of(TEST_USER_1);
    let total_supply_before = dispatcher.total_supply();

    // Interact
    dispatcher.burn(TEST_USER_1, TEST_MINT_AMOUNT);
    stop_cheat_caller_address(contract_address);

    // Assert
    assert(
        balance_before - TEST_MINT_AMOUNT == dispatcher.balance_of(TEST_USER_1), 'Invalid balance',
    );
    assert(
        total_supply_before - TEST_MINT_AMOUNT == dispatcher.total_supply(), 'Invalid total supply',
    );
}

#[test]
#[feature("safe_dispatcher")]
fn test_burn_revert_not_market_contract() {
    // Setup
    let contract_address = deploy_lp_token_contract();
    let safe_dispatcher = ILPTokenSafeDispatcher { contract_address };

    // Interact
    start_cheat_caller_address(contract_address, TEST_USER_1);
    match safe_dispatcher.burn(TEST_USER_1, TEST_BURN_AMOUNT) {
        Result::Ok(_) => panic_with_felt252('Should have panicked'),
        Result::Err(panic_data) => {
            assert(*panic_data.at(0) == Error::NOT_MARKET_CONTRACT, *panic_data.at(0));
        },
    }
    stop_cheat_caller_address(contract_address);
}

#[test]
fn test_lp_transfer_hook() {
    // Setup
    let pool_contract_address = deploy_pool_contract();
    let lp_token_contract_address: ContractAddress = interact_with_state(
        pool_contract_address,
        || {
            let mut state = Pool::contract_state_for_testing();
            state.lp_token.read()
        },
    );
    let pool_dispatcher = IPoolDispatcher { contract_address: pool_contract_address };
    let lp_token_dispatcher = ILPTokenDispatcher { contract_address: lp_token_contract_address };
    start_cheat_caller_address(pool_contract_address, TEST_MARKET_CONTRACT);
    start_cheat_caller_address(lp_token_contract_address, TEST_MARKET_CONTRACT);
    lp_token_dispatcher.mint(TEST_USER_1, TEST_MINT_AMOUNT);
    lp_token_dispatcher.mint(TEST_USER_2, TEST_MINT_AMOUNT);
    pool_dispatcher.add_user_lp_owned(TEST_USER_1, TEST_MINT_AMOUNT);
    pool_dispatcher.add_user_lp_owned(TEST_USER_2, TEST_MINT_AMOUNT);
    stop_cheat_caller_address(pool_contract_address);
    stop_cheat_caller_address(lp_token_contract_address);
    let user_1_to_lp_owned_before = pool_dispatcher.get_user_to_lp_owned(TEST_USER_1);
    let user_2_to_lp_owned_before = pool_dispatcher.get_user_to_lp_owned(TEST_USER_2);

    // Interact
    start_cheat_caller_address(lp_token_contract_address, TEST_USER_1);
    lp_token_dispatcher.transfer(TEST_USER_2, TEST_TRANSFER_AMOUNT);
    stop_cheat_caller_address(lp_token_contract_address);

    // Assert
    assert(
        user_1_to_lp_owned_before == pool_dispatcher.get_user_to_lp_owned(TEST_USER_1)
            + TEST_TRANSFER_AMOUNT,
        'Invalid amount',
    );
    assert(
        user_2_to_lp_owned_before == pool_dispatcher.get_user_to_lp_owned(TEST_USER_2)
            - TEST_TRANSFER_AMOUNT,
        'Invalid amount',
    );
}
