// External imports
use starknet::{ClassHash, ContractAddress};

// Structs
/// Stores borrowing information for a specific user borrow position
#[derive(Copy, Drop, Serde, PartialEq, starknet::Store)]
pub struct UserBorrowInfo {
    pub borrow_amount: u256,
    pub collateral_amount: u256,
    pub hf: u256,
    pub borrow_apr: u256,
    pub borrow_start_time: u64,
}

/// Aggregated information about a lending pool
#[derive(Drop, Serde)]
pub struct PoolInfo {
    pub pool: ByteArray,
    pub total_borrow: u256,
    pub total_supply: u256,
    pub ur: u256,
    pub borrow_apr: u256,
    pub supply_apy: u256,
}

/// Data passed in LP Token contract's constructor
#[derive(Drop, Serde)]
pub struct LPTokenDeployData {
    pub name: ByteArray,
    pub symbol: ByteArray,
    pub _market_contract: ContractAddress,
    pub _pool: ContractAddress,
}

/// Data passed in Pool contract's constructor
#[derive(Drop, Serde)]
pub struct PoolDeployData {
    pub _token: ContractAddress,
    pub _collateral_token: ContractAddress,
    pub lp_token_class_hash: ClassHash,
    pub _market_contract: ContractAddress,
}

/// Chainlink aggregator contract's return data
#[derive(Drop, Serde, starknet::Store)]
pub struct Round {
    pub round_id: felt252,
    pub answer: u128,
    pub block_num: u64,
    pub started_at: u64,
    pub updated_at: u64,
}

// Interfaces
/// Market contract's interface
#[starknet::interface]
pub trait IMarket<TContractState> {
    /// Returns the USD price (include decimals) of a token along with its decimals
    fn get_price_usd(self: @TContractState, token: ContractAddress) -> (u128, u8);

    /// Returns the pool address for a given token and collateral pair
    fn get_pools(
        self: @TContractState, token: ContractAddress, collateral_token: ContractAddress,
    ) -> ContractAddress;

    /// Deploys a new lending pool for a token–collateral pair
    fn deploy_new_pool(
        ref self: TContractState, token: ContractAddress, collateral_token: ContractAddress,
    );

    /// Update price feed address
    fn update_price_feed_address(
        ref self: TContractState,
        _chainlink_price_feed_token: ContractAddress,
        _chainlink_price_feed_address: ContractAddress,
    );

    /// Supplies liquidity to a pool and mints LP tokens
    fn supply(
        ref self: TContractState,
        token: ContractAddress,
        collateral: ContractAddress,
        supply_amount: u256,
    );

    /// Withdraws supplied liquidity by burning LP tokens
    fn withdraw(
        ref self: TContractState,
        token: ContractAddress,
        collateral: ContractAddress,
        lp_amount_withdraw: u256,
    );

    /// Borrows assets by spending collateral
    fn borrow(
        ref self: TContractState,
        borrow_token: ContractAddress,
        borrow_amount: u256,
        collateral_token: ContractAddress,
        collateral_amount: u256,
    );

    /// Repays an existing borrow position
    fn repay(
        ref self: TContractState,
        repay_token: ContractAddress,
        collateral_token: ContractAddress,
        borrow_id: u256,
    );

    /// Liquidates an undercollateralized borrow position
    fn liquidate(
        ref self: TContractState,
        repay_token: ContractAddress,
        collateral_token: ContractAddress,
        borrower: ContractAddress,
        borrow_id: u256,
    );
}

/// Pool contract's interface
#[starknet::interface]
pub trait IPool<TContractState> {
    /// Returns the name of the borrow token
    fn get_token_name(self: @TContractState) -> ByteArray;

    /// Returns the name of the collateral token
    fn get_collateral_token_name(self: @TContractState) -> ByteArray;

    /// Returns the symbol of the borrow token
    fn get_token_symbol(self: @TContractState) -> ByteArray;

    /// Returns the symbol of the collateral token
    fn get_collateral_token_symbol(self: @TContractState) -> ByteArray;

    /// Returns the total supplied tokens
    fn get_total_supply(self: @TContractState) -> u256;

    /// Returns the total borrowed tokens
    fn get_total_borrow(self: @TContractState) -> u256;

    /// Returns the LP token contract address
    fn get_lp_token_address(self: @TContractState) -> ContractAddress;

