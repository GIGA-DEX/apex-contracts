# Apex Contracts — Security Review Scope

## Scope Identification

| Item | Value |
| --- | --- |
| Audit repository | `https://github.com/GIGA-DEX/apex-contracts` |
| Source directory | `src/` |
| Source tree | `d25ecc1858df782b9a6dfcbcbe96511279bf83a0` |
| Solidity versions | `0.7.6`, `0.8.20`, and compatible `0.8.x` pragmas |
| In-scope files | 29 |
| In-scope Solidity code lines | 5,734 |

The source tree identifier is the Git object ID of `src/`. It uniquely identifies
the reviewed contract source independently of repository packaging or
documentation-only commits.

Code-line counts were produced with `cloc 2.06`. Blank and comment lines are not
included.

## In-Scope Files

The following files are included in full:

| File | Code LoC |
| --- | ---: |
| `src/core/ApexController.sol` | 623 |
| `src/core/ApexToken.sol` | 12 |
| `src/core/ApexVault.sol` | 642 |
| `src/core/CLFactory.sol` | 133 |
| `src/core/CLMasterChef.sol` | 501 |
| `src/core/CLPool.sol` | 601 |
| `src/core/CLPoolDeployer.sol` | 40 |
| `src/core/ClassicChef.sol` | 201 |
| `src/core/ClassicFactory.sol` | 100 |
| `src/core/ClassicPool.sol` | 384 |
| `src/core/EmissionCenter.sol` | 25 |
| `src/core/FeeCenter.sol` | 193 |
| `src/core/FeeReceiver.sol` | 93 |
| `src/core/LmPool.sol` | 102 |
| `src/core/LmPoolDeployer.sol` | 29 |
| `src/core/VeApexToken.sol` | 603 |
| `src/core/libraries/ApexControllerFeePolicy.sol` | 122 |
| `src/core/storage/ApexControllerStorage.sol` | 42 |
| `src/core/storage/ApexVaultStorage.sol` | 48 |
| `src/core/storage/FeeCenterStorage.sol` | 20 |
| `src/core/storage/FeeReceiverStorage.sol` | 15 |
| `src/core/storage/VeApexTokenStorage.sol` | 48 |
| `src/periphery/ClassicRouter.sol` | 321 |
| `src/periphery/MixedQuoter.sol` | 183 |
| `src/periphery/NonfungiblePositionManager.sol` | 313 |
| `src/periphery/SimplePositionDescriptor.sol` | 25 |
| `src/periphery/SmartRouter.sol` | 266 |
| `src/periphery/libraries/MixedRoute.sol` | 19 |
| `src/periphery/libraries/PoolAddress.sol` | 30 |
| **Total** | **5,734** |

## Review Boundary

The assessment covers the complete implementation of every in-scope file and
its interactions with inherited and third-party dependencies. A vulnerability
caused by an in-scope contract's use, configuration, or assumptions about an
out-of-scope dependency remains within scope.

The assessment includes cross-contract state transitions and invariants across:

- protocol initialization, roles, upgrades, and storage layouts;
- Classic pool creation, liquidity, swaps, fees, and farming;
- concentrated-liquidity pool creation, swaps, fees, positions, and farming;
- emission funding, allocation, settlement, forfeiture, and liabilities;
- veNFT lifecycle, voting-power checkpoints, Vault custody, rewards, and
  compounding;
- protocol-fee collection, conversion, distribution, and receiver upgrades;
- Classic, concentrated-liquidity, and mixed-route periphery execution;
- callback authentication, asset custody, native-token handling, and
  reentrancy boundaries.

## Internal Dependencies — Out of Scope

The following files are retained as compilation and analysis context but are not
included in the line-by-line implementation scope:

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

The following two files are exceptions to the final exclusion and are in scope:

```text
src/periphery/libraries/MixedRoute.sol
src/periphery/libraries/PoolAddress.sol
```

The exclusion basis is:

- `src/core/libraries/cl/**` consists of PancakeSwap CL math and accounting
  libraries with import, compiler, naming, formatting, or semantically
  equivalent adaptations.
- The excluded periphery contracts, bases, and libraries preserve PancakeSwap or
  Ramses/Uniswap behavior with equivalent adaptations.
- `src/core/CLEnumerable.sol` is semantically equivalent to PancakeSwap
  MasterChef V3 `Enumerable.sol`; helper functions were inlined without changing
  the state transition.
- Interfaces and `ApexErrors.sol` contain declarations and no executable
  protocol logic.

## Repository Material — Out of Scope

The following repository material is outside the contract implementation scope:

```text
test/**
lib/**
.github/**
foundry.toml
foundry.lock
README.md
AUDIT_NOTES.md
```

