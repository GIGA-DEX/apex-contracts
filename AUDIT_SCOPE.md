# Apex Contracts — Security Review Scope

## Scope Identification

| Item | Value |
| --- | --- |
| Audit repository | `https://github.com/GIGA-DEX/apex-contracts` |
| Source directory | `src/` |
| Source tree | `d25ecc1858df782b9a6dfcbcbe96511279bf83a0` |
| In-scope files | 29 |
| In-scope Solidity code lines | 5,734 |

The source tree is the Git object ID of `src/` and identifies the contract source
independently of documentation-only commits. Code-line counts use `cloc 2.06`
and exclude blank and comment lines.

## Review Classification

| Classification | Files | Container LoC | Review treatment |
| --- | ---: | ---: | --- |
| Full review | 17 | 2,979 | Review the complete Apex implementation |
| Differential review — close fork | 7 | 1,248 | Review Apex deltas and affected invariants against the pinned upstream file |
| Differential review — material fork | 5 | 1,507 | Review all Apex changes and affected integration/accounting paths; unchanged upstream mechanics remain reference code |
| **Total** | **29** | **5,734** |  |

For differential files, container LoC is the size of the complete Apex file and
does not represent the size of the Apex delta. Unchanged upstream logic is not a
new line-by-line review target. Changes to imports, compiler pragmas, contract or
interface names, formatting, and equivalent casts do not enter scope unless they
alter runtime behavior.

## Full Review

| File | Code LoC |
| --- | ---: |
| `src/core/ApexController.sol` | 623 |
| `src/core/ApexToken.sol` | 12 |
| `src/core/ApexVault.sol` | 642 |
| `src/core/EmissionCenter.sol` | 25 |
| `src/core/FeeCenter.sol` | 193 |
| `src/core/FeeReceiver.sol` | 93 |
| `src/core/VeApexToken.sol` | 603 |
| `src/core/libraries/ApexControllerFeePolicy.sol` | 122 |
| `src/core/storage/ApexControllerStorage.sol` | 42 |
| `src/core/storage/ApexVaultStorage.sol` | 48 |
| `src/core/storage/FeeCenterStorage.sol` | 20 |
| `src/core/storage/FeeReceiverStorage.sol` | 15 |
| `src/core/storage/VeApexTokenStorage.sol` | 48 |
| `src/periphery/MixedQuoter.sol` | 183 |
| `src/periphery/SimplePositionDescriptor.sol` | 25 |
| `src/periphery/SmartRouter.sol` | 266 |
| `src/periphery/libraries/MixedRoute.sol` | 19 |
| **Total** | **2,979** |

`VeApexToken.sol` retains veAERO checkpoint ancestry, but the upgradeable storage
conversion and removed/changed lock features are broad enough to require a full
review. The pinned veAERO implementation remains reference material for retained
checkpoint mechanics.

## Differential Review — Close Forks

Pinned PancakeSwap V3 source:
`pancakeswap/pancake-v3-contracts@986847948755cba528324d41be19480731c36c2a`.

| Apex file | Code LoC | Upstream file | Apex delta boundary |
| --- | ---: | --- | --- |
| `src/core/CLFactory.sol` | 133 | `projects/v3-core/contracts/PancakeV3Factory.sol` | Fee tiers, ownership/binding, pool validation, and LM-pool configuration |
| `src/core/CLPool.sol` | 601 | `projects/v3-core/contracts/PancakeV3Pool.sol` | Protocol-fee representation, range/default behavior, and Apex integration changes |
| `src/core/CLPoolDeployer.sol` | 40 | `projects/v3-core/contracts/PancakeV3PoolDeployer.sol` | Guarded one-time factory binding and Apex deployment wiring |
| `src/core/LmPool.sol` | 102 | `projects/v3-lm-pool/contracts/PancakeV3LmPool.sol` | Finite controller reward periods and zero-liquidity reward treatment |
| `src/core/LmPoolDeployer.sol` | 29 | `projects/v3-lm-pool/contracts/PancakeV3LmPoolDeployer.sol` | Factory discovery and Apex Chef/pool wiring |
| `src/periphery/NonfungiblePositionManager.sol` | 313 | `projects/v3-periphery/contracts/NonfungiblePositionManager.sol` | `mintAndStake`, recipient/Chef validation, and liquidity-donation restrictions |
| `src/periphery/libraries/PoolAddress.sol` | 30 | `projects/v3-periphery/contracts/libraries/PoolAddress.sol` | Apex pool types and init-code hash |
| **Total container LoC** | **1,248** |  |  |

