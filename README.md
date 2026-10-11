# evm_directory_chain

Smart contracts for the EVM Directory project. The main contract, `Escrow`, holds ETH for buyer/seller
offers on **Ethereum Sepolia** and records each offer's USD value from the
[Chainlink ETH/USD price feed](https://docs.chain.link/data-feeds/price-feeds/addresses). Its events are
meant to be indexed by [`evm_directory_subgraph`](https://github.com/MaxwellDG/evm_directory_subgraph) and
served by [`evm_directory_api`](https://github.com/MaxwellDG/evm_directory_api) to report how often escrow
deals succeed or fail.

This project targets Sepolia only. There is no mainnet deployment.

Built with [Hardhat 3](https://hardhat.org/docs/getting-started) (mocha + ethers, Ignition) and Solidity 0.8.28.

## Layout

| Path                                       | What it is                                                     |
| ------------------------------------------ | -------------------------------------------------------------- |
| `contracts/Escrow.sol`                     | The escrow contract                                            |
| `contracts/interfaces/AggregatorV3Interface.sol` | Minimal copy of Chainlink's feed interface               |
| `contracts/mocks/MockV3Aggregator.sol`     | Mock feed for tests and local deployments only                 |
| `contracts/Escrow.t.sol`                   | Foundry-style Solidity tests                                   |
| `test/Escrow.ts`                           | mocha + ethers tests                                           |
| `ignition/modules/Escrow.ts`               | Deploys `Escrow` against a real feed (Sepolia)                 |
| `ignition/modules/EscrowLocal.ts`          | Deploys a mock feed + `Escrow` for local chains                |
| `ignition/parameters/sepolia.json`         | Sepolia deployment parameters                                  |

## How the escrow works

Each offer has a seller, a buyer, an amount in wei, and a USD value (18 decimals) taken from the price feed
when the offer is created. The feed answer must be positive and no older than `maxPriceAge` seconds, or the
call reverts with `StalePrice` / `InvalidPrice`. The recorded USD value never changes afterwards.

| Step | Function | Who | ETH |
| ---- | -------- | --- | --- |
| List an item for sale | `createOffer(Side.Sell, counterparty, amount)` | seller | none |
| Offer to buy | `createOffer(Side.Buy, counterparty, amount)` | buyer | deposits `amount` |
| Accept | `acceptOffer(offerId)` | the other party (`counterparty`, or anyone if it was `address(0)`) | buyer sends `amount` when accepting a listing |
| Cancel | `cancelOffer(offerId)` | creator, only while still open | a buy offer's deposit is returned |
| Complete the sale | `completeSale(offerId)` | buyer or arbiter | escrowed ETH goes to the seller |
| Refund | `refund(offerId)` | seller or arbiter | escrowed ETH goes back to the buyer |

Statuses: `Open` → `Accepted` → `Completed` or `Refunded`; `Open` → `Cancelled`.

The `arbiter` is an optional dispute resolver set at deployment (`address(0)` disables it). Without an
arbiter, an accepted offer can only be settled by the buyer releasing funds or the seller refunding.

### Events

```solidity
event OfferCreated(uint256 indexed offerId, address indexed seller, address indexed buyer, address creator, Side side, uint256 amount, uint256 usdValue);
event OfferAccepted(uint256 indexed offerId, address indexed seller, address indexed buyer, uint256 amount);
event OfferCancelled(uint256 indexed offerId, address indexed cancelledBy);
event SaleExecuted(uint256 indexed offerId, address indexed seller, address indexed buyer, uint256 amount, uint256 usdValue);
event Refunded(uint256 indexed offerId, address indexed buyer, address indexed refundedBy, uint256 amount);
```

In `OfferCreated`, `buyer` (for a sell listing) or `seller` (for a buy offer) is `address(0)` when the offer
is open to anyone; the accepting address appears in `OfferAccepted`.

### Safety

- Checks-effects-interactions plus a `nonReentrant` guard on every state-changing function.
- Custom errors (`Unauthorized`, `InvalidStatus`, `IncorrectPayment`, `StalePrice`, ...).
- ETH is sent with `call`; if the recipient reverts, the whole settlement reverts and the funds stay in escrow.

## Setup

Requires Node.js 22 or later (Hardhat 3).

```shell
pnpm install
```

## Test

```shell
npx hardhat test            # everything
npx hardhat test solidity   # contracts/Escrow.t.sol
npx hardhat test mocha      # test/Escrow.ts
```

## Deploy

### Local

```shell
npx hardhat ignition deploy ignition/modules/EscrowLocal.ts
```

### Sepolia

The Sepolia deployment uses the Chainlink ETH/USD feed proxy
`0x694AA1769357215DE4FAC081bf1f309aDC325306`
(from [docs.chain.link](https://docs.chain.link/data-feeds/using-data-feeds)). Check
[data.chain.link](https://data.chain.link/feeds/ethereum/testnet-sepolia/eth-usd) for the feed's current
heartbeat and adjust `maxPriceAge` in `ignition/parameters/sepolia.json` if needed (default: 3 hours).

`hardhat.config.ts` reads three configuration variables:

| Variable | Used for |
| -------- | -------- |
| `SEPOLIA_RPC_URL` | Sepolia RPC endpoint |
| `SEPOLIA_PRIVATE_KEY` | Deployer account (needs Sepolia ETH) |
| `ETHERSCAN_API_KEY` | Contract verification |

Set them with the keystore (or as environment variables):

```shell
npx hardhat keystore set SEPOLIA_RPC_URL
npx hardhat keystore set SEPOLIA_PRIVATE_KEY
npx hardhat keystore set ETHERSCAN_API_KEY
```

Deploy (and verify on Etherscan in the same step):

```shell
npx hardhat ignition deploy ignition/modules/Escrow.ts \
  --network sepolia \
  --parameters ignition/parameters/sepolia.json \
  --build-profile production \
  --verify
```

Or verify an existing deployment separately:

```shell
npx hardhat verify --network sepolia <ESCROW_ADDRESS> \
  0x694AA1769357215DE4FAC081bf1f309aDC325306 10800 0x0000000000000000000000000000000000000000
```

After deploying, point `evm_directory_subgraph` at the new `Escrow` address and its deployment block.

## Contract addresses

### Sepolia

Not deployed yet.
