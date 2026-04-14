// Structs
#[derive(Copy, Drop, Serde, starknet::Store)]
struct Transmission {
    answer: u128,
    block_num: u64,
    observation_timestamp: u64,
    transmission_timestamp: u64,
}

#[starknet::interface]
pub trait IMockAggregator<TContractState> {
    fn set_latest_round_data(
        ref self: TContractState,
        answer: u128,
        block_num: u64,
        observation_timestamp: u64,
        transmission_timestamp: u64,
    );
}

// Interface
#[starknet::interface]
trait ITypeAndVersion<TContractState> {
    fn type_and_version(self: @TContractState) -> felt252;
}

// Contract
#[starknet::contract]
mod MockAggregator {
    // External imports
    use core::panic_with_felt252;
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    #[feature("deprecated-starknet-consts")]
    use starknet::{ContractAddress, contract_address_const};

    // Internal imports
    use starknet_lending_sc::interfaces::{IAggregator, Round};
    use super::{IMockAggregator, ITypeAndVersion, Transmission};

    // Event
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        NewTransmission: NewTransmission,
    }

    #[derive(Drop, starknet::Event)]
    struct NewTransmission {
        #[key]
        round_id: u128,
        answer: u128,
        #[key]
        transmitter: ContractAddress,
        observation_timestamp: u64,
        observers: felt252,
        observations: Array<u128>,
        juels_per_fee_coin: u128,
        gas_price: u128,
        config_digest: felt252,
        epoch_and_round: u64,
        reimbursement: u128,
    }

    // Storage
    #[storage]
    struct Storage {
        _transmissions: Map<u128, Transmission>,
        _latest_aggregator_round_id: u128,
        _decimals: u8,
    }

    // Constructor
    #[constructor]
    fn constructor(ref self: ContractState, decimals: u8) {
        self._decimals.write(decimals);
    }

    // External
    #[abi(embed_v0)]
    impl MockImpl of IMockAggregator<ContractState> {
        fn set_latest_round_data(
            ref self: ContractState,
            answer: u128,
            block_num: u64,
            observation_timestamp: u64,
            transmission_timestamp: u64,
        ) {
            let new_round_id = self._latest_aggregator_round_id.read() + 1_u128;
            self
                ._transmissions
                .entry(new_round_id)
                .write(
                    Transmission {
                        answer: answer,
                        block_num: block_num,
                        observation_timestamp: observation_timestamp,
                        transmission_timestamp: transmission_timestamp,
                    },
                );

            let mut observations = array![];
            observations.append(2_u128);
            observations.append(3_u128);

            self._latest_aggregator_round_id.write(new_round_id);

            self
                .emit(
                    Event::NewTransmission(
                        NewTransmission {
                            round_id: new_round_id,
                            answer: answer,
                            transmitter: contract_address_const::<42>(),
                            observation_timestamp: observation_timestamp,
                            observers: 3,
                            observations: observations,
                            juels_per_fee_coin: 18_u128,
                            gas_price: 1_u128,
                            config_digest: 777,
                            epoch_and_round: 20_u64,
                            reimbursement: 100_u128,
                        },
                    ),
                );
        }
    }

    #[abi(embed_v0)]
    impl TypeAndVersionImpl of ITypeAndVersion<ContractState> {
        fn type_and_version(self: @ContractState) -> felt252 {
            'mock_aggregator.cairo 2.0.0'
        }
    }

    #[abi(embed_v0)]
    impl Aggregator of IAggregator<ContractState> {
        fn round_data(self: @ContractState, round_id: u128) -> Round {
            panic_with_felt252('unimplemented')
        }

        fn latest_round_data(self: @ContractState) -> Round {
            let latest_round_id = self._latest_aggregator_round_id.read();
            let transmission = self._transmissions.entry(latest_round_id).read();

            Round {
                round_id: latest_round_id.into(),
                answer: transmission.answer,
                block_num: transmission.block_num,
                started_at: transmission.observation_timestamp,
                updated_at: transmission.transmission_timestamp,
            }
        }

        fn decimals(self: @ContractState) -> u8 {
            self._decimals.read()
        }

        fn description(self: @ContractState) -> felt252 {
            'mock'
        }

        fn latest_answer(self: @ContractState) -> u128 {
            let latest_round_id = self._latest_aggregator_round_id.read();
            let transmission = self._transmissions.entry(latest_round_id).read();
            transmission.answer
        }
    }
}