The concentrated-liquidity swap engine, tick processing, oracle observations,
position accounting, and inherited periphery mechanics remain PancakeSwap logic
except where an Apex delta above changes their inputs, outputs, or invariants.

## Differential Review — Material Forks

These files retain identifiable upstream structure, but Apex modifications are
larger than the close-fork group. The scope is every Apex delta, the complete
enclosing function, and each invariant or integration path affected by that
delta. Unchanged upstream routines remain outside the new implementation review.

| Apex file | Code LoC | Pinned upstream file | Apex delta boundary |
| --- | ---: | --- | --- |
| `src/core/CLMasterChef.sol` | 501 | PancakeSwap `projects/masterchef-v3/contracts/MasterChefV3.sol` | Controller-funded finite emissions, boost removal, NFT custody, liquidity-change timing, MEV treatment, and withdrawal behavior |
| `src/core/ClassicChef.sol` | 201 | Trader Joe `contracts/MasterChefJoeV2.sol` | Controller-funded finite emissions, accounting precision, liability release, pool-supply tracking, and router callbacks |
| `src/core/ClassicFactory.sol` | 100 | Ramses `contracts/factories/PairFactory.sol` | Apex authority, fee configuration, receiver configuration, and pair deployment |
| `src/core/ClassicPool.sol` | 384 | Ramses `contracts/Pair.sol` | ERC-20 integration, lazy protocol-fee minting, fee receiver/configuration, and Apex factory/controller integration |
| `src/periphery/ClassicRouter.sol` | 321 | Ramses `contracts/Router.sol` | Apex interfaces, atomic add-and-stake, withdrawal callbacks, recipient handling, and native-token flows |
| **Total container LoC** | **1,507** |  |  |

Pinned revisions for this group:

- PancakeSwap V3:
  `pancakeswap/pancake-v3-contracts@986847948755cba528324d41be19480731c36c2a`
- Trader Joe:
  `traderjoe-xyz/joe-core@5bec2f3d86500bfd81038c99afe702ee7e67af3e`
- Ramses V3:
  `RamsesExchange/ramses-v3-contracts@72977b9125051ac88d0dc1d08706d6230fc3c39d`

For `ClassicPool.sol`, Ramses-derived stable/volatile curve math, reserve
accounting, oracle observation logic, and swap mechanics are reference code.
The Apex fee-minting and integration deltas, including their effect on those
inherited invariants, are in scope.

## Upstream Reference for Full-Review Fork

| Apex file | Reference source | Pinned revision |
| --- | --- | --- |
| `src/core/VeApexToken.sol` | Aerodrome `contracts/VotingEscrow.sol` | `aerodrome-finance/contracts@1ba30815bba620f7e9faa34769ffd00c214c9b82` |

This reference does not change the full-review classification of
`VeApexToken.sol`.

## Internal Dependencies — Out of Scope

The following files are available as compilation and analysis context but are
excluded from the implementation scope:

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

Exclusion basis:

- `src/core/libraries/cl/**` preserves PancakeSwap CL math and accounting logic
  with import, compiler, naming, formatting, or semantically equivalent
  adaptations.
- The excluded periphery implementations preserve PancakeSwap or
  Ramses/Uniswap behavior with equivalent adaptations.
- `src/core/CLEnumerable.sol` is semantically equivalent to PancakeSwap
  MasterChef V3 `Enumerable.sol`; internal helpers were inlined without changing
  the state transition.
- Interfaces and `ApexErrors.sol` contain declarations rather than executable
  protocol logic.

An issue caused by an in-scope Apex delta interacting with an out-of-scope
dependency remains in scope.

## External Dependencies — Out of Scope

| Dependency | Version | Treatment |
| --- | --- | --- |
| OpenZeppelin Contracts | `5.0.2` | Implementation excluded; Apex integration included |
| OpenZeppelin Contracts | `3.4.2-solc-0.7` | Implementation excluded; Apex integration included |

Dependency source is vendored under `lib/**`.

## Other Repository Material — Out of Scope

```text
test/**
lib/**
.github/**
foundry.toml
foundry.lock
README.md
AUDIT_NOTES.md
```

Tests are supporting evidence. `AUDIT_NOTES.md` separately documents protocol
architecture, intended behavior, integration assumptions, known findings, and
developer responses. Deployment and off-chain applications are outside this
contract source scope.
