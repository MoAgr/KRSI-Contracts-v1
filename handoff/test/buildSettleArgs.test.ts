// Phase 4 test 5: buildSettleArgs from the accept bid response (fixtures/acceptBid.json, synthetic with real keys).
import { describe, expect, it } from 'vitest'
import { encodeFunctionData, type Abi } from 'viem'
import settlement from '../fixtures/acceptBid.json'
import split from '../fixtures/receiptLedgerSplit.json'
import receiptAbi from '../abis/KrsiReceipt.json'
import { buildSettleArgs, userRef } from '../krsiChain'

describe('buildSettleArgs', () => {
  it('builds a split of 12 MT of ENWR-000006 into child ENWR-000007', () => {
    expect(buildSettleArgs(settlement)).toEqual([
      6n, // tokenId: listing.enwrId
      userRef(2), // buyerRef: userRef(trade.buyerId)
      12000n, // qtyKg: mtToKg(trade.quantityMt)
      7n, // childId: buyerReceipt.id
      'ENWR-000007', // childReceiptNo: buyerReceipt.receiptNo
      `0x${settlement.buyerReceipt.ledgerHash}`, // childLedgerHash: the ENWR_SPLIT block hash
      2n, // tradeId: trade.id
    ])
  })

  it('builds a whole sale when the buyer got the listed receipt itself', () => {
    const whole = {
      ...settlement,
      trade: { ...settlement.trade, quantityMt: 20, buyerEnwrId: 6 },
      buyerReceipt: { ...settlement.buyerReceipt, id: 6, receiptNo: 'ENWR-000006', parentId: null },
    }
    expect(buildSettleArgs(whole)).toEqual([6n, userRef(2), 20000n, 0n, '', `0x${'0'.repeat(64)}`, 2n])
  })

  it('does not take a resold child (with a parentId) for a split', () => {
    const resold = {
      ...settlement,
      listing: { ...settlement.listing, enwrId: 7 },
      buyerReceipt: { ...settlement.buyerReceipt, id: 7 },
    }
    expect(buildSettleArgs(resold)[3]).toBe(0n)
  })

  it('agrees with the real TRADE_SETTLED and ENWR_SPLIT payloads (FINDINGS F8 fallback)', () => {
    // Live trade 1 split ENWR-000001: rebuild the settlement from the ledger and check the arguments.
    const settled = split.blocks.find((b) => b.eventType === 'TRADE_SETTLED')!
    const splitBlock = split.blocks.find((b) => b.eventType === 'ENWR_SPLIT')!
    const p = settled.payload as { tradeId: number; buyerId: number; quantityMt: number; sourceEnwrId: number; buyerEnwrId: number }
    const fromLedger = {
      trade: { id: p.tradeId, buyerId: p.buyerId, quantityMt: p.quantityMt },
      listing: { enwrId: p.sourceEnwrId },
      buyerReceipt: { id: p.buyerEnwrId, receiptNo: 'ENWR-000002', ledgerHash: splitBlock.hash },
    }
    expect(buildSettleArgs(fromLedger)).toEqual([1n, userRef(2), 10000n, 2n, 'ENWR-000002', `0x${splitBlock.hash}`, 1n])
  })

  it('encodes as the settle call of the deployed ABI', () => {
    const data = encodeFunctionData({ abi: receiptAbi as Abi, functionName: 'settle', args: [...buildSettleArgs(settlement)] })
    expect(data.length).toBeGreaterThan(10)
  })
})
