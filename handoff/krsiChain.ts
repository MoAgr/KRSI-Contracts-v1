// chainStorage handoff kit (SPEC 8.3): every conversion from KRSI API values to contract arguments.
// Each function here mirrors one rule of SPEC section 4 and is pinned to the Solidity library by vectors.json.
import { encodeAbiParameters, keccak256, stringToHex, toBytes, type Hex } from 'viem'
import deployments from './deployments.json'

export const CHAIN_ID = 421614

/** The live deployment (deployments/421614.json): contract addresses, schemaUID, accounts and deployedAtBlock. */
export const addresses = deployments as {
  chainId: number
  eas: Hex
  schemaRegistry: Hex
  kycResolver: Hex
  receipt: Hex
  schema: string
  schemaUID: Hex
  admin: Hex
  issuer: Hex
  auditor: Hex
  warehouseOwner: Hex
  demoWarehouseSlug: string
  deployedAtBlock: number
}

/** SPEC 5.1, byte for byte. */
export const SCHEMA = 'bytes32 userRef,uint8 role,bytes32 provider,uint64 kycVerifiedAt'

export type ProviderName = 'SETU_DIGILOCKER' | 'DEMO'

/** KrsiReceipt.ReceiptInput, field for field (SPEC 6.2). Pass it as the first argument of `issue`. */
export interface ReceiptInput {
  tokenId: bigint
  receiptNo: string
  warehouseSlug: string
  commodity: string
  grade: string
  quantityKg: bigint
  storedOn: bigint
  validTill: bigint
  moistureBps: number
  foreignMatterBps: number
  inspectedOn: bigint
  inspectionHash: Hex
  ledgerHash: Hex
}

/** The fields of the dashboard's `Enwr` (src/api/types.ts) that issue needs. Decimals arrive as JSON numbers. */
export interface ApiReceipt {
  id: number
  receiptNo: string
  warehouseId: string
  commodity: string
  grade: string
  quantityMt: number | string
  storedOn: string
  validTill: string
  moisturePct: number | string | null
  foreignMatterPct: number | string | null
  qualityRemarks: string | null
  inspectedAt: string | null
}

/** The fields of the dashboard's `Settlement` (POST /api/bids/{id}/accept) that settle needs (FINDINGS F8). */
export interface ApiSettlement {
  trade: { id: number; buyerId: number; quantityMt: number | string }
  listing: { enwrId: number }
  buyerReceipt: { id: number; receiptNo: string; ledgerHash: string | null }
}

/** settle's arguments in order: tokenId, buyerRef, qtyKg, childId, childReceiptNo, childLedgerHash, tradeId. */
export type SettleArgs = readonly [bigint, Hex, bigint, bigint, string, Hex, bigint]

const UINT64_MAX = (1n << 64n) - 1n
const ZERO_HASH: Hex = `0x${'0'.repeat(64)}`
const DECIMAL = /^(\d+)(?:\.(\d+))?$/

// ---------- SPEC 4.1 to 4.3 ----------

/** SPEC 4.1: keccak256(abi.encode("KRSI_USER", uint256 userId)). userId is Profile.id (the JWT sub). */
export function userRef(userId: number | bigint | string): Hex {
  return keccak256(encodeAbiParameters([{ type: 'string' }, { type: 'uint256' }], ['KRSI_USER', toUint(userId, 'userId')]))
}

/** SPEC 4.3: the name as bytes32, left aligned and zero padded like Solidity's bytes32("..."). */
export function providerBytes(name: ProviderName): Hex {
  if (name !== 'SETU_DIGILOCKER' && name !== 'DEMO') throw new Error(`Unknown provider name: ${String(name)}`)
  return stringToHex(name, { size: 32 })
}

/** SPEC 4.3 (DEVIATIONS D4): KycStatus.provider "setu" is SETU_DIGILOCKER; "mock" or null is DEMO. */
export function providerFromApi(provider: string | null): ProviderName {
  if (provider === 'setu') return 'SETU_DIGILOCKER'
  if (provider === 'mock' || provider === null) return 'DEMO'
  throw new Error(`Unknown KYC provider from the API: ${provider}`)
}

// ---------- SPEC 4.4 to 4.6 ----------

/** SPEC 4.4 (DEVIATIONS D2): quantity in MT, as a decimal string or the API's JSON number, to integer kg. */
export function mtToKg(value: string | number): bigint {
  const { whole, fraction } = parseDecimal(value, 3, 'quantity')
  const kg = whole * 1000n + BigInt(fraction.padEnd(3, '0'))
  if (kg > UINT64_MAX) throw new Error(`Quantity ${String(value)} MT does not fit uint64 kg`)
  return kg
}

