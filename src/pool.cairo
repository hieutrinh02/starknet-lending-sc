#[starknet::contract]
pub mod Pool {
    // External imports
    use core::num::traits::zero::Zero;
    use core::poseidon::poseidon_hash_span;
    use openzeppelin::token::erc20::interface::{
        IERC20Dispatcher, IERC20DispatcherTrait, IERC20MetadataDispatcher,
        IERC20MetadataDispatcherTrait,
    };
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::syscalls::deploy_syscall;
    #[feature("deprecated-starknet-consts")]
    use starknet::{
        ClassHash, ContractAddress, SyscallResultTrait, contract_address_const, get_caller_address,
        get_contract_address,
    };

    // Internal imports
    use starknet_lending_sc::{
        constants::{
            BASE_INTEREST_RATE, OPTIMAL_UTILIZATION_RATE, RSLOPE_1, RSLOPE_2, ten_pow_decimals,
        },
        errors::Error, interfaces::{IPool, LPTokenDeployData, PoolInfo, UserBorrowInfo},
    };

    // Storage
    #[storage]
    struct Storage {
        pub market_contract: ContractAddress,
        pub token: ContractAddress,
        pub collateral_token: ContractAddress,
        pub lp_token: ContractAddress,
        total_supply: u256,
        total_borrow: u256,
        user_to_lp_owned: Map<ContractAddress, u256>,
        user_borrow_quantity: Map<ContractAddress, u256>,
        user_borrow_info: Map<ContractAddress, Map<u256, UserBorrowInfo>>,
        active_borrower: Map<u256, ContractAddress>,
        active_borrower_num: u256,
        active_borrower_index: Map<ContractAddress, u256>,
        expected_interest_amount_per_year: u256,
        actual_interest_amount: u256,
    }

    // Constructor
    #[constructor]
    fn constructor(
        ref self: ContractState,
        _token: ContractAddress,
        _collateral_token: ContractAddress,
        lp_token_class_hash: ClassHash,
        _market_contract: ContractAddress,
    ) {
        // Prepare LP token deploy data
        let token_symbol = IERC20MetadataDispatcher { contract_address: _token }.symbol();
        let collateral_token_symbol = IERC20MetadataDispatcher {
            contract_address: _collateral_token,
        }
            .symbol();
        let lp_token_symbol = "LP-" + token_symbol + "/" + collateral_token_symbol;
        let lp_token_name = lp_token_symbol.clone();
        let mut hash_data: Array<felt252> = array![];
        let mut calldata: Array<felt252> = array![];
        let mut deploy_data = LPTokenDeployData {
            name: lp_token_name,
            symbol: lp_token_symbol,
            _market_contract: _market_contract,
            _pool: get_contract_address(),
        };
        Serde::serialize(@deploy_data, ref hash_data);
        let salt = poseidon_hash_span(hash_data.span());
        Serde::serialize(@deploy_data, ref calldata);
        let deploy_from_zero: bool = false;

        // Deploy
        let (_lp_token, _) = deploy_syscall(
            lp_token_class_hash, salt, calldata.span(), deploy_from_zero,
        )
            .unwrap_syscall();

        // Write to storage
        self.market_contract.write(_market_contract);
        self.token.write(_token);
        self.collateral_token.write(_collateral_token);
        self.lp_token.write(_lp_token);
    }

    // External
    #[abi(embed_v0)]
    impl PoolImpl of IPool<ContractState> {
        // See IPool-get_token_name
        fn get_token_name(self: @ContractState) -> ByteArray {
            // Call & return
            IERC20MetadataDispatcher { contract_address: self.token.read() }.name()
        }

        // See IPool-get_collateral_token_name
        fn get_collateral_token_name(self: @ContractState) -> ByteArray {
            // Call & return
            IERC20MetadataDispatcher { contract_address: self.collateral_token.read() }.name()
        }

        // See IPool-get_token_symbol
        fn get_token_symbol(self: @ContractState) -> ByteArray {
            // Call & return
            IERC20MetadataDispatcher { contract_address: self.token.read() }.symbol()
        }

        // See IPool-get_collateral_token_symbol
        fn get_collateral_token_symbol(self: @ContractState) -> ByteArray {
            // Call & return
            IERC20MetadataDispatcher { contract_address: self.collateral_token.read() }.symbol()
        }

