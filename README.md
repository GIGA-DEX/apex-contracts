# Apex Contracts

Core smart contracts for the multichain Apex decentralized-exchange stack.

## Repository relationship

This repository is a sanitized, one-way public mirror of Apex's authoritative
private contracts repository. Published protocol source and eligible tests are
exported from a reviewed private commit and are not developed as an independent
fork. First-party scripts, internal documentation, audit notes, deployment
configuration, broadcasts, operational/SDK integration tests, operator tooling,
and private records are intentionally excluded.

Private source commit: `b77ebdd81ae1e3002fa02bf49cc8970535c1c9c2`.


## Development

```bash
forge fmt --check
forge build --sizes
forge test
```
