# KRSI chain kit: full reference

For the demo you only need README.md (two function calls in `onchain.ts`). This file is the complete reference: everything the dashboard needs to put KYC and eNWRs on Arbitrum Sepolia with MetaMask, without reading Solidity: the deployed addresses, the ABIs, and `krsiChain.ts`, which turns the dashboard's API objects into contract arguments. Every conversion here is pinned to the contracts by `vectors.json` and the tests in `test/`.

## What to copy and install

1. Copy `krsiChain.ts`, `deployments.json` and the `abis/` folder into the app, for example to `src/chain/`, keeping them side by side (`krsiChain.ts` imports `./deployments.json`).
2. Install the exact viem version the kit was tested with: `npm install viem@2.57.4`.
3. If you call viem directly instead of through `onchain.ts` (which declares it), declare MetaMask's provider once, for example in `src/vite-env.d.ts`: `interface Window { ethereum?: import('viem').EIP1193Provider }`.
4. Nothing else in the app's TypeScript setup needs to change. `tsconfig.frontend.json` repeats the dashboard's compiler options and `krsiChain.ts` compiles under it; the app targets ES2023, so `bigint` and BigInt literals such as `0n` work.

The kit returns `bigint` for every uint64 and uint256 value and `number` for uint8 and uint16, which is what viem expects for `writeContract`.

## Deployment (Arbitrum Sepolia, chain id 421614)

<!-- deployment:start -->
| Field | Value |
| --- | --- |
| `chainId` | `421614` |
| `eas` | `0x2521021fc8BF070473E1e1801D3c7B4aB701E1dE` |
| `schemaRegistry` | `0x45CB6Fa0870a8Af06796Ac15915619a0f22cd475` |
| `kycResolver` | `0x57031ED0217f1040b295F027665620fB74a068FD` |
| `receipt` | `0x674070F23a5450D430F3A808385c401F33e301F6` |
| `schema` | `bytes32 userRef,uint8 role,bytes32 provider,uint64 kycVerifiedAt` |
| `schemaUID` | `0xbaced4df1f22e93ac2ed72f0e58934c33bcb07b91054d180603f09fb5c977ccd` |
| `admin` | `0xeF519A9DC8e62765B72ad9e22B26Aeb3e4ae5494` |
| `issuer` | `0x3C26A3Aa362FcFdFe262c299f33BD93Fcd699d98` |
| `auditor` | `0x9DCDDdD5071b47848E45809b28658400b004C9B2` |
| `warehouseOwner` | `0x9DCDDdD5071b47848E45809b28658400b004C9B2` |
| `demoWarehouseSlug` | `agri-vault` |
| `deployedAtBlock` | `322118242` |
<!-- deployment:end -->