        // See IPool-get_total_supply
        fn get_total_supply(self: @ContractState) -> u256 {
            // Return
            self.total_supply.read()
        }

        // See IPool-get_total_borrow
        fn get_total_borrow(self: @ContractState) -> u256 {
            // Return
            self.total_borrow.read()
        }

        // See IPool-get_lp_token_address
        fn get_lp_token_address(self: @ContractState) -> ContractAddress {
            // Return
            self.lp_token.read()
        }

        // See IPool-get_user_to_lp_owned
        fn get_user_to_lp_owned(self: @ContractState, user: ContractAddress) -> u256 {
            // Check user
            assert(user.is_non_zero(), Error::INVALID_ADDRESS);

            // Return
            self.user_to_lp_owned.entry(user).read()
        }

        // See IPool-get_user_borrow_quantity
        fn get_user_borrow_quantity(self: @ContractState, user: ContractAddress) -> u256 {
            // Check user
            assert(user.is_non_zero(), Error::INVALID_ADDRESS);

            // Return
            self.user_borrow_quantity.entry(user).read()
        }

        // See IPool-get_user_borrow_info
        fn get_user_borrow_info(
            self: @ContractState, user: ContractAddress, borrow_id: u256,
        ) -> UserBorrowInfo {
            // Check borrow id
            let user_borrow_quantity = self.get_user_borrow_quantity(user);
            assert(borrow_id < user_borrow_quantity, Error::INVALID_BORROW_ID);

            // Return
            self.user_borrow_info.entry(user).entry(borrow_id).read()
        }

        // See IPool-get_active_borrower_num
        fn get_active_borrower_num(self: @ContractState) -> u256 {
            // Return
            self.active_borrower_num.read()
        }

        // See IPool-get_active_borrower_index
        fn get_active_borrower_index(self: @ContractState, borrower: ContractAddress) -> u256 {
            // Check borrower
            assert(borrower.is_non_zero(), Error::INVALID_ADDRESS);
            let index = self.active_borrower_index.entry(borrower).read();
            if (index == 0) {
                assert(
                    self.active_borrower.entry(0).read() == borrower, Error::BORROWER_NOT_EXISTS,
                );
            }

            // Return
            index
        }

        // See IPool-get_active_borrower
        fn get_active_borrower(self: @ContractState, index: u256) -> ContractAddress {
            // Check index
            let borrower = self.active_borrower.entry(index).read();
            assert(borrower.is_non_zero(), Error::INVALID_INDEX);

            // Return
            borrower
        }

        // See IPool-get_expected_interest_amount_per_year
        fn get_expected_interest_amount_per_year(self: @ContractState) -> u256 {
            // Return
            self.expected_interest_amount_per_year.read()
        }

        // See IPool-get_actual_interest_amount
        fn get_actual_interest_amount(self: @ContractState) -> u256 {
            // Return
            self.actual_interest_amount.read()
        }

        // See IPool-get_pool_info
        fn get_pool_info(self: @ContractState) -> PoolInfo {
            // Fetch pool info
            let token_symbol = self.get_token_symbol();
            let collateral_token_symbol = self.get_collateral_token_symbol();
            let pool = token_symbol + "/" + collateral_token_symbol;

            // Fetch total borrow
            let total_borrow = self.get_total_borrow();

            // Fetch total supply
            let total_supply = self.get_total_supply();

            // Calculate utilization rate (UR)
            let mut ur = 0;
            if (total_supply.is_non_zero()) {
                ur = total_borrow
                    * ten_pow_decimals().into()
                    * ten_pow_decimals().into()
                    / total_supply;
            }

            // Calculate borrow APR
            let mut borrow_apr: u256 = BASE_INTEREST_RATE.into() * ten_pow_decimals().into();
            if (ur <= OPTIMAL_UTILIZATION_RATE.into() * ten_pow_decimals().into()) {
                let low_charge: u256 = RSLOPE_1.into() * ur / ten_pow_decimals().into();
                borrow_apr += low_charge;
            } else {
                let high_charge: u256 = RSLOPE_1.into() * OPTIMAL_UTILIZATION_RATE.into()
                    + RSLOPE_2.into()
                        * ((ur - (OPTIMAL_UTILIZATION_RATE.into() * ten_pow_decimals().into()))
                            / ten_pow_decimals().into());
                borrow_apr += high_charge;
            }

            // Calculate supply APY
            let mut supply_apy = 0;
            if (total_supply.is_non_zero()) {
                supply_apy = self.get_expected_interest_amount_per_year()
                    * ten_pow_decimals().into()
                    * ten_pow_decimals().into()
                    / (total_supply - self.get_actual_interest_amount())
            }

            // Return
            PoolInfo { pool, total_borrow, total_supply, ur, borrow_apr, supply_apy }
        }

