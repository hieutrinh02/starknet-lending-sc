<h1 align="center">Starknet Lending Smart Contract</h1>

<p align="center">
  <a href="https://github.com/hieutrinh02/starknet-lending-sc/blob/main/LICENSE">
    <img src="https://img.shields.io/badge/License-MIT-green" />
  </a>
  <img src="https://img.shields.io/badge/status-educational-blue" />
  <img src="https://img.shields.io/badge/version-v0.1.0-blue" />
  <img src="https://img.shields.io/badge/Starknet-Cairo-red" />
</p>

## ✨ Overview

This repository contains a lending protocol implementation on Starknet,
built to explore core lending mechanics, interest accrual, and liquidation logic.

The focus of this project is smart contract correctness and security. For read-side indexing and local UI interaction, see [`starknet-lending-indexer`](https://github.com/hieutrinh02/starknet-lending-indexer) and [`starknet-lending-fe`](https://github.com/hieutrinh02/starknet-lending-fe).

## 🌐 Deployed Market Contract

Starknet Sepolia

- Address: `0x014fd1f73829520b97e00bbcdc4d5b3818503f8eaafd88e0ba7129a5d1d4fe9a`
- Explorer: https://sepolia.voyager.online/contract/0x014fd1f73829520b97e00bbcdc4d5b3818503f8eaafd88e0ba7129a5d1d4fe9a

## 📄 High-level protocol design

<p align="center">
  <img src="assets/high_level_protocol_design.png" alt="High-level protocol design" width="500">
</p>

### Design highlights

- Market: User-facing entry point
- Pool: Liquidity, borrowing state & interest calculations
- LPToken (ERC20): Represents liquidity provider ownership, has a 1 : 1 relationship with its Pool
- Price Oracle (Chainlink): Provides reliable on-chain asset prices for collateral valuation and liquidation checks

## 🚀 Features

- Supply: Deposit assets into the pool and receive LP tokens representing pool ownership.
- Withdraw: Burn LP tokens to withdraw supplied assets plus accrued interest.
- Borrow: Borrow assets by locking collateral and creating a unique borrow position.
- Repay: Fully repay an active borrow position (principal + accrued interest) to close it.
- Liquidate: Liquidate under-collateralized borrow positions to maintain protocol solvency.

## 🔐 Invariants

The protocol is designed and tested against the following core invariants:

- Pool solvency: Total borrowed amount must always be smaller than or equal to 90% of total supplied liquidity plus accrued interest.
- Collateralization ratio: When a user borrows, the value of their collateral must be at least 150% of the borrowed value, based on oracle prices.
- Borrow positions: A borrow position must be fully repaid or liquidated to be closed.
- Collateral safety: Under-collateralized positions must be liquidatable.

## 🧪 Test Coverage

The codebase is extensively tested using:

- Unit & integration tests for individual functions
- Representative fuzz tests

Total: **96 test cases**

### Test Coverage

<p align="center">
  <img src="assets/coverage.png" alt="Test Coverage" width="800">
</p>

## 🧰 Tech Stack

- Blockchain: Starknet
- Smart contract language: Cairo
- Package manager: Scarb
- Testing & fuzzing: Starknet Foundry (snforge)
- Oracle: Chainlink Price Feeds

## 🛠 Build, Test & Deploy

Prerequisites

- [Scarb](https://docs.swmansion.com/scarb/) 2.14.0
- [Starknet Foundry](https://foundry-rs.github.io/starknet-foundry/) 0.53.0

Clone the repo and from within the project's root folder run:

```bash
snforge test
```

### Deploy the contract

1. You'll need to declare 3 contracts `LPToken`, `Pool` and `Market` to get their class hashes following this instruction: https://foundry-rs.github.io/starknet-foundry/starknet/declare.html

```bash
sncast --account my_account declare --network sepolia --contract-name MyContract
```

2. You'll deploy the `Market` contract using these parameters:
- Admin wallet address
- `Pool` contract class hash deployed at step 1
- `LPToken` contract class hash deployed at step 1
- List of initial token addresses configured for price feed
- List of price feed addresses corresponds to the token addresses above
following this instruction: https://foundry-rs.github.io/starknet-foundry/starknet/deploy.html

```bash
sncast --account my_account deploy --class-hash <market_class_hash> --arguments '<owner>, <pool_class_hash>, <lp_token_class_hash>, array![<first_token_address>, <second_token_address>, <third_token_address>].span(), array![<first_price_feed_address>, <second_price_feed_address>, <third_price_feed_address>].span()' --network sepolia
```

3. After deploying the `Market` contract, the admin must call `deploy_new_pool(token, collateral_token)` to create lending pools for the desired asset pairs.

The token addresses passed to `deploy_new_pool` must already have their corresponding price feed addresses configured in the `Market` contract.

## ⚠️ Disclaimer

This code is for educational purposes only, has not been audited, and is provided without any warranties or guarantees.

## 📜 License

This project is licensed under the MIT License.
