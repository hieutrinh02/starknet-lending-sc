#[starknet::contract]
pub mod Market {
    // External imports
    use core::num::traits::zero::Zero;
    use core::poseidon::poseidon_hash_span;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::syscalls::deploy_syscall;
    use starknet::{
        ClassHash, ContractAddress, SyscallResultTrait, get_block_timestamp, get_caller_address,
        get_contract_address,
    };

    // Internal imports
    use starknet_lending_sc::{
        constants::{
            BASE_INTEREST_RATE, BORROW_LIMIT, MIN_HF_WITH_DECIMALS, OPTIMAL_UTILIZATION_RATE,
            RSLOPE_1, RSLOPE_2, THRESHOLD_LIQUIDATION, UPPER_LIQUIDATE_HF_WITH_DECIMALS,
            YEAR_TIMESTAMPS, ten_pow_decimals,
        },
        errors::Error,
        interfaces::{
            IAggregatorDispatcher, IAggregatorDispatcherTrait, ILPTokenDispatcher,
            ILPTokenDispatcherTrait, IMarket, IPoolDispatcher, IPoolDispatcherTrait, PoolDeployData,
            UserBorrowInfo,
        },
    };

    // Event
    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        NewPoolDeployed: NewPoolDeployed,
        PriceFeedUpdated: PriceFeedUpdated,
        Supplied: Supplied,
        Withdrew: Withdrew,
        Borrowed: Borrowed,
        Repaid: Repaid,
        Liquidated: Liquidated,
    }

    #[derive(Drop, starknet::Event)]
    pub struct NewPoolDeployed {
        #[key]
        pub token: ContractAddress,
        #[key]
        pub collateral_token: ContractAddress,
        pub pool_address: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PriceFeedUpdated {
        #[key]
        pub token: ContractAddress,
        pub feed_address: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Supplied {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub token: ContractAddress,
        #[key]
        pub collateral_token: ContractAddress,
        pub supply_amount: u256,
        pub lp_token_mint: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Withdrew {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub token: ContractAddress,
        #[key]
        pub collateral_token: ContractAddress,
        pub lp_amount_withdraw: u256,
        pub token_withdraw_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Borrowed {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub borrow_token: ContractAddress,
        #[key]
        pub collateral_token: ContractAddress,
        pub borrow_amount: u256,
        pub collateral_amount: u256,
        pub borrow_id: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Repaid {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub repay_token: ContractAddress,
        #[key]
        pub collateral_token: ContractAddress,
        pub borrow_id: u256,
        pub interest_amount: u256,
        pub total_repay_amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Liquidated {
        #[key]
        pub borrower: ContractAddress,
        #[key]
        pub repay_token: ContractAddress,
        #[key]
        pub collateral_token: ContractAddress,
        #[key]
        pub borrow_id: u256,
        pub caller: ContractAddress,
        pub interest_amount: u256,
        pub total_repay_amount: u256,
    }

    // Storage
    #[storage]
    struct Storage {
        pub owner: ContractAddress,
        pools: Map<
            ContractAddress, Map<ContractAddress, ContractAddress>,
        >, // Token => Collateral Token => Pool
        pub pool_class_hash: ClassHash,
        pub lp_token_class_hash: ClassHash,
        pub chainlink_price_feed_address: Map<ContractAddress, ContractAddress> // Token => Feed
    }

    // Constructor
    #[constructor]
    fn constructor(
        ref self: ContractState,
        _owner: ContractAddress,
        _pool_class_hash: ClassHash,
        _lp_token_class_hash: ClassHash,
        _chainlink_price_feed_tokens: Span<ContractAddress>,
        _chainlink_price_feed_addresses: Span<ContractAddress>,
    ) {
        // Write to storage
        self.owner.write(_owner);
        self.pool_class_hash.write(_pool_class_hash);
        self.lp_token_class_hash.write(_lp_token_class_hash);
        let mut i = 0;
        let price_feed_len = _chainlink_price_feed_tokens.len();
        while (i < price_feed_len) {
            self
                .chainlink_price_feed_address
                .entry(*_chainlink_price_feed_tokens.at(i))
                .write(*_chainlink_price_feed_addresses.at(i));
            i += 1;
        }
    }

    // External
    #[abi(embed_v0)]
    impl MarketImpl of IMarket<ContractState> {
        // See IMarket-get_price_usd
        fn get_price_usd(self: @ContractState, token: ContractAddress) -> (u128, u8) {
            // Check feed address
            let chainlink_price_feed_address = self
                .chainlink_price_feed_address
                .entry(token)
                .read();
            assert(chainlink_price_feed_address.is_non_zero(), Error::UNKNOWN_TOKEN_ADDRESS);

            // Get prices info
            let aggregator_dispatcher = IAggregatorDispatcher {
                contract_address: chainlink_price_feed_address,
            };
            let latest_round_data_answer = aggregator_dispatcher.latest_round_data().answer;
            let decimals = aggregator_dispatcher.decimals();

            // Return
            (latest_round_data_answer, decimals)
        }

        // See IMarket-get_pools
        fn get_pools(
            self: @ContractState, token: ContractAddress, collateral_token: ContractAddress,
        ) -> ContractAddress {
            // Check pool address
            let pool_address = self.pools.entry(token).entry(collateral_token).read();
            assert(pool_address.is_non_zero(), Error::POOL_NOT_EXIST);

            // Return
            pool_address
        }

        // See IMarket-deploy_new_pool
        fn deploy_new_pool(
            ref self: ContractState, token: ContractAddress, collateral_token: ContractAddress,
        ) {
            // Check caller
            assert(get_caller_address() == self.owner.read(), Error::NOT_OWNER);

            // Check pool existance
            assert(
                self.pools.entry(token).entry(collateral_token).read().is_zero(),
                Error::POOL_ALREADY_EXISTED,
            );

            // Prepare deploy data
            let mut hash_data: Array<felt252> = array![];
            let mut calldata: Array<felt252> = array![];
            let mut deploy_data = PoolDeployData {
                _token: token,
                _collateral_token: collateral_token,
                lp_token_class_hash: self.lp_token_class_hash.read(),
                _market_contract: get_contract_address(),
            };
            Serde::serialize(@deploy_data, ref hash_data);
            let salt = poseidon_hash_span(hash_data.span());
            Serde::serialize(@deploy_data, ref calldata);
            let deploy_from_zero: bool = false;

            // Deploy
            let (_pool_address, _) = deploy_syscall(
                self.pool_class_hash.read(), salt, calldata.span(), deploy_from_zero,
            )
                .unwrap_syscall();

            // Write to storage
            self.pools.entry(token).entry(collateral_token).write(_pool_address);

            // Emit event
            self
                .emit(
                    Event::NewPoolDeployed(
                        NewPoolDeployed { token, collateral_token, pool_address: _pool_address },
                    ),
                );
        }

        // See IMarket-update_price_feed_address
        fn update_price_feed_address(
            ref self: ContractState,
            _chainlink_price_feed_token: ContractAddress,
            _chainlink_price_feed_address: ContractAddress,
        ) {
            // Check caller
            assert(get_caller_address() == self.owner.read(), Error::NOT_OWNER);

            // Check token
            assert(_chainlink_price_feed_token.is_non_zero(), Error::INVALID_TOKEN_ADDRESS);

            // Write to storage
            self
                .chainlink_price_feed_address
                .entry(_chainlink_price_feed_token)
                .write(_chainlink_price_feed_address);

            // Emit event
            self
                .emit(
                    Event::PriceFeedUpdated(
                        PriceFeedUpdated {
                            token: _chainlink_price_feed_token,
                            feed_address: _chainlink_price_feed_address,
                        },
                    ),
                );
        }

        // See IMarket-supply
        fn supply(
            ref self: ContractState,
            token: ContractAddress,
            collateral: ContractAddress,
            supply_amount: u256,
        ) {
            let caller = get_caller_address();
            let market_contract = get_contract_address();

            // Check inputs
            assert(token.is_non_zero(), Error::INVALID_TOKEN_ADDRESS);
            assert(collateral.is_non_zero(), Error::INVALID_COLLATERAL_ADDRESS);
            assert(supply_amount > 0, Error::INVALID_AMOUNT);

            // Check pool address
            let pool_address = self.pools.entry(token).entry(collateral).read();
            assert(pool_address.is_non_zero(), Error::POOL_NOT_EXIST);

            // Check user has enough balance
            let token_dispatcher = IERC20Dispatcher { contract_address: token };
            assert(
                token_dispatcher.balance_of(caller) >= supply_amount,
                Error::NOT_ENOUGH_BALANCE_TO_SUPPLY,
            );

            // Check user has enough allowance
            assert(
                token_dispatcher.allowance(caller, market_contract) >= supply_amount,
                Error::NOT_ENOUGH_ALLOWANCE,
            );

            // Transfer token from user to pool
            assert(
                token_dispatcher.transfer_from(caller, pool_address, supply_amount),
                Error::FAILED_TRANSFER,
            );

            // Mint LP token to user
            let pool_dispatcher = IPoolDispatcher { contract_address: pool_address };
            let lp_token_address = pool_dispatcher.get_lp_token_address();
            let pool_total_supply = pool_dispatcher.get_total_supply();
            let lp_token_dispatcher = ILPTokenDispatcher { contract_address: lp_token_address };
            let mut lp_token_mint = 0; // Calculate LP token to mint
            if (pool_total_supply == 0) { // If this is the first supply
                lp_token_mint = supply_amount;
            } else { // Normal case
                lp_token_mint = supply_amount
                    * lp_token_dispatcher.total_supply()
                    / pool_total_supply;
            }
            lp_token_dispatcher.mint(caller, lp_token_mint);

            // Add user LP token owned
            pool_dispatcher.add_user_lp_owned(caller, lp_token_mint);

            // Add pool token total supply
            pool_dispatcher.add_total_supply(supply_amount);

            // Emit event
            self
                .emit(
                    Event::Supplied(
                        Supplied {
                            user: caller,
                            token,
                            collateral_token: collateral,
                            supply_amount,
                            lp_token_mint,
                        },
                    ),
                );
        }

        // See IMarket-withdraw
        fn withdraw(
            ref self: ContractState,
            token: ContractAddress,
            collateral: ContractAddress,
            lp_amount_withdraw: u256,
        ) {
            let caller = get_caller_address();

            // Check inputs
            assert(token.is_non_zero(), Error::INVALID_TOKEN_ADDRESS);
            assert(collateral.is_non_zero(), Error::INVALID_COLLATERAL_ADDRESS);
            assert(lp_amount_withdraw > 0, Error::INVALID_AMOUNT);

            // Check pool address
            let pool_address = self.pools.entry(token).entry(collateral).read();
            assert(pool_address.is_non_zero(), Error::POOL_NOT_EXIST);

            // Check LP token amount
            let pool_dispatcher = IPoolDispatcher { contract_address: pool_address };
            let lp_amount_avail = pool_dispatcher.get_user_to_lp_owned(caller);
            assert(lp_amount_withdraw <= lp_amount_avail, Error::INVALID_AMOUNT);

            // Check user has enough LP token balance
            let lp_token_address = pool_dispatcher.get_lp_token_address();
            let lp_token_dispatcher = ILPTokenDispatcher { contract_address: lp_token_address };
            assert(
                lp_token_dispatcher.balance_of(caller) >= lp_amount_withdraw,
                Error::NOT_ENOUGH_LP_TOKEN_AMOUNT,
            );

            // Transfer token from pool to user
            let token_withdraw_amount = lp_amount_withdraw
                * (pool_dispatcher.get_total_supply())
                / lp_token_dispatcher.total_supply();
            pool_dispatcher.approve_transfer(token, token_withdraw_amount);
            assert(
                IERC20Dispatcher { contract_address: token }
                    .transfer_from(pool_address, caller, token_withdraw_amount),
                Error::FAILED_TRANSFER,
            );

            // Burn LP token from user
            lp_token_dispatcher.burn(caller, lp_amount_withdraw);

            // Subtract user LP token owned
            pool_dispatcher.subtract_user_lp_owned(caller, lp_amount_withdraw);

            // Subtract pool token total supply
            pool_dispatcher.subtract_total_supply(token_withdraw_amount);

            // Emit event
            self
                .emit(
                    Event::Withdrew(
                        Withdrew {
                            user: caller,
                            token,
                            collateral_token: collateral,
                            lp_amount_withdraw,
                            token_withdraw_amount,
                        },
                    ),
                );
        }

        // See IMarket-borrow
        fn borrow(
            ref self: ContractState,
            borrow_token: ContractAddress,
            borrow_amount: u256,
            collateral_token: ContractAddress,
            collateral_amount: u256,
        ) {
            let caller = get_caller_address();
            let market_contract = get_contract_address();
            let cur_timestamp = get_block_timestamp();

            // Check inputs
            assert(borrow_token.is_non_zero(), Error::INVALID_TOKEN_ADDRESS);
            assert(collateral_token.is_non_zero(), Error::INVALID_COLLATERAL_ADDRESS);
            assert(borrow_amount > 0 && collateral_amount > 0, Error::INVALID_AMOUNT);

            // Check pool address
            let pool_address = self.pools.entry(borrow_token).entry(collateral_token).read();
            assert(pool_address.is_non_zero(), Error::POOL_NOT_EXIST);

            // Check user has enough collateral balance
            let collateral_token_dispatcher = IERC20Dispatcher {
                contract_address: collateral_token,
            };
            assert(
                collateral_token_dispatcher.balance_of(caller) >= collateral_amount,
                Error::NOT_ENOUGH_COLLATERAL_BALANCE,
            );

            // Check user has enough collateral allowance
            assert(
                collateral_token_dispatcher.allowance(caller, market_contract) >= collateral_amount,
                Error::NOT_ENOUGH_ALLOWANCE,
            );

            // Check pool supply balance
            let pool_dispatcher = IPoolDispatcher { contract_address: pool_address };
            let pool_total_supply = pool_dispatcher.get_total_supply();
            let pool_total_borrow = pool_dispatcher.get_total_borrow();
            assert(
                pool_total_supply > 0 && borrow_amount <= pool_total_supply - pool_total_borrow,
                Error::NOT_ENOUGH_SUPPLY,
            );

            // Check utilization rate (UR), must < 90%
            let current_ur = pool_dispatcher.calculate_utilization_rate();
            assert(
                current_ur / ten_pow_decimals().into() < BORROW_LIMIT.into(),
                Error::EXCEEDS_BORROW_LIMIT,
            );

            // Calculate Health Factor (HF)
            // HF = collateral_amount value / borrow_amount value
            let borrow_token_feed = self.chainlink_price_feed_address.entry(borrow_token).read();
            let collateral_token_feed = self
                .chainlink_price_feed_address
                .entry(collateral_token)
                .read();
            let borrow_token_aggregator_dispatcher = IAggregatorDispatcher {
                contract_address: borrow_token_feed,
            };
            let collateral_token_aggregator_dispatcher = IAggregatorDispatcher {
                contract_address: collateral_token_feed,
            };
            let (borrow_token_price_answer, borrow_token_price_decimals) = (
                borrow_token_aggregator_dispatcher.latest_round_data().answer,
                borrow_token_aggregator_dispatcher.decimals(),
            );
            let (collateral_token_price_answer, collateral_token_price_decimals) = (
                collateral_token_aggregator_dispatcher.latest_round_data().answer,
                collateral_token_aggregator_dispatcher.decimals(),
            );
            let hf = collateral_token_price_answer.into()
                * collateral_amount
                * borrow_token_price_decimals.into()
                * THRESHOLD_LIQUIDATION.into()
                / (borrow_token_price_answer.into()
                    * borrow_amount
                    * collateral_token_price_decimals.into());

            // Check the loan's HF
            // The borrower needs to deposit at least 150% of collateral value equivalent to borrow
            // value
            assert(hf >= MIN_HF_WITH_DECIMALS.into(), Error::UNSECURED_LOAN);

            // Check utilization rate (UR) after loan, must <= 90%
            let new_ur = (pool_total_borrow + borrow_amount)
                * ten_pow_decimals().into()
                * ten_pow_decimals().into()
                / pool_total_supply;
            assert(
                new_ur / ten_pow_decimals().into() <= BORROW_LIMIT.into(),
                Error::EXCEEDS_BORROW_LIMIT,
            );

            // Calculate borrow APR
            let mut borrow_apr: u256 = BASE_INTEREST_RATE.into() * ten_pow_decimals().into();
            if (new_ur <= OPTIMAL_UTILIZATION_RATE.into() * ten_pow_decimals().into()) {
                let low_charge: u256 = RSLOPE_1.into() * new_ur / ten_pow_decimals().into();
                borrow_apr += low_charge;
            } else {
                let high_charge: u256 = RSLOPE_1.into() * OPTIMAL_UTILIZATION_RATE.into()
                    + RSLOPE_2.into()
                        * ((new_ur - (OPTIMAL_UTILIZATION_RATE.into() * ten_pow_decimals().into()))
                            / ten_pow_decimals().into());
                borrow_apr += high_charge;
            }

            // Transfer collateral from user to pool
            assert(
                collateral_token_dispatcher.transfer_from(caller, pool_address, collateral_amount),
                Error::FAILED_TRANSFER,
            );

            // Add user borrow info
            let user_borrow_info = UserBorrowInfo {
                borrow_amount, collateral_amount, hf, borrow_apr, borrow_start_time: cur_timestamp,
            };
            let borrow_id = pool_dispatcher.get_user_borrow_quantity(caller);
            pool_dispatcher.add_user_borrow_info(caller, user_borrow_info);

            // Add expected interest amount per year
            pool_dispatcher
                .add_expected_interest_amount_per_year(
                    (borrow_amount * borrow_apr)
                        / (ten_pow_decimals().into() * ten_pow_decimals().into()),
                );

            // Add pool token total borrow
            pool_dispatcher.add_total_borrow(borrow_amount);

            // Transfer token from pool to user
            pool_dispatcher.approve_transfer(borrow_token, borrow_amount);
            assert(
                IERC20Dispatcher { contract_address: borrow_token }
                    .transfer_from(pool_address, caller, borrow_amount),
                Error::FAILED_TRANSFER,
            );

            // Emit event
            self
                .emit(
                    Event::Borrowed(
                        Borrowed {
                            user: caller,
                            borrow_token,
                            collateral_token: collateral_token,
                            borrow_amount,
                            collateral_amount,
                            borrow_id,
                        },
                    ),
                );
        }

        // See IMarket-repay
        fn repay(
            ref self: ContractState,
            repay_token: ContractAddress,
            collateral_token: ContractAddress,
            borrow_id: u256,
        ) {
            let caller = get_caller_address();
            let market_contract = get_contract_address();
            let cur_timestamp = get_block_timestamp();

            // Check inputs
            assert(repay_token.is_non_zero(), Error::INVALID_TOKEN_ADDRESS);
            assert(collateral_token.is_non_zero(), Error::INVALID_COLLATERAL_ADDRESS);

            // Check pool address
            let pool_address = self.pools.entry(repay_token).entry(collateral_token).read();
            assert(pool_address.is_non_zero(), Error::POOL_NOT_EXIST);

            // Check user borrow quantity
            let pool_dispatcher = IPoolDispatcher { contract_address: pool_address };
            let user_borrow_quantity = pool_dispatcher.get_user_borrow_quantity(caller);
            assert(user_borrow_quantity > 0, Error::HAVENT_BORROW_YET);
            assert(borrow_id < user_borrow_quantity, Error::INVALID_BORROW_ID);

            // Calculate interest amount
            let user_borrow_info = pool_dispatcher.get_user_borrow_info(caller, borrow_id);
            let user_borrow_amount = user_borrow_info.borrow_amount;
            let interest_amount = user_borrow_amount
                * user_borrow_info.borrow_apr
                * (cur_timestamp - user_borrow_info.borrow_start_time).into()
                / (YEAR_TIMESTAMPS.into() * ten_pow_decimals().into() * ten_pow_decimals().into());

            // Check user has enough token balance
            let repay_token_dispatcher = IERC20Dispatcher { contract_address: repay_token };
            let total_repay_amount = user_borrow_amount + interest_amount;
            assert(
                repay_token_dispatcher.balance_of(caller) >= total_repay_amount,
                Error::NOT_ENOUGH_BALANCE_TO_REPAY,
            );

            // Check user has enough token allowance
            assert(
                repay_token_dispatcher.allowance(caller, market_contract) >= total_repay_amount,
                Error::NOT_ENOUGH_ALLOWANCE,
            );

            // Transfer repay token from user to pool
            assert(
                repay_token_dispatcher.transfer_from(caller, pool_address, total_repay_amount),
                Error::FAILED_TRANSFER,
            );

            // Add pool total supply
            pool_dispatcher.add_total_supply(interest_amount);

            // Add actual interest amount
            pool_dispatcher.add_actual_interest_amount(interest_amount);

            // Subtract pool token total borrow
            pool_dispatcher.subtract_total_borrow(user_borrow_amount);

            // Remove user borrow info
            pool_dispatcher.remove_borrow_info(caller, borrow_id);

            // Transfer collateral from pool to user
            let user_collateral_amount = user_borrow_info.collateral_amount;
            pool_dispatcher.approve_transfer(collateral_token, user_collateral_amount);
            assert(
                IERC20Dispatcher { contract_address: collateral_token }
                    .transfer_from(pool_address, caller, user_collateral_amount),
                Error::FAILED_TRANSFER,
            );

            // Emit event
            self
                .emit(
                    Event::Repaid(
                        Repaid {
                            user: caller,
                            repay_token,
                            collateral_token: collateral_token,
                            borrow_id,
                            interest_amount,
                            total_repay_amount,
                        },
                    ),
                );
        }

        // See IMarket-liquidate
        fn liquidate(
            ref self: ContractState,
            repay_token: ContractAddress,
            collateral_token: ContractAddress,
            borrower: ContractAddress,
            borrow_id: u256,
        ) {
            let caller = get_caller_address();
            let market_contract = get_contract_address();
            let cur_timestamp = get_block_timestamp();

            // Check inputs
            assert(repay_token.is_non_zero(), Error::INVALID_TOKEN_ADDRESS);
            assert(collateral_token.is_non_zero(), Error::INVALID_COLLATERAL_ADDRESS);
            assert(borrower.is_non_zero(), Error::INVALID_BORROWER_ADDRESS);
            assert(caller != borrower, Error::CANNOT_SELF_LIQUIDATE);

            // Check pool address
            let pool_address = self.pools.entry(repay_token).entry(collateral_token).read();
            assert(pool_address.is_non_zero(), Error::POOL_NOT_EXIST);

            // Check borrower borrow quantity
            let pool_dispatcher = IPoolDispatcher { contract_address: pool_address };
            let borrower_borrow_quantity = pool_dispatcher.get_user_borrow_quantity(borrower);
            assert(borrower_borrow_quantity > 0, Error::HAVENT_BORROW_YET);
            assert(borrow_id < borrower_borrow_quantity, Error::INVALID_BORROW_ID);

            // Get loan info
            let loan_info = pool_dispatcher.get_user_borrow_info(borrower, borrow_id);
            let borrow_amount = loan_info.borrow_amount;
            let collateral_amount = loan_info.collateral_amount;

            // Check the loan's HF < 1
            let repay_token_feed = self.chainlink_price_feed_address.entry(repay_token).read();
            let collateral_token_feed = self
                .chainlink_price_feed_address
                .entry(collateral_token)
                .read();
            let repay_token_aggregator_dispatcher = IAggregatorDispatcher {
                contract_address: repay_token_feed,
            };
            let collateral_token_aggregator_dispatcher = IAggregatorDispatcher {
                contract_address: collateral_token_feed,
            };
            let (repay_token_price_answer, repay_token_price_decimals) = (
                repay_token_aggregator_dispatcher.latest_round_data().answer,
                repay_token_aggregator_dispatcher.decimals(),
            );
            let (collateral_token_price_answer, collateral_token_price_decimals) = (
                collateral_token_aggregator_dispatcher.latest_round_data().answer,
                collateral_token_aggregator_dispatcher.decimals(),
            );
            let interest_amount = borrow_amount
                * loan_info.borrow_apr
                * (cur_timestamp - loan_info.borrow_start_time).into()
                / (YEAR_TIMESTAMPS.into()
                    * ten_pow_decimals().into()
                    * ten_pow_decimals().into()); // Calculate interest amount
            let hf = collateral_token_price_answer.into()
                * collateral_amount
                * repay_token_price_decimals.into()
                * THRESHOLD_LIQUIDATION.into()
                / (repay_token_price_answer.into()
                    * (borrow_amount + interest_amount)
                    * collateral_token_price_decimals.into());
            assert(hf <= UPPER_LIQUIDATE_HF_WITH_DECIMALS.into(), Error::LIQUIDATE_NOT_ALLOWED);

            // Check caller has enough token balance
            let liquidate_token_dispatcher = IERC20Dispatcher { contract_address: repay_token };
            let total_repay_amount = borrow_amount + interest_amount;
            assert(
                liquidate_token_dispatcher.balance_of(caller) >= total_repay_amount,
                Error::NOT_ENOUGH_BALANCE_TO_REPAY,
            );

            // Check caller has enough token allowance
            assert(
                liquidate_token_dispatcher.allowance(caller, market_contract) >= total_repay_amount,
                Error::NOT_ENOUGH_ALLOWANCE,
            );

            // Transfer repay token from caller to pool
            assert(
                liquidate_token_dispatcher.transfer_from(caller, pool_address, total_repay_amount),
                Error::FAILED_TRANSFER,
            );

            // Add pool total supply
            pool_dispatcher.add_total_supply(interest_amount);

            // Add actual interest amount
            pool_dispatcher.add_actual_interest_amount(interest_amount);

            // Subtract pool token total borrow
            pool_dispatcher.subtract_total_borrow(borrow_amount);

            // Remove user borrow info
            pool_dispatcher.remove_borrow_info(borrower, borrow_id);

            // Transfer collateral from pool to caller
            pool_dispatcher.approve_transfer(collateral_token, collateral_amount);
            assert(
                IERC20Dispatcher { contract_address: collateral_token }
                    .transfer_from(pool_address, caller, collateral_amount),
                Error::FAILED_TRANSFER,
            );

            // Emit event
            self
                .emit(
                    Event::Liquidated(
                        Liquidated {
                            borrower,
                            repay_token,
                            collateral_token,
                            borrow_id,
                            caller,
                            interest_amount,
                            total_repay_amount,
                        },
                    ),
                );
        }
    }
}
