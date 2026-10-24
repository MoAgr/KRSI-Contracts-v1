// Phase 4 test 4: buildReceiptInput from the real ENWR-000006 fixtures returns exactly the expected ReceiptInput,
// and that value encodes against the deployed KrsiReceipt ABI.
import { describe, expect, it } from 'vitest'
import { decodeFunctionData, encodeFunctionData, toFunctionSelector, type Abi } from 'viem'
import receipt from '../fixtures/receipt.json'
import ledger from '../fixtures/receiptLedger.json'
import receiptAbi from '../abis/KrsiReceipt.json'
import { buildReceiptInput, inspectionHash, userRef } from '../krsiChain'

// The ENWR_ISSUED block of the receipt (FINDINGS F7): its hash is the ledger hash to pass.
const issued = ledger.blocks.find((b) => b.eventType === 'ENWR_ISSUED' && b.entityId === String(receipt.id))!

describe('buildReceiptInput', () => {
  it('uses the ENWR_ISSUED block hash, which equals the receipt ledgerHash right after approval', () => {
    expect(issued.hash).toBe(receipt.ledgerHash)
  })

  it('returns the golden ENWR-000006 input', () => {
    expect(buildReceiptInput(receipt, issued.hash)).toEqual({
      tokenId: 6n,
      receiptNo: 'ENWR-000006',
      warehouseSlug: 'agri-vault',
      commodity: 'Coffee',
      grade: 'Raw',
      quantityKg: 20000n,
      storedOn: 1792627200n,
      validTill: 1808179200n,
      moistureBps: 1000,
      foreignMatterBps: 100,
      inspectedOn: 1792689759n,
      inspectionHash: inspectionHash('Fine', 1792689759n),
      ledgerHash: '0x89561c5c9b311b531577de5a72ef7afc25a06176216bcdef2b0a6b62ed7928d0',
    })
  })

  it('turns a null foreign matter reading into 0 bps (D3)', () => {
    expect(buildReceiptInput({ ...receipt, foreignMatterPct: null }, issued.hash).foreignMatterBps).toBe(0)
  })

  it('refuses a receipt that was not inspected or has no ledger hash', () => {
    expect(() => buildReceiptInput({ ...receipt, inspectedAt: null }, issued.hash)).toThrow(/not been inspected/)
    expect(() => buildReceiptInput(receipt, null)).toThrow(/no ledger hash/)
  })

  it('encodes as the issue call of the deployed ABI and decodes back to the same arguments', () => {
    const args = [buildReceiptInput(receipt, issued.hash), userRef(receipt.ownerId)] as const
    const data = encodeFunctionData({ abi: receiptAbi as Abi, functionName: 'issue', args })
    expect(data.slice(0, 10)).toBe(
      toFunctionSelector(
        'issue((uint256,string,string,string,string,uint64,uint64,uint64,uint16,uint16,uint64,bytes32,bytes32),bytes32)',
      ),
    )
    expect(decodeFunctionData({ abi: receiptAbi as Abi, data }).args).toEqual(args)
  })
})
