# Apex Contracts

Core smart contracts for the Apex decentralized exchange.

This public mirror intentionally contains only contract sources, tests, and
vendored build dependencies. Deployment automation, live configuration,
broadcast records, operator addresses, and private release material are kept in
the isolated release repository.

## Development

```bash
forge fmt --check
forge build --sizes
forge test
```

No address in tests is a production authority. Canonical live addresses must be
read from an integrity-checked, release-signed deployment manifest.