In code these are `addresses.eas`, `addresses.receipt`, `addresses.schemaUID` and so on (`import { addresses } from './krsiChain'`). Both KRSI contracts are verified on Arbiscan: [KrsiKycResolver](https://sepolia.arbiscan.io/address/0x57031ED0217f1040b295F027665620fB74a068FD#code), [KrsiReceipt](https://sepolia.arbiscan.io/address/0x674070F23a5450D430F3A808385c401F33e301F6#code). Query logs from `deployedAtBlock`, which is an Arbitrum (L2) block number.

## In the demo: two calls

The demo puts exactly two things on chain. Everything else in the call table works and is tested, but is not a demo step.

1. **KYC stored on chain.** After a user finishes DigiLocker, the issuer signs `EAS.attest` (row 1 below).
2. **eNWR stored on chain.** When the auditor approves an inspection, the auditor signs `KrsiReceipt.issue` (row 2 below), which mints the receipt to the farmer's attested wallet.

Order matters: issue only mints to a wallet that holds a live attestation for the receipt owner's KRSI user id, otherwise it reverts `HolderNotVerified`. Attest the farmer first.

## The rule for every action: API first, then MetaMask

Each dashboard action calls the existing API exactly as today, and only after it succeeds asks MetaMask to sign the matching call with the response's data. The database stays the source of truth; the chain follows it.

If the user rejects the signature or the transaction fails, nothing is rolled back in the database. Show the receipt as "Not on chain yet" and offer to sign again. To decide which receipts need that, read `KrsiReceipt.stateOf(BigInt(enwr.id))`: `0` (NONE) means the token was never issued, so show "Not on chain yet"; `1` ACTIVE, `2` LISTED, `3` RELEASE_REQUESTED, `4` RELEASED.

```ts
import { createPublicClient, createWalletClient, custom, http, zeroHash, type Abi } from 'viem'
import { arbitrumSepolia } from 'viem/chains'
import easAbi from './abis/EAS.json'
import receiptAbi from './abis/KrsiReceipt.json'
import { addresses, buildReceiptInput, encodeKycData, providerBytes, providerFromApi, timestampToUnix, userRef } from './krsiChain'

const publicClient = createPublicClient({ chain: arbitrumSepolia, transport: http() })
const walletClient = createWalletClient({ chain: arbitrumSepolia, transport: custom(window.ethereum!) })
const [account] = await walletClient.requestAddresses() // the MetaMask account selected right now

// Row 1, KYC: in the user's own session (only they can read their KycStatus), signed by the issuer account.
const ROLE_CODE = { FARMER: 1, MERCHANT: 2, WAREHOUSE_OWNER: 3 } as const // AUDITOR is never attested
const data = encodeKycData(
  userRef(profile.id),
  ROLE_CODE[profile.role as keyof typeof ROLE_CODE],
  providerBytes(providerFromApi(kycStatus.provider)),
  timestampToUnix(kycStatus.verifiedAt!),
)
await walletClient.writeContract({
  account, // must be the issuer
  address: addresses.eas,
  abi: easAbi as Abi,
  functionName: 'attest',
  args: [{
    schema: addresses.schemaUID,
    data: {
      recipient: userWallet, // the user's MetaMask address, never profile.walletAddress
      expirationTime: BigInt(Math.floor(Date.now() / 1000) + 365 * 86400),
      revocable: true,
      refUID: zeroHash,
      data,
      value: 0n,
    },
  }],
})

// Row 2, eNWR: right after api.enwrs.inspect(id, { decision: 'APPROVE', ... }) returns, signed by the auditor.
const enwr = await api.enwrs.inspect(id, body) // the response already carries ledgerHash (FINDINGS F9)
await walletClient.writeContract({
  account, // must hold AUDITOR_ROLE
  address: addresses.receipt,
  abi: receiptAbi as Abi,
  functionName: 'issue',
  args: [buildReceiptInput(enwr, enwr.ledgerHash), userRef(enwr.ownerId)],
})
const state = await publicClient.readContract({ address: addresses.receipt, abi: receiptAbi as Abi, functionName: 'stateOf', args: [BigInt(enwr.id)] })
```

`buildReceiptInput` throws with a readable message before MetaMask opens when the receipt cannot be issued: not inspected yet, no ledger hash, or a short string that breaks SPEC 4.13 (for example a grade typed with a quote or a non ASCII character). Check `KrsiKycResolver.verifiedWalletOf(userRef(enwr.ownerId))` first if you want to warn that the farmer has no attestation yet (it returns the zero address).

## Call table

API field names are those of `src/api/types.ts`. "Demo" marks the two calls the demo uses.

<!-- call-table:start -->
| # | Dashboard action | Contract call | Signer | Where each argument comes from |
| --- | --- | --- | --- | --- |
| 1 | KYC completed (demo; issuer screen or `script/IssueKyc.s.sol`) | `EAS.attest` | KRSI issuer | `schema` = `addresses.schemaUID`; `recipient` = the user's MetaMask address; `expirationTime` = now + 365 days; `revocable` = true; `refUID` = zero; `value` = 0; `data` = `encodeKycData(userRef(Profile.id), role code of Profile.role, providerBytes(providerFromApi(KycStatus.provider)), timestampToUnix(KycStatus.verifiedAt))`, read in the user's session from GET /api/me and GET /api/kyc |
| 2 | Auditor approves the inspection (demo) | `KrsiReceipt.issue` | Auditor | `buildReceiptInput(enwr, enwr.ledgerHash)` and `userRef(enwr.ownerId)`, where `enwr` is the response of POST /api/enwrs/{id}/inspection |
| 3 | Create listing / withdraw listing (not in the demo) | `KrsiReceipt.lock`, `KrsiReceipt.unlock` | Seller (the admin may too) | `BigInt(listing.enwrId)` |
| 4 | Accept bid (not in the demo) | `KrsiReceipt.settle` | Seller only | `...buildSettleArgs(settlement)` from POST /api/bids/{id}/accept; a whole sale passes childId 0, an empty child receipt number and a zero child ledger hash |
| 5 | Holder requests release, a new button (not in the demo) | `KrsiReceipt.requestRelease`, `KrsiReceipt.cancelRelease` | Holder (the admin may also cancel) | `BigInt(enwr.id)` |
| 6 | Warehouse owner releases the goods (not in the demo) | `KrsiReceipt.confirmRelease` | Warehouse owner mapped to the receipt's warehouse | `BigInt(enwr.id)`, after POST /api/enwrs/{id}/release |
| 7 | Revoke KYC (not in the demo; `script/RevokeKyc.s.sol`) | `EAS.revoke` | KRSI issuer | `schema` = `addresses.schemaUID`; `uid` = `KrsiKycResolver.uidOf(wallet)`; `value` = 0 |
| 8 | Admin only, no dashboard action | `KrsiReceipt.pause`, `KrsiReceipt.unpause`, `KrsiReceipt.setWarehouseOwner`, `KrsiReceipt.setFrozenTokens`, `KrsiReceipt.forcedTransfer`, `KrsiReceipt.grantRole`, `KrsiReceipt.revokeRole`, `KrsiReceipt.renounceRole`, `KrsiKycResolver.setIssuer`, `KrsiKycResolver.setSchema`, `KrsiKycResolver.transferOwnership`, `KrsiKycResolver.renounceOwnership` | KRSI admin | Operations only: pause in an emergency, map another warehouse slug to its owner, freeze or move a token by force |
| 9 | Not offered by the dashboard (standard ERC 721) | `KrsiReceipt.transferFrom`, `KrsiReceipt.safeTransferFrom`, `KrsiReceipt.approve`, `KrsiReceipt.setApprovalForAll` | Holder | A holder could move an ACTIVE receipt to another verified wallet directly; the database would not know (limitation 2) |
| 10 | Called only by EAS, never by the app | `KrsiKycResolver.attest`, `KrsiKycResolver.multiAttest`, `KrsiKycResolver.revoke`, `KrsiKycResolver.multiRevoke` | EAS | EAS calls these hooks during `EAS.attest` and `EAS.revoke`; any other caller is refused |
<!-- call-table:end -->

The KYC role code comes from `Profile.role`: FARMER (farmer and FPO) is 1, MERCHANT (trader and FPU) is 2, WAREHOUSE_OWNER is 3, and AUDITOR is never attested (auditors hold `AUDITOR_ROLE` on the token instead).

## Reading state back

| What the UI shows | Call |
| --- | --- |
| On chain or not, and the receipt's state | `KrsiReceipt.stateOf` |
| The stored record, also after release | `KrsiReceipt.getReceipt` |
| Past its valid till date (UTC) | `KrsiReceipt.isExpired` |
| Whether a wallet to wallet move would pass the gate | `KrsiReceipt.canTransfer` |
| The token's metadata (JSON, base64 data URL) | `KrsiReceipt.tokenURI` |
| Whether a wallet holds a live KYC credential | `KrsiKycResolver.isVerified` |
| The credential's decoded fields | `KrsiKycResolver.getKyc` |
| The wallet linked to a KRSI user | `KrsiKycResolver.verifiedWalletOf` |
| The attestation uid of a wallet (needed to revoke) | `KrsiKycResolver.uidOf` |

## Conversions (`krsiChain.ts`)

| Function | Input | Output | Rule |
| --- | --- | --- | --- |
| `userRef(userId)` | `Profile.id`, `enwr.ownerId`, `trade.buyerId` | bytes32 | keccak256(abi.encode("KRSI_USER", uint256 userId)) |
| `providerFromApi(provider)` | `KycStatus.provider` | `'SETU_DIGILOCKER'` or `'DEMO'` | "setu" gives SETU_DIGILOCKER; "mock" or null gives DEMO |
| `providerBytes(name)` | provider name | bytes32 | the name left aligned, zero padded |
| `mtToKg(value)` | `quantityMt` (JSON number or string) | bigint kg | tonnes × 1000, at most 3 decimals, never through floating point arithmetic |
| `pctToBps(value)` | `moisturePct`, `foreignMatterPct` | number bps | percent × 100, at most 2 decimals, 0 to 10000; null gives 0 |
| `dateToUnix(yyyyMmDd)` | `storedOn`, `validTill` | bigint seconds | 00:00:00 UTC of that date |
| `timestampToUnix(isoString)` | `inspectedAt`, `verifiedAt` | bigint seconds | rounded down; reads up to 9 fraction digits |
| `inspectionHash(remarks, inspectedAtSeconds)` | `qualityRemarks`, seconds | bytes32 | keccak256(abi.encode(string, uint64)); null remark is "" |
| `ledgerHashToBytes32(hex64)` | `ledgerHash` | bytes32 | adds 0x, lowercases, exactly 64 hex characters |
| `encodeKycData(userRef, role, provider, kycVerifiedAt)` | the four values above | bytes | abi.encode(bytes32, uint8, bytes32, uint64) |
| `buildReceiptInput(apiReceipt, ledgerHash)` | inspection response | `ReceiptInput` | all of the above, plus SPEC 4.13 checks on receiptNo, warehouseId, commodity and grade |
| `buildSettleArgs(settlement)` | accept bid response | settle's 7 arguments | whole sale when `buyerReceipt.id === listing.enwrId` |

The API sends decimals as JSON numbers (`"quantityMt":20.000` arrives as `20`). `mtToKg` and `pctToBps` turn a number back into its shortest decimal string first, which is exact for these database columns, and reject anything with more decimals than the column allows.

## Accounts and who signs

| Account | Address | Signs | Needs test ETH for the demo |
| --- | --- | --- | --- |
| KRSI admin | `0xeF519A9DC8e62765B72ad9e22B26Aeb3e4ae5494` | the deployment and row 8 | no |
| KRSI issuer | `0x3C26A3Aa362FcFdFe262c299f33BD93Fcd699d98` | rows 1 and 7 | yes (row 1) |
| Auditor and warehouse owner (one account) | `0x9DCDDdD5071b47848E45809b28658400b004C9B2` | row 2 as auditor, row 6 as owner of agri-vault | yes (row 2) |
| Farmer | `0xD73792F814d3ADb440Ef50F62268978E3F715C13` | nothing in the demo; rows 3 to 5 as holder | no |

The presenter switches MetaMask accounts for each step. A merchant account would be needed only for trading, which is not in the demo.

<!-- address-warning:start -->
## Warning: the dashboard's ledger addresses are not wallets

`Profile.walletAddress`, the JWT `addr` claim and every ledger block's `actorAddress` look like Ethereum addresses but are `0x` plus the first 40 hex characters of sha256 of the user's phone number. They are not MetaMask accounts, nobody holds a key for them, and because the phone number space is small they can be reversed to the phone number. Never pass them to a contract, never use them as `recipient`, and never show them as the user's wallet. The user's wallet is always the address MetaMask returns.
<!-- address-warning:end -->

## Known limitations

1. The database moves first; a rejected or failed signature leaves the chain behind until the step is signed again ("Not on chain yet").
2. Direct holder to holder transfers between verified wallets are possible on chain and invisible to the database (row 9). The dashboard never offers them.
3. An expired listing stays locked on chain until the seller withdraws, as in the database.
4. Seeded demo data was never put on chain; the demo uses fresh receipts.
5. A credential with provider SETU_DIGILOCKER means "completed KRSI's DigiLocker flow"; DEMO means the backend marked the user verified without DigiLocker (a seeded account or the mock provider). The backend does not verify the Aadhaar XML signature, so neither credential claims that.
6. The issuer is a person with a MetaMask account in the demo; in production it would be a service.
7. A missing moisture or foreign matter reading is stored as 0 bps, so on chain it cannot be told apart from a measured 0.00 %.

## Checking the kit

From `chainStorage/handoff/` after `npm install`:

```
npm test            # vectors, conversions, buildReceiptInput, buildSettleArgs (vitest)
npm run typecheck   # strict, and with the dashboard's own compiler options
npm run check       # ABIs, this README, deployments.json, API field names
npm run sync        # after forge build or a new deployment: refresh abis/ and deployments.json
```

The Solidity side (`forge test` in `chainStorage/`) checks `vectors.json` against the contracts' encoding library. `fixtures/` holds the API samples recorded in Phase 0; each file says whether it is real (scrubbed) or synthetic.