/** SPEC 4.5 (DEVIATIONS D2, D3): percent to basis points, 0 to 10000. A null reading is 0 bps. */
export function pctToBps(value: string | number | null): number {
  if (value === null) return 0
  const { whole, fraction } = parseDecimal(value, 2, 'percentage')
  const bps = whole * 100n + BigInt(fraction.padEnd(2, '0'))
  if (bps > 10000n) throw new Error(`Percentage ${String(value)} is above 100`)
  return Number(bps)
}

/** SPEC 4.6: a DATE ("yyyy-MM-dd") as unix seconds at 00:00:00 UTC. */
export function dateToUnix(yyyyMmDd: string): bigint {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(yyyyMmDd)
  if (!m) throw new Error(`Not a yyyy-MM-dd date: ${yyyyMmDd}`)
  return BigInt(utcSeconds(Number(m[1]), Number(m[2]), Number(m[3]), 0, 0, 0, yyyyMmDd))
}

/**
 * SPEC 4.6: an ISO 8601 timestamp (inspectedAt, verifiedAt) as unix seconds, rounded down. Parsed by hand
 * because the API sends up to 6 fraction digits (FINDINGS F11), more than Date.parse is guaranteed to read.
 */
export function timestampToUnix(isoString: string): bigint {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$/.exec(isoString)
  if (!m) throw new Error(`Not an ISO 8601 timestamp with a zone: ${isoString}`)
  const local = utcSeconds(Number(m[1]), Number(m[2]), Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6]), isoString)
  const zone = m[7]
  const offset = zone === 'Z' ? 0 : (zone.startsWith('-') ? -1 : 1) * (Number(zone.slice(1, 3)) * 3600 + Number(zone.slice(4, 6)) * 60)
  const seconds = local - offset
  if (seconds < 0) throw new Error(`Timestamp before 1970: ${isoString}`)
  return BigInt(seconds)
}

// ---------- SPEC 4.8, 4.9 and 4.12 ----------

/** SPEC 4.8: keccak256(abi.encode(string qualityRemarks, uint64 inspectedAtSeconds)); a null remark is "". */
export function inspectionHash(remarks: string | null, inspectedAtSeconds: bigint | number): Hex {
  const at = toUint(inspectedAtSeconds, 'inspectedAtSeconds')
  if (at > UINT64_MAX) throw new Error('inspectedAtSeconds does not fit uint64')
  return keccak256(encodeAbiParameters([{ type: 'string' }, { type: 'uint64' }], [remarks ?? '', at]))
}

/** SPEC 4.9: the API's 64 hex character ledger_hash as bytes32 (adds 0x, lowercases). */
export function ledgerHashToBytes32(hex64: string): Hex {
  if (!/^[0-9a-fA-F]{64}$/.test(hex64)) throw new Error(`A ledger hash is exactly 64 hex characters: ${hex64}`)
  return `0x${hex64.toLowerCase()}`
}

/** SPEC 4.12: the attestation data, abi.encode(bytes32 userRef, uint8 role, bytes32 provider, uint64 kycVerifiedAt). */
export function encodeKycData(userRef_: Hex, role: number, provider: Hex, kycVerifiedAt: bigint): Hex {
  if (!/^0x[0-9a-fA-F]{64}$/.test(userRef_)) throw new Error('userRef must be bytes32')
  if (role !== 1 && role !== 2 && role !== 3) throw new Error(`Role code must be 1, 2 or 3 (auditors are not attested): ${role}`)
  if (!/^0x[0-9a-fA-F]{64}$/.test(provider)) throw new Error('provider must be bytes32 (use providerBytes)')
  if (kycVerifiedAt < 0n || kycVerifiedAt > UINT64_MAX) throw new Error('kycVerifiedAt does not fit uint64')
  return encodeAbiParameters(
    [{ type: 'bytes32' }, { type: 'uint8' }, { type: 'bytes32' }, { type: 'uint64' }],
    [userRef_, role, provider, kycVerifiedAt],
  )
}

// ---------- builders for the two contract calls that take API objects ----------

/**
 * The `issue` argument for a receipt just approved at inspection (POST /api/enwrs/{id}/inspection returns it,
 * FINDINGS F9). ledgerHash is that response's ledgerHash: the ENWR_ISSUED block hash.
 */