        // See IPool-calculate_utilization_rate
        fn calculate_utilization_rate(self: @ContractState) -> u256 {
            // Calculate utilization rate (UR)
            let mut ur: u256 = 0;
            let total_supply = self.get_total_supply();
            if (total_supply.is_non_zero()) {
                ur = self.get_total_borrow()
                    * ten_pow_decimals().into()
                    * ten_pow_decimals().into()
                    / total_supply;
            }

            // Return
            ur
        }

        // See IPool-calculate_borrow_apr
        fn calculate_borrow_apr(self: @ContractState) -> u256 {
            // Calculate borrow APR
            let ur = self.calculate_utilization_rate();
            let mut borrow_apr: u256 = BASE_INTEREST_RATE.into() * ten_pow_decimals().into();
            if (ur <= OPTIMAL_UTILIZATION_RATE.into() * ten_pow_decimals().into()) {
                let low_charge: u256 = RSLOPE_1.into() * ur / ten_pow_decimals().into();
                borrow_apr += low_charge;
            } else {
                let high_charge: u256 = RSLOPE_1.into() * OPTIMAL_UTILIZATION_RATE.into()
                    + RSLOPE_2.into()
                        * ((ur - (OPTIMAL_UTILIZATION_RATE.into() * ten_pow_decimals().into()))
                            / ten_pow_decimals().into());
                borrow_apr += high_charge;
            }

            // Return
            borrow_apr
        }

        // See IPool-calculate_supply_apy
        fn calculate_supply_apy(self: @ContractState) -> u256 {
            // Calculate supply APY
            let mut supply_apy: u256 = 0;
            let total_supply = self.get_total_supply();
            if (total_supply.is_non_zero()) {
                supply_apy = self.get_expected_interest_amount_per_year()
                    * ten_pow_decimals().into()
                    * ten_pow_decimals().into()
                    / (total_supply - self.get_actual_interest_amount());
            }

            // Return
            supply_apy
        }

        // See IPool-add_user_lp_owned
        fn add_user_lp_owned(ref self: ContractState, user: ContractAddress, amount: u256) {
            // Check caller
            let caller = get_caller_address();
            assert(
                caller == self.market_contract.read() || caller == self.lp_token.read(),
                Error::NOT_MARKET_OR_LP_CONTRACT,
            );

            // Write to storage
            self
                .user_to_lp_owned
                .entry(user)
                .write(self.user_to_lp_owned.entry(user).read() + amount);
        }

        // See IPool-subtract_user_lp_owned
        fn subtract_user_lp_owned(ref self: ContractState, user: ContractAddress, amount: u256) {
            // Check caller
            let caller = get_caller_address();
            assert(
                caller == self.market_contract.read() || caller == self.lp_token.read(),
                Error::NOT_MARKET_OR_LP_CONTRACT,
            );

            // Write to storage
            self
                .user_to_lp_owned
                .entry(user)
                .write(self.user_to_lp_owned.entry(user).read() - amount);
        }

        // See IPool-add_total_supply
        fn add_total_supply(ref self: ContractState, amount: u256) {
            // Check caller
            assert(get_caller_address() == self.market_contract.read(), Error::NOT_MARKET_CONTRACT);

            // Write to storage
            self.total_supply.write(self.total_supply.read() + amount);
        }

        // See IPool-subtract_total_supply
        fn subtract_total_supply(ref self: ContractState, amount: u256) {
            // Check caller
            assert(get_caller_address() == self.market_contract.read(), Error::NOT_MARKET_CONTRACT);

            // Write to storage
            self.total_supply.write(self.total_supply.read() - amount);
        }

        // See IPool-add_total_borrow
        fn add_total_borrow(ref self: ContractState, amount: u256) {
            // Check caller
            assert(get_caller_address() == self.market_contract.read(), Error::NOT_MARKET_CONTRACT);

            // Write to storage
            self.total_borrow.write(self.total_borrow.read() + amount);
        }

