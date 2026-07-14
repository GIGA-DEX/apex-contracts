# Symbolic money-safety checks

These tests target code paths where accounting mistakes can lose or overpay user funds:

- `SymbolicVaultAndFees.t.sol`: vault reward accounting, claim conservation, and fee-center raw-unit splits.
- `SymbolicEmissions.t.sol`: controller emission liability, classic farm accrual caps, and `EmissionCenter` 95/5 release splitting.
- `SymbolicClassicPoolMath.t.sol`: volatile and stable classic-pool quote math preserving the post-fee invariant.
- `SymbolicCLSwapMath.t.sol`: CL per-tick swap-step bounds for exact-input and exact-output swaps.
- `SymbolicCLProtocolFees.t.sol`: CL protocol-fee and flash-fee accounting math.
- `SymbolicRouterQuotes.t.sol`: SmartRouter and MixedQuoter output agreement for classic and mixed classic/CL paths.
- `SymbolicAccessGates.t.sol`: true symbolic checks for controller-only money-path gates.
- `SymbolicClassicChefWithdraw.t.sol`: true symbolic check that `withdrawTo` debits only the caller's ClassicChef
  position and transfers the withdrawn LP to the requested recipient.

The arithmetic-heavy pool, vault, emission, router, and fee properties intentionally use `testFuzz_...` and
`fuzzOnly_...` entrypoints. Current Foundry nightly symbolic execution reports these broad nonlinear arithmetic
properties as incomplete (`hard arithmetic heuristic witness` or solver `unknown`), so they should not be presented as
formal proofs.

The `check_...` entrypoints are limited to properties the current symbolic backend can complete.

Run the fuzz-compatible checks:

```sh
forge test --match-path 'test/symbolic/*.t.sol'
```

Run the true symbolic checks with a Forge nightly that supports symbolic testing and an SMT solver such as `z3` or
`cvc5`:

```sh
forge test --symbolic --match-path test/symbolic/SymbolicAccessGates.t.sol --symbolic-solver-portfolio z3,cvc5 --symbolic-timeout 60
forge test --symbolic --match-path test/symbolic/SymbolicClassicChefWithdraw.t.sol --symbolic-solver-portfolio z3,cvc5 --symbolic-timeout 60
```

Do not treat these commands as formal AMM math proofs. The following are useful fuzz campaigns, not currently complete
symbolic proofs:

```sh
forge test --match-path test/symbolic/SymbolicCLProtocolFees.t.sol
forge test --match-path test/symbolic/SymbolicClassicPoolMath.t.sol
forge test --match-path test/symbolic/SymbolicCLSwapMath.t.sol
forge test --match-path test/symbolic/SymbolicVaultAndFees.t.sol
forge test --match-path test/symbolic/SymbolicEmissions.t.sol
forge test --match-path test/symbolic/SymbolicRouterQuotes.t.sol
```