Tests and `AUDIT_NOTES.md` are supporting evidence and design context. They do
not restrict independent analysis or define expected findings.

Deployment scripts, deployment configuration, broadcast records, signing
operations, frontends, SDKs, indexers, APIs, and other off-chain services are not
part of this assessment.

## Source Ancestry

| Component | Upstream source | Pinned revision |
| --- | --- | --- |
| Classic pools and router | `RamsesExchange/ramses-v3-contracts` | `72977b9125051ac88d0dc1d08706d6230fc3c39d` |
| CL core, CL periphery, CL MasterChef, LM pools | `pancakeswap/pancake-v3-contracts` | `986847948755cba528324d41be19480731c36c2a` |
| Classic MasterChef accounting | `traderjoe-xyz/joe-core` | `5bec2f3d86500bfd81038c99afe702ee7e67af3e` |
| veAPEX lock mechanics | `aerodrome-finance/contracts` | `1ba30815bba620f7e9faa34769ffd00c214c9b82` |

Fork ancestry does not exclude a listed file. Fork-derived files are included
when Apex changes affect authority, accounting, fee handling, reward windows,
custody, storage, validation, staking, routing, or cross-contract behavior.

In particular, the full implementations of `CLPool`, `CLFactory`,
`CLPoolDeployer`, `LmPool`, `LmPoolDeployer`, `CLMasterChef`,
`NonfungiblePositionManager`, the Classic contracts, and `VeApexToken` are in
scope.

## External Dependencies

| Dependency | Version | Treatment |
| --- | --- | --- |
| OpenZeppelin Contracts | `5.0.2` | Implementation out of scope; integration and configuration in scope |
| OpenZeppelin Contracts | `3.4.2-solc-0.7` | Implementation out of scope; integration and configuration in scope |

The dependency source is vendored under `lib/**`.

## External Contract Assumptions

The protocol interacts with:

- a WETH9-compatible wrapped native token;
- standard ERC-20 pool, reward, and fee-conversion tokens;
- governance-approved `IFeeSwapper` implementations;
- OpenZeppelin transparent and beacon proxy infrastructure.

Fee-on-transfer and rebasing tokens are unsupported unless a specific in-scope
code path states otherwise. No oracle, bridge, or lending-market integration is
included in the contract scope.

## Security Properties

### Authority and upgrades

- Initializers cannot be replayed or front-run after deployment.
- Proxy administration, operational roles, and protocol ownership remain
  separated as designed.
- Namespaced storage remains collision-free across upgrades.
- Delegate calls into `ApexControllerFeePolicy` use the intended controller
  storage layout.
- FeeReceiver beacon upgrades preserve state and affect the intended receiver
  population.

### Fees and accounting

- Classic lazy LP fee minting and CL protocol-fee accounting conserve value.
- Active and inactive farm transitions apply the intended fee configuration and
  receiver.
- Collection, realization, splitting, swapping, and Vault notification cannot
  lose, duplicate, or redirect protocol assets.
- Balance-delta accounting and token behavior assumptions are enforced.

### Emissions and farming

- Funded emissions, reward liabilities, rates, allocation points, and finite
  reward windows remain synchronized across the Controller, both Chefs, and LM
  pools.
- Rebalancing, deactivation, reactivation, short payment, rounding, and
  zero-liquidity periods cannot overpay or trap withdrawals.
- CL NFT custody, beneficiary attribution, MEV windows, liquidity changes,
  emergency withdrawal, fee collection, and LM tick cleanup remain consistent.
- Classic atomic add-and-stake and withdrawal callbacks authenticate the caller,
  pair, position, and beneficiary.

### veNFT and Vault

- veAPEX checkpoints and total supply remain correct through lock creation,
  extension, increase, transfer, merge, and withdrawal.
- Vault position weights track veNFT state transitions.
- Reward notification, streaming, claim, compounding, forfeiture, and treasury
  settlement conserve assets across zero-weight and inactive states.
- Unsupported direct NFT transfers cannot corrupt or strand custody state.

### Routing and asset handling

- Classic and CL route decoding cannot collide or select an unintended pool.
- CREATE2 address derivation matches deployed pool bytecode and factory state.
- Swap and mint callbacks authenticate canonical pools.
- Exact-input and exact-output paths enforce limits, deadlines, and recipients.
- Native-token wrapping, refunds, sweeping, and multicall composition do not
  leak or strand user funds.

## Operational Limits Relevant to Review

- Emission rebalancing iterates over registered farms; the supported production
  assumption is at most 200 total farms.
- veAPEX checkpoint progression and Vault/FeeCenter loops require liveness and
  gas analysis at their configured bounds.
- `ApexController` is close to the EIP-170 runtime bytecode limit; build-size
  validation is required for changes to its implementation.
