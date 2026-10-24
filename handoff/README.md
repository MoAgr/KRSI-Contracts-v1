# Put KYC and eNWRs on chain

The demo puts two things on Arbitrum Sepolia. Each is one function call, made right after the dashboard's existing API call succeeds. MetaMask pops up and asks to sign.

## Setup, once

1. Copy `krsiChain.ts`, `onchain.ts`, `deployments.json` and the `abis/` folder into `src/chain/`.
2. Run `npm install viem@2.57.4`.

## Step 1: KYC on chain

In `KycCallbackPage`, after `api.kyc.complete` returns:

```ts
import { putKycOnChain } from '../chain/onchain'

const kyc = await api.kyc.complete(requestId)
await putKycOnChain(user, kyc, userWallet)
```

`user` is `useAuth().user`. `userWallet` is that user's MetaMask address. MetaMask must be on the **issuer** account.

## Step 2: eNWR on chain

Where the auditor approves an inspection:

```ts
import { putEnwrOnChain } from '../chain/onchain'

const enwr = await api.enwrs.inspect(id, body)
if (body.decision === 'APPROVE') await putEnwrOnChain(enwr)
```

MetaMask must be on the **auditor** account. Do step 1 for the farmer first, or this fails with `HolderNotVerified`.

## Good to know

<!-- deployment:start -->
| Account | Address |
| --- | --- |
| `issuer` | `0x3C26A3Aa362FcFdFe262c299f33BD93Fcd699d98` |
| `auditor` | `0x9DCDDdD5071b47848E45809b28658400b004C9B2` |
<!-- deployment:end -->

1. Both accounts need a little Arbitrum Sepolia ETH.
2. Both functions return the transaction hash; open `https://sepolia.arbiscan.io/tx/<hash>` to see it.
3. If the user rejects in MetaMask or the transaction fails, the database has already saved; call the function again.
4. The functions switch MetaMask to Arbitrum Sepolia themselves, and throw a clear message if the wrong account is selected.

<!-- address-warning:start -->
5. Never use `user.walletAddress` (Profile.walletAddress), the JWT `addr` claim or a ledger `actorAddress` as a wallet: they are derived from the phone number, not MetaMask accounts.
<!-- address-warning:end -->
