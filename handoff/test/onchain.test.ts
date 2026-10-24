// The two demo steps with fake MetaMask clients: what they would ask MetaMask to sign, and when they refuse.
import { describe, expect, it } from 'vitest'
import { zeroHash, type Hex } from 'viem'
import profile from '../fixtures/profile.json'
import kyc from '../fixtures/kyc.json'
import receipt from '../fixtures/receipt.json'
import { putEnwrOnChain, putKycOnChain, type Clients } from '../onchain'
import { addresses, buildReceiptInput, encodeKycData, providerBytes, userRef } from '../krsiChain'

const FARMER_WALLET: Hex = '0xD73792F814d3ADb440Ef50F62268978E3F715C13'

function fakeClients(selected: Hex) {
  const sent: Record<string, unknown>[] = []
  const clients = {
    wallet: {
      switchChain: async () => {},
      addChain: async () => {},
      requestAddresses: async () => [selected],
      writeContract: async (request: Record<string, unknown>) => {
        sent.push(request)
        return '0xabc' as Hex
      },
    },
    public: {
      simulateContract: async (call: Record<string, unknown>) => ({ request: call }),
      waitForTransactionReceipt: async () => ({ status: 'success' }),
    },
  } as unknown as Clients
  return { clients, sent }
}

describe('putKycOnChain', () => {
  it('asks the issuer to sign EAS.attest with the KYC data for the user', async () => {
    const { clients, sent } = fakeClients(addresses.issuer)
    expect(await putKycOnChain(profile, kyc, FARMER_WALLET, clients)).toBe('0xabc')
    const [request] = sent as [{ address: Hex; functionName: string; args: [{ schema: Hex; data: Record<string, unknown> }] }]
    expect(request.address).toBe(addresses.eas)
    expect(request.functionName).toBe('attest')
    expect(request.args[0].schema).toBe(addresses.schemaUID)
    expect(request.args[0].data).toMatchObject({
      recipient: FARMER_WALLET,
      revocable: true,
      refUID: zeroHash,
      value: 0n,
      data: encodeKycData(userRef(1), 1, providerBytes('DEMO'), 1792616629n), // demo farmer: provider null is DEMO
    })
    const expiry = request.args[0].data.expirationTime as bigint
    expect(Number(expiry) - Math.floor(Date.now() / 1000)).toBeGreaterThan(365 * 86400 - 60)
  })

  it('refuses the wrong MetaMask account, an unverified user and auditors', async () => {
    await expect(putKycOnChain(profile, kyc, FARMER_WALLET, fakeClients(addresses.auditor).clients)).rejects.toThrow(/issuer account/)
    await expect(putKycOnChain(profile, { ...kyc, status: 'NONE' }, FARMER_WALLET, fakeClients(addresses.issuer).clients)).rejects.toThrow(/not verified/)
    await expect(putKycOnChain({ ...profile, role: 'AUDITOR' }, kyc, FARMER_WALLET, fakeClients(addresses.issuer).clients)).rejects.toThrow(/do not get/)
  })
})

describe('putEnwrOnChain', () => {
  it('asks the auditor to sign KrsiReceipt.issue for the approved receipt', async () => {
    const { clients, sent } = fakeClients(addresses.auditor)
    await putEnwrOnChain(receipt, clients)
    expect(sent).toHaveLength(1)
    expect(sent[0]).toMatchObject({
      address: addresses.receipt,
      functionName: 'issue',
      args: [buildReceiptInput(receipt, receipt.ledgerHash), userRef(receipt.ownerId)],
    })
  })

  it('refuses the wrong MetaMask account before anything is signed', async () => {
    const { clients, sent } = fakeClients(addresses.issuer)
    await expect(putEnwrOnChain(receipt, clients)).rejects.toThrow(/auditor account/)
    expect(sent).toHaveLength(0)
  })
})
