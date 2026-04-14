#[starknet::contract]
pub mod LPToken {
    // External imports
    use core::num::traits::Zero;
    use openzeppelin::token::erc20::{DefaultConfig as ERC20DefaultConfig, ERC20Component};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_caller_address};

    // Internal imports
    use starknet_lending_sc::{errors::Error, interfaces::{IPoolDispatcher, IPoolDispatcherTrait}};

    // Component
    component!(path: ERC20Component, storage: erc20, event: ERC20Event);

    // External
    #[abi(embed_v0)]
    impl ERC20MixinImpl = ERC20Component::ERC20MixinImpl<ContractState>;
    // Internal
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    // Storage
    #[storage]
    pub struct Storage {
        #[substorage(v0)]
        pub erc20: ERC20Component::Storage,
        pub market_contract: ContractAddress,
        pub pool: ContractAddress,
    }

    // Event
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event,
    }

    // Constructor
    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: ByteArray,
        symbol: ByteArray,
        _market_contract: ContractAddress,
        _pool: ContractAddress,
    ) {
        self.erc20.initializer(name, symbol);
        self.market_contract.write(_market_contract);
        self.pool.write(_pool);
    }

    // External
    #[generate_trait]
    #[abi(per_item)]
    impl ExternalImpl of ExternalTrait {
        #[external(v0)]
        fn mint(ref self: ContractState, recipient: ContractAddress, amount: u256) {
            // Check caller
            assert(get_caller_address() == self.market_contract.read(), Error::NOT_MARKET_CONTRACT);

            // Mint
            self.erc20.mint(recipient, amount);
        }

        #[external(v0)]
        fn burn(ref self: ContractState, account: ContractAddress, amount: u256) {
            // Check caller
            assert(get_caller_address() == self.market_contract.read(), Error::NOT_MARKET_CONTRACT);

            // Burn
            self.erc20.burn(account, amount);
        }
    }

    // Internal
    impl ERC20HooksImpl of ERC20Component::ERC20HooksTrait<ContractState> {
        fn before_update(
            ref self: ERC20Component::ComponentState<ContractState>,
            from: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) {
            if (from != Zero::zero() && recipient != Zero::zero()) {
                let contract_state = self.get_contract();
                let pool_dispatcher = IPoolDispatcher {
                    contract_address: contract_state.pool.read(),
                };

                // Subtract sender LP owned
                pool_dispatcher.subtract_user_lp_owned(from, amount);

                // Add receiver LP owned
                pool_dispatcher.add_user_lp_owned(recipient, amount);
            }
        }
    }
}
