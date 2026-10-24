// The two demo steps, ready to call from the dashboard. Each one switches MetaMask to Arbitrum Sepolia, checks the
// signing account, simulates the call (so a revert shows a readable reason), asks MetaMask to sign, and waits.
import {
  createPublicClient,
  createWalletClient,
  custom,
  http,
  zeroHash,
  type Abi,
  type Hex,
  type PublicClient,
  type WalletClient,
} from 'viem'
import { arbitrumSepolia } from 'viem/chains'
import easAbi from './abis/EAS.json'
import receiptAbi from './abis/KrsiReceipt.json'
import {
  addresses,
  buildReceiptInput,
  encodeKycData,
  providerBytes,
  providerFromApi,
  timestampToUnix,
  userRef,
  type ApiReceipt,
} from './krsiChain'

const ROLE_CODE: Record<string, number> = { FARMER: 1, MERCHANT: 2, WAREHOUSE_OWNER: 3 }

export interface Clients {
  wallet: WalletClient
  public: PublicClient
}

/**
 * Step 1: put a user's KYC on chain. Call it after api.kyc.complete returns VERIFIED, with MetaMask on the issuer
 * account. `user` is useAuth().user, `kyc` is the KycStatus, `userWallet` is the user's MetaMask address.
 * Returns the transaction hash.
 */
export async function putKycOnChain(
  user: { id: number; role: string },
  kyc: { status: string; verifiedAt: string | null; provider: string | null },
  userWallet: Hex,
  clients: Clients = metaMask(),
): Promise<Hex> {
  if (kyc.status !== 'VERIFIED' || kyc.verifiedAt === null) throw new Error('KYC is not verified yet')
  const role = ROLE_CODE[user.role]
  if (role === undefined) throw new Error(`${user.role} accounts do not get a KYC credential`)
  const data = encodeKycData(
    userRef(user.id),
    role,
    providerBytes(providerFromApi(kyc.provider)),
    timestampToUnix(kyc.verifiedAt),
  )
  const account = await signer(clients, addresses.issuer, 'issuer')
  return send(clients, {
    account,
    address: addresses.eas,
    abi: easAbi as Abi,
    functionName: 'attest',
    args: [
      {
        schema: addresses.schemaUID,
        data: {
          recipient: userWallet,
          expirationTime: BigInt(Math.floor(Date.now() / 1000) + 365 * 86400),
          revocable: true,
          refUID: zeroHash,
          data,
          value: 0n,
        },
      },
    ],
  })
}

/**
 * Step 2: put an eNWR on chain. Call it with the response of api.enwrs.inspect after an APPROVE, with MetaMask on
 * the auditor account. The owner's KYC must be on chain first. Returns the transaction hash.
 */
export async function putEnwrOnChain(
  enwr: ApiReceipt & { ownerId: number; ledgerHash: string | null },
  clients: Clients = metaMask(),
): Promise<Hex> {
  const args = [buildReceiptInput(enwr, enwr.ledgerHash), userRef(enwr.ownerId)]
  const account = await signer(clients, addresses.auditor, 'auditor')
  return send(clients, { account, address: addresses.receipt, abi: receiptAbi as Abi, functionName: 'issue', args })
}

// ---------- internals ----------

function metaMask(): Clients {
  if (typeof window === 'undefined' || !window.ethereum) throw new Error('MetaMask is not installed')
  return {
    wallet: createWalletClient({ chain: arbitrumSepolia, transport: custom(window.ethereum) }),
    public: createPublicClient({ chain: arbitrumSepolia, transport: http() }),
  }
}

/** Switches MetaMask to Arbitrum Sepolia (adding it if needed) and checks the selected account. */
async function signer(clients: Clients, expected: Hex, role: string): Promise<Hex> {
  try {
    await clients.wallet.switchChain({ id: arbitrumSepolia.id })
  } catch {
    await clients.wallet.addChain({ chain: arbitrumSepolia })
  }
  const [account] = await clients.wallet.requestAddresses()
  if (!account || account.toLowerCase() !== expected.toLowerCase()) {
    throw new Error(`Switch MetaMask to the ${role} account ${expected}`)
  }
  return account
}

async function send(
  clients: Clients,
  call: { account: Hex; address: Hex; abi: Abi; functionName: string; args: readonly unknown[] },
): Promise<Hex> {
  const { request } = await clients.public.simulateContract({ ...call, chain: arbitrumSepolia })
  const hash = await clients.wallet.writeContract(request)
  const receipt = await clients.public.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error(`Transaction ${hash} failed`)
  return hash
}

declare global {
  interface Window {
    ethereum?: import('viem').EIP1193Provider
  }
}
