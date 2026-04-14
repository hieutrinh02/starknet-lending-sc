#[starknet::contract]
pub mod MockToken {
    // External imports
    use openzeppelin::token::erc20::{
        DefaultConfig as ERC20DefaultConfig, ERC20Component, ERC20HooksEmptyImpl,
    };
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_caller_address};

    // Internal imports
    use starknet_lending_sc::errors::Error;

    // Component
    component!(path: ERC20Component, storage: erc20, event: ERC20Event);

    // External
    #[abi(embed_v0)]
    impl ERC20MixinImpl = ERC20Component::ERC20MixinImpl<ContractState>;

    // Internal
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    // Storage
    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
        owner: ContractAddress,
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
        ref self: ContractState, name: ByteArray, symbol: ByteArray, _owner: ContractAddress,
    ) {
        self.erc20.initializer(name, symbol);
        self.owner.write(_owner);
    }

    // External
    #[generate_trait]
    #[abi(per_item)]
    impl ExternalImpl of ExternalTrait {
        #[external(v0)]
        fn mint(ref self: ContractState, recipient: ContractAddress, amount: u256) {
            // Check caller
            assert(get_caller_address() == self.owner.read(), Error::NOT_OWNER);

            // Mint
            self.erc20.mint(recipient, amount);
        }

        #[external(v0)]
        fn burn(ref self: ContractState, account: ContractAddress, amount: u256) {
            // Check caller
            assert(get_caller_address() == self.owner.read(), Error::NOT_OWNER);

            // Burn
            self.erc20.burn(account, amount);
        }
    }
}
