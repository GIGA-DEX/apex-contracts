# Apex Contracts — Audit Scope

## Scope Baseline

| Item | Value |
| --- | --- |
| Repository | `https://github.com/GIGA-DEX/apex-contracts` |
| Source tree | `af289dce21d2efb13b7c22ac6ee3c3b5624a0659` |
| Full-review scope | 16 files / 2,754 Solidity code lines |
| Fork-delta scope | 13 files; Apex semantic deltas only |

The commercial review baseline is **2,754 full-review LoC plus the Apex semantic
deltas identified below**. The complete size of a fork-derived file is not part
of the full-review LoC merely because that file contains an Apex change.

Comments, formatting, import paths, compiler pragmas, contract/interface
renames, equivalent casts, and other non-semantic adaptations are excluded from
the fork-delta scope.

## Full-Review Files

| File | Code LoC |
| --- | ---: |
| `src/core/ApexController.sol` | 642 |
| `src/core/ApexToken.sol` | 12 |
| `src/core/ApexVault.sol` | 642 |
| `src/core/EmissionCenter.sol` | 25 |
| `src/core/FeeCenter.sol` | 273 |
| `src/core/FeeReceiver.sol` | 95 |
| `src/core/libraries/ApexControllerFeePolicy.sol` | 589 |
| `src/core/storage/ApexControllerStorage.sol` | 71 |
| `src/core/storage/ApexVaultStorage.sol` | 48 |
| `src/core/storage/FeeCenterStorage.sol` | 26 |
| `src/core/storage/FeeReceiverStorage.sol` | 15 |
| `src/core/storage/VeApexTokenStorage.sol` | 48 |
| `src/periphery/MixedQuoter.sol` | 183 |
| `src/periphery/SimplePositionDescriptor.sol` | 25 |
| `src/periphery/SmartRouter.sol` | 266 |
| `src/periphery/libraries/MixedRoute.sol` | 19 |
| **Total** | **2,979** |

## Fork-Delta Files

Only the runtime-relevant Apex deltas and the invariants directly affected by
those deltas are in scope. Unchanged upstream implementation is reference code.

| Apex file | Pinned upstream file | Delta in scope |
| --- | --- | --- |
| `src/core/ClassicPool.sol` | Ramses `contracts/Pair.sol` | LP metadata, renamed fee API, compiler/dependency and CREATE2 integration. **No change to curve math, swaps, mint/burn, lazy fee-mint math, reserves, or TWAP logic.** |
| `src/core/ClassicFactory.sol` | Ramses `contracts/factories/PairFactory.sol` | `ApexController` authority, fee receiver and protocol-fee configuration, pair validation, and deployment integration |
| `src/periphery/ClassicRouter.sol` | Ramses `contracts/Router.sol` | Chef integration, parameterized liquidity entrypoints, staking, authenticated withdrawal callbacks, and native-token handling. Unchanged liquidity-ratio arithmetic is reference code |
| `src/core/ClassicChef.sol` | Trader Joe `contracts/MasterChefJoeV2.sol` | Controller-funded finite rewards, accounting precision, pool-supply tracking, liability release, and router callbacks |
| `src/core/CLPool.sol` | PancakeSwap `projects/v3-core/contracts/PancakeV3Pool.sol` | Protocol-fee defaults, packing and accepted range, plus Apex interface integration. **No change to swap, tick, oracle, position, or liquidity math.** |
| `src/core/CLFactory.sol` | PancakeSwap `projects/v3-core/contracts/PancakeV3Factory.sol` | Initial owner, enabled fee tiers, canonical-pool validation, and Apex deployer/LM integration |
| `src/core/CLPoolDeployer.sol` | PancakeSwap `projects/v3-core/contracts/PancakeV3PoolDeployer.sol` | Guarded one-time factory binding |
| `src/core/CLMasterChef.sol` | PancakeSwap `projects/masterchef-v3/contracts/MasterChefV3.sol` | Controller-funded finite rewards, boost removal, NFT custody, liquidity-change timing, MEV treatment, and withdrawal behavior |
| `src/core/LmPool.sol` | PancakeSwap `projects/v3-lm-pool/contracts/PancakeV3LmPool.sol` | Finite reward-window handling and zero-liquidity reward forfeiture |
| `src/core/LmPoolDeployer.sol` | PancakeSwap `projects/v3-lm-pool/contracts/PancakeV3LmPoolDeployer.sol` | Factory discovery and Apex Chef/pool wiring |
| `src/periphery/NonfungiblePositionManager.sol` | PancakeSwap `projects/v3-periphery/contracts/NonfungiblePositionManager.sol` | `mintAndStake`, staking-recipient validation, internal mint refactor, and authorization of liquidity increases |
| `src/periphery/libraries/PoolAddress.sol` | PancakeSwap `projects/v3-periphery/contracts/libraries/PoolAddress.sol` | Apex pool init-code hash and address cast |
| `src/core/VeApexToken.sol` | Aerodrome `contracts/VotingEscrow.sol` | Upgradeable/namespaced storage conversion and removed or changed lock features. Retained veAERO checkpoint mathematics is reference code |

Pinned upstream revisions:

- Ramses V3: `RamsesExchange/ramses-v3-contracts@72977b9125051ac88d0dc1d08706d6230fc3c39d`
- PancakeSwap V3: `pancakeswap/pancake-v3-contracts@986847948755cba528324d41be19480731c36c2a`
- Trader Joe: `traderjoe-xyz/joe-core@5bec2f3d86500bfd81038c99afe702ee7e67af3e`
- Aerodrome: `aerodrome-finance/contracts@1ba30815bba620f7e9faa34769ffd00c214c9b82`

## Excluded Inherited Source

The following source is available for compilation and integration context but is
excluded from line-by-line review:

```text
src/core/CLEnumerable.sol
src/core/interfaces/**
src/core/libraries/cl/**
src/core/libraries/common/ApexErrors.sol
src/periphery/InterfaceMulticall.sol
src/periphery/Quoter.sol
src/periphery/QuoterV2.sol
src/periphery/SwapRouter.sol
src/periphery/TickLens.sol
src/periphery/base/**
src/periphery/interfaces/**
src/periphery/libraries/**
```

The final library exclusion has two in-scope exceptions:

```text
src/periphery/libraries/MixedRoute.sol
src/periphery/libraries/PoolAddress.sol
```

The excluded CL math, pool-support libraries, periphery bases, `SwapRouter`,
quoters, lens, and multicall preserve their pinned PancakeSwap or Ramses/Uniswap
behavior. Interfaces and `ApexErrors.sol` contain declarations rather than
executable protocol logic.

An issue caused by an in-scope Apex delta interacting with excluded inherited
code remains in scope.

## External Dependencies and Other Material

OpenZeppelin Contracts `5.0.2` and `3.4.2-solc-0.7` are excluded as audited
dependencies; Apex integration with them remains in scope.

The following repository material is not implementation scope:

```text
test/**
lib/**
.github/**
foundry.toml
foundry.lock
README.md
AUDIT_NOTES.md
```

Tests are supporting evidence. `AUDIT_NOTES.md` separately contains protocol
architecture, intended behavior, integration assumptions, known findings, and
developer responses.
