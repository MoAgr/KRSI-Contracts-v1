# chainStorage

KRSI on Arbitrum Sepolia: a KYC credential per user as an EAS attestation checked by `KrsiKycResolver`, and each electronic negotiable warehouse receipt (eNWR) as a token in `KrsiReceipt`. It works alongside the KRSI dashboard and never changes it.

| Contract | Arbitrum Sepolia address |
| --- | --- |
| KrsiKycResolver | [0x57031ED0217f1040b295F027665620fB74a068FD](https://sepolia.arbiscan.io/address/0x57031ED0217f1040b295F027665620fB74a068FD#code) |
| KrsiReceipt | [0x674070F23a5450D430F3A808385c401F33e301F6](https://sepolia.arbiscan.io/address/0x674070F23a5450D430F3A808385c401F33e301F6#code) |

All deployment values are in `deployments/421614.json`. The frontend kit is in `handoff/` (start with `handoff/README.md`).

## Build and test

```
git clone --recursive <this repository>   # or, after a plain clone: git submodule update --init --recursive
forge build          # solc 0.8.28, optimizer 200 runs, pinned in foundry.toml
forge test           # all Solidity tests; fork tests run when ARB_SEPOLIA_RPC_URL is set
cd handoff && npm ci && npm test && npm run check
```

Dependencies are git submodules in `lib/` at exact tags: forge-std v1.17.0, OpenZeppelin Contracts v5.7.0, eas-contracts v1.4.0. Scripts read secrets from `.env` (never committed); `.env.example` lists the variables.