export function buildReceiptInput(apiReceipt: ApiReceipt, ledgerHash: string | null): ReceiptInput {
  const r = apiReceipt
  if (r.inspectedAt === null) throw new Error(`Receipt ${r.receiptNo} has not been inspected yet`)
  if (ledgerHash === null) throw new Error(`Receipt ${r.receiptNo} has no ledger hash`)
  const inspectedOn = timestampToUnix(r.inspectedAt)
  return {
    tokenId: toUint(r.id, 'id'),
    receiptNo: shortString(r.receiptNo, 'receiptNo'),
    warehouseSlug: shortString(r.warehouseId, 'warehouseId'),
    commodity: shortString(r.commodity, 'commodity'),
    grade: shortString(r.grade, 'grade'),
    quantityKg: mtToKg(r.quantityMt),
    storedOn: dateToUnix(r.storedOn),
    validTill: dateToUnix(r.validTill),
    moistureBps: pctToBps(r.moisturePct),
    foreignMatterBps: pctToBps(r.foreignMatterPct),
    inspectedOn,
    inspectionHash: inspectionHash(r.qualityRemarks, inspectedOn),
    ledgerHash: ledgerHashToBytes32(ledgerHash),
  }
}

/**
 * settle's arguments from the accept bid response (FINDINGS F8). A whole sale is when the buyer received the
 * listed receipt itself; it passes childId 0, an empty child receipt number and a zero child ledger hash.
 */
export function buildSettleArgs(settlement: ApiSettlement): SettleArgs {
  const { trade, listing, buyerReceipt } = settlement
  const tokenId = toUint(listing.enwrId, 'listing.enwrId')
  const buyerRef = userRef(trade.buyerId)
  const qtyKg = mtToKg(trade.quantityMt)
  const tradeId = toUint(trade.id, 'trade.id')
  if (buyerReceipt.id === listing.enwrId) return [tokenId, buyerRef, qtyKg, 0n, '', ZERO_HASH, tradeId]
  if (buyerReceipt.ledgerHash === null) throw new Error(`Child receipt ${buyerReceipt.receiptNo} has no ledger hash`)
  return [
    tokenId,
    buyerRef,
    qtyKg,
    toUint(buyerReceipt.id, 'buyerReceipt.id'),
    shortString(buyerReceipt.receiptNo, 'buyerReceipt.receiptNo'),
    ledgerHashToBytes32(buyerReceipt.ledgerHash),
    tradeId,
  ]
}

// ---------- internals ----------

function toUint(value: number | bigint | string, name: string): bigint {
  if (typeof value === 'bigint') {
    if (value < 0n) throw new Error(`${name} must not be negative`)
    return value
  }
  if (typeof value === 'number') {
    if (!Number.isSafeInteger(value) || value < 0) throw new Error(`${name} must be a non negative safe integer: ${value}`)
    return BigInt(value)
  }
  if (!/^\d+$/.test(value)) throw new Error(`${name} must be a decimal integer: ${value}`)
  return BigInt(value)
}

/** SPEC 4.4 and 4.5: a JSON number goes through String(n) first; the string must be digits with an optional fraction. */
function parseDecimal(value: string | number, maxDecimals: number, what: string): { whole: bigint; fraction: string } {
  if (typeof value === 'number' && !Number.isFinite(value)) throw new Error(`Not a finite ${what}: ${value}`)
  const text = typeof value === 'number' ? String(value) : value
  const m = DECIMAL.exec(text)
  if (!m) throw new Error(`Not a plain decimal ${what}: ${text}`)
  const fraction = m[2] ?? ''
  if (fraction.length > maxDecimals) throw new Error(`A ${what} has at most ${maxDecimals} decimals: ${text}`)
  return { whole: BigInt(m[1]), fraction }
}

function utcSeconds(y: number, mo: number, d: number, h: number, mi: number, s: number, input: string): number {
  const ms = Date.UTC(y, mo - 1, d, h, mi, s)
  const back = new Date(ms)
  if (
    back.getUTCFullYear() !== y || back.getUTCMonth() !== mo - 1 || back.getUTCDate() !== d ||
    back.getUTCHours() !== h || back.getUTCMinutes() !== mi || back.getUTCSeconds() !== s
  ) throw new Error(`Not a real date or time: ${input}`)
  return ms / 1000
}

/** SPEC 4.13: 1 to 64 bytes of printable ASCII without double quote or backslash; issue reverts otherwise. */
function shortString(value: string, field: string): string {
  const bytes = toBytes(value)
  const ok = bytes.length >= 1 && bytes.length <= 64 && bytes.every((b) => b >= 0x20 && b <= 0x7e && b !== 0x22 && b !== 0x5c)
  if (!ok) throw new Error(`${field} "${value}" is not 1 to 64 printable ASCII characters without quotes or backslashes`)
  return value
}