    /// Returns the amount of LP tokens owned by a user
    fn get_user_to_lp_owned(self: @TContractState, user: ContractAddress) -> u256;

    /// Returns the total borrow positions of a user
    fn get_user_borrow_quantity(self: @TContractState, user: ContractAddress) -> u256;

    /// Returns detailed borrow information for a user position
    fn get_user_borrow_info(
        self: @TContractState, user: ContractAddress, borrow_id: u256,
    ) -> UserBorrowInfo;

    /// Returns the number of active borrowers
    fn get_active_borrower_num(self: @TContractState) -> u256;

    /// Returns the index of a borrower in the active borrower list
    fn get_active_borrower_index(self: @TContractState, borrower: ContractAddress) -> u256;

    /// Returns the borrower address at a given index of the active borrower list
    fn get_active_borrower(self: @TContractState, index: u256) -> ContractAddress;

    /// Returns the expected interest accrued per year
    fn get_expected_interest_amount_per_year(self: @TContractState) -> u256;

    /// Returns the actual accrued interest
    fn get_actual_interest_amount(self: @TContractState) -> u256;

    /// Returns aggregated pool information
    fn get_pool_info(self: @TContractState) -> PoolInfo;

    /// Calculates the utilization rate of the pool
    fn calculate_utilization_rate(self: @TContractState) -> u256;

    /// Calculates the current borrow AP
    fn calculate_borrow_apr(self: @TContractState) -> u256;

    /// Calculates the current supply APY
    fn calculate_supply_apy(self: @TContractState) -> u256;

    /// Increases a user's LP token balance
    fn add_user_lp_owned(ref self: TContractState, user: ContractAddress, amount: u256);

    /// Decreases a user's LP token balance
    fn subtract_user_lp_owned(ref self: TContractState, user: ContractAddress, amount: u256);

    /// Increases total supply
    fn add_total_supply(ref self: TContractState, amount: u256);

    /// Decreases total supply
    fn subtract_total_supply(ref self: TContractState, amount: u256);

    /// Increases total borrowed amount
    fn add_total_borrow(ref self: TContractState, amount: u256);

    /// Decreases total borrowed amount
    fn subtract_total_borrow(ref self: TContractState, amount: u256);

    /// Adds a new borrow position for a user
    fn add_user_borrow_info(
        ref self: TContractState, user: ContractAddress, _user_borrow_info: UserBorrowInfo,
    );

    /// Removes a borrow position after repayment or liquidation
    fn remove_borrow_info(ref self: TContractState, user: ContractAddress, borrow_id: u256);

    /// Increases expected yearly interest
    fn add_expected_interest_amount_per_year(ref self: TContractState, amount: u256);

    /// Increases actual accrued interest
    fn add_actual_interest_amount(ref self: TContractState, amount: u256);

    /// Approves token transfer for pool operations
    fn approve_transfer(ref self: TContractState, token: ContractAddress, amount: u256);
}

/// LP token contract's interface (ERC20)
#[starknet::interface]
pub trait ILPToken<TContractState> {
    fn total_supply(self: @TContractState) -> u256;
    fn balance_of(self: @TContractState, account: ContractAddress) -> u256;
    fn allowance(self: @TContractState, owner: ContractAddress, spender: ContractAddress) -> u256;
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn transfer_from(
        ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256,
    ) -> bool;
    fn approve(ref self: TContractState, spender: ContractAddress, amount: u256) -> bool;
    fn name(self: @TContractState) -> ByteArray;
    fn symbol(self: @TContractState) -> ByteArray;
    fn decimals(self: @TContractState) -> u8;
    fn totalSupply(self: @TContractState) -> u256;
    fn balanceOf(self: @TContractState, account: ContractAddress) -> u256;
    fn transferFrom(
        ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256,
    ) -> bool;
    fn mint(ref self: TContractState, recipient: ContractAddress, amount: u256);
    fn burn(ref self: TContractState, account: ContractAddress, amount: u256);
}

/// Chainlink aggregator contract's interface
#[starknet::interface]
pub trait IAggregator<TContractState> {
    fn latest_round_data(self: @TContractState) -> Round;
    fn round_data(self: @TContractState, round_id: u128) -> Round;
    fn description(self: @TContractState) -> felt252;
    fn decimals(self: @TContractState) -> u8;
    fn latest_answer(self: @TContractState) -> u128;
}