        // See IPool-subtract_total_borrow
        fn subtract_total_borrow(ref self: ContractState, amount: u256) {
            // Check caller
            assert(get_caller_address() == self.market_contract.read(), Error::NOT_MARKET_CONTRACT);

            // Write to storage
            self.total_borrow.write(self.total_borrow.read() - amount);
        }

        // See IPool-add_user_borrow_info
        fn add_user_borrow_info(
            ref self: ContractState, user: ContractAddress, _user_borrow_info: UserBorrowInfo,
        ) {
            // Check caller
            assert(get_caller_address() == self.market_contract.read(), Error::NOT_MARKET_CONTRACT);

            // Get borrow id
            let borrow_id = self.user_borrow_quantity.entry(user).read();

            // Add user borrow info
            self.user_borrow_info.entry(user).entry(borrow_id).write(_user_borrow_info);

            // Update user borrow quantity
            self.user_borrow_quantity.entry(user).write(borrow_id + 1);

            // Add to active borrower
            if (borrow_id == 0) {
                let active_borrower_num = self.active_borrower_num.read();
                self.active_borrower.entry(active_borrower_num).write(user);
                self.active_borrower_index.entry(user).write(active_borrower_num);
                self.active_borrower_num.write(active_borrower_num + 1);
            }
        }

        // See IPool-remove_borrow_info
        fn remove_borrow_info(ref self: ContractState, user: ContractAddress, borrow_id: u256) {
            // Check caller
            assert(get_caller_address() == self.market_contract.read(), Error::NOT_MARKET_CONTRACT);

            // Remove borrow info
            let default_user_borrow_info = UserBorrowInfo {
                borrow_amount: Default::default(),
                collateral_amount: Default::default(),
                hf: Default::default(),
                borrow_apr: Default::default(),
                borrow_start_time: Default::default(),
            };
            let final_index = self.get_user_borrow_quantity(user) - 1;
            if (borrow_id < final_index) {
                let final_index_borrow_info = self
                    .user_borrow_info
                    .entry(user)
                    .entry(final_index)
                    .read();
                self.user_borrow_info.entry(user).entry(borrow_id).write(final_index_borrow_info);
            }
            self.user_borrow_info.entry(user).entry(final_index).write(default_user_borrow_info);

            // Update user borrow quantity
            self.user_borrow_quantity.entry(user).write(final_index);

            // Remove from active borrower
            if (final_index == 0) {
                let active_borrower_index = self.active_borrower_index.entry(user).read();
                let active_borrower_final_index = self.active_borrower_num.read() - 1;
                if (active_borrower_index < active_borrower_final_index) {
                    let final_index_borrower = self
                        .active_borrower
                        .entry(active_borrower_final_index)
                        .read();
                    self.active_borrower.entry(active_borrower_index).write(final_index_borrower);
                    self
                        .active_borrower_index
                        .entry(final_index_borrower)
                        .write(active_borrower_index);
                }
                self
                    .active_borrower
                    .entry(active_borrower_final_index)
                    .write(contract_address_const::<0>());
                self.active_borrower_index.entry(user).write(0);
                self.active_borrower_num.write(active_borrower_final_index);
            }
        }

        // See IPool-add_expect_interest_amount_per_year
        fn add_expected_interest_amount_per_year(ref self: ContractState, amount: u256) {
            // Check caller
            assert(get_caller_address() == self.market_contract.read(), Error::NOT_MARKET_CONTRACT);

            // Write to storage
            self
                .expected_interest_amount_per_year
                .write(self.expected_interest_amount_per_year.read() + amount);
        }

        // See IPool-add_actual_interest_amount
        fn add_actual_interest_amount(ref self: ContractState, amount: u256) {
            // Check caller
            assert(get_caller_address() == self.market_contract.read(), Error::NOT_MARKET_CONTRACT);

            // Write to storage
            self.actual_interest_amount.write(self.actual_interest_amount.read() + amount);
        }

        // See IPool-approve_transfer
        fn approve_transfer(ref self: ContractState, token: ContractAddress, amount: u256) {
            // Check caller
            let market_contract = self.market_contract.read();
            assert(get_caller_address() == market_contract, Error::NOT_MARKET_CONTRACT);

            // Approve market contract to spend tokens
            assert(
                IERC20Dispatcher { contract_address: token }.approve(market_contract, amount),
                Error::FAILED_APPROVAL,
            );
        }
    }
}
