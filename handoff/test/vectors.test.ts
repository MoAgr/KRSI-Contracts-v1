// Phase 4 test 2: every vector in vectors.json (written by script/GenerateVectors.s.sol) recomputed in TypeScript.
import { describe, expect, it } from 'vitest'
import { hexToString, keccak256, toBytes } from 'viem'
import vectors from '../vectors.json'
import fixture from '../fixtures/receipt.json'
import {
  buildReceiptInput,
  encodeKycData,
  inspectionHash,
  providerBytes,
  userRef,
  type ProviderName,
} from '../krsiChain'

describe('vectors.json', () => {
  it('has every vector TESTS.md Phase 4 lists', () => {
    expect(vectors.userRef.map((v) => v.userId)).toEqual(['1', '42', '101', '102', '9007199254740992'])
    expect(vectors.provider.map((v) => v.name)).toEqual(['SETU_DIGILOCKER', 'DEMO'])
    expect(vectors.warehouseKey.map((v) => v.slug)).toEqual(['agri-vault'])
    expect(vectors.inspectionHash.map((v) => [v.remarks, v.inspectedAt])).toEqual([['Fine', '1792656000'], ['', '0']])
    expect(vectors.kycData.map((v) => v.role)).toEqual([1, 2])
  })

  it.each(vectors.userRef)('userRef($userId)', ({ userId, out }) => {
    expect(userRef(BigInt(userId))).toBe(out)
    expect(userRef(userId)).toBe(out)
  })

  it('userRef accepts the API number for every id up to 2^53 minus 1', () => {
    expect(userRef(101)).toBe(vectors.userRef[2].out)
    expect(() => userRef(9007199254740992)).toThrow() // 2^53 as a number is not a safe integer
  })

  it.each(vectors.provider)('providerBytes($name)', ({ name, out }) => {
    expect(providerBytes(name as ProviderName)).toBe(out)
  })

  it.each(vectors.warehouseKey)('warehouseKey($slug), computed by the contract from the slug', ({ slug, out }) => {
    // The kit never computes this (SPEC 4.10: callers pass only the slug); checked here with viem directly.
    expect(keccak256(toBytes(slug))).toBe(out)
  })

  it.each(vectors.inspectionHash)('inspectionHash("$remarks", $inspectedAt)', ({ remarks, inspectedAt, out }) => {
    expect(inspectionHash(remarks, BigInt(inspectedAt))).toBe(out)
  })

  it('inspectionHash treats a null remark as the empty string', () => {
    expect(inspectionHash(null, 0n)).toBe(vectors.inspectionHash[1].out)
  })

  it.each(vectors.kycData)('encodeKycData for user $userId', ({ userId, userRef: ref, role, provider, kycVerifiedAt, out }) => {
    expect(userRef(userId)).toBe(ref)
    expect(encodeKycData(ref as `0x${string}`, role, providerBytes(provider as ProviderName), BigInt(kycVerifiedAt))).toBe(out)
  })

  it.each(vectors.shortString)('short string rule for $inHex is $out', ({ inHex, out }) => {
    // buildReceiptInput enforces SPEC 4.13 on every short string; run each input through it as the grade.
    const grade = hexToString(inHex as `0x${string}`)
    const build = () => buildReceiptInput({ ...fixture, grade }, fixture.ledgerHash)
    if (out) expect(build().grade).toBe(grade)
    else expect(build).toThrow(/grade/)
  })
})
