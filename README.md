# Apex Contracts

Core smart contracts for the multichain Apex decentralized-exchange stack.

## Repository relationship

This repository is a sanitized, one-way public mirror of Apex's authoritative
private contracts repository. Published protocol source and eligible tests are
exported from a reviewed private commit and are not developed as an independent
fork. First-party scripts, internal documentation, audit notes, deployment
configuration, broadcasts, operational/SDK integration tests, operator tooling,
and private records are intentionally excluded.

Private source commit: `227de0d483bd4db2b2984152dbdb45b271494362`.


## Development

```bash
forge fmt --check
forge build --sizes
forge test
```
