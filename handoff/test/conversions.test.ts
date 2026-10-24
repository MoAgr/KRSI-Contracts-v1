// Phase 4 test 3: the SPEC 4 conversions, including DEVIATIONS D2 (numbers), D3 (null percent) and D4 (provider).
import { describe, expect, it } from 'vitest'
import { dateToUnix, ledgerHashToBytes32, mtToKg, pctToBps, providerFromApi, timestampToUnix } from '../krsiChain'

describe('mtToKg', () => {
  it('converts decimal strings', () => {
    expect(mtToKg('20.000')).toBe(20000n)
    expect(mtToKg('0.001')).toBe(1n)
    expect(mtToKg('12.5')).toBe(12500n)
  })
  it('rejects more than 3 decimals and non numbers', () => {
    expect(() => mtToKg('1.2345')).toThrow()
    expect(() => mtToKg('abc')).toThrow()
  })
  it('converts the JSON numbers the API sends (D2)', () => {
    expect(mtToKg(20)).toBe(20000n)
    expect(mtToKg(12.5)).toBe(12500n)
    expect(mtToKg(0.001)).toBe(1n)
    expect(() => mtToKg(1.2345)).toThrow()
    expect(() => mtToKg(0.1 + 0.2)).toThrow()
    expect(() => mtToKg(1e21)).toThrow()
    expect(() => mtToKg(NaN)).toThrow()
  })
  it('accepts only plain decimals', () => {
    for (const bad of ['1e3', '-1', ' 20', '20.', '.5']) expect(() => mtToKg(bad)).toThrow()
  })
})

describe('pctToBps', () => {
  it('converts decimal strings', () => {
    expect(pctToBps('10.00')).toBe(1000)
    expect(pctToBps('0')).toBe(0)
    expect(pctToBps('100.00')).toBe(10000)
  })
  it('rejects more than 2 decimals and more than 100 percent', () => {
    expect(() => pctToBps('10.005')).toThrow()
    expect(() => pctToBps('100.01')).toThrow()
  })
  it('converts numbers (D2) and null (D3)', () => {
    expect(pctToBps(10)).toBe(1000)
    expect(pctToBps(0.5)).toBe(50)
    expect(() => pctToBps(10.005)).toThrow()
    expect(() => pctToBps(1e-7)).toThrow()
    expect(pctToBps(null)).toBe(0)
  })
})

describe('providerFromApi (D4)', () => {
  it('maps the API provider to the SPEC 4.3 name', () => {
    expect(providerFromApi('setu')).toBe('SETU_DIGILOCKER')
    expect(providerFromApi('mock')).toBe('DEMO')
    expect(providerFromApi(null)).toBe('DEMO')
    expect(() => providerFromApi('digilocker')).toThrow()
  })
})

describe('dateToUnix', () => {
  it('gives 00:00:00 UTC of the date', () => {
    expect(dateToUnix('2026-10-22')).toBe(1792627200n)
    expect(dateToUnix('2027-04-20')).toBe(1808179200n)
    expect(dateToUnix('2027-04-20') - dateToUnix('2026-10-22')).toBe(180n * 86400n)
  })
  it('rejects other formats and impossible dates', () => {
    for (const bad of ['22/10/2026', '2026-10-22T00:00:00Z', '2026-02-30', '2026-13-01']) expect(() => dateToUnix(bad)).toThrow()
  })
})

describe('timestampToUnix', () => {
  it('rounds down and reads every fraction length the API sends (FINDINGS F11)', () => {
    expect(timestampToUnix('2026-10-22T17:22:39.051791Z')).toBe(1792689759n)
    expect(timestampToUnix('2026-10-22T17:22:39.999Z')).toBe(1792689759n)
    expect(timestampToUnix('2026-10-22T17:22:39Z')).toBe(1792689759n)
    expect(timestampToUnix('2026-10-22T22:52:39.5+05:30')).toBe(1792689759n)
    expect(timestampToUnix('2026-10-21T21:03:49.879804Z')).toBe(1792616629n) // the demo farmer's verifiedAt
  })
  it('requires a zone', () => {
    expect(() => timestampToUnix('2026-10-22T17:22:39')).toThrow()
    expect(() => timestampToUnix('2026-10-22')).toThrow()
  })
})

describe('ledgerHashToBytes32', () => {
  const hash = '89561c5c9b311b531577de5a72ef7afc25a06176216bcdef2b0a6b62ed7928d0'
  it('adds 0x and lowercases', () => {
    expect(ledgerHashToBytes32(hash)).toBe(`0x${hash}`)
    expect(ledgerHashToBytes32(hash.toUpperCase())).toBe(`0x${hash}`)
  })
  it('rejects anything but 64 hex characters', () => {
    for (const bad of [hash.slice(1), `${hash}0`, `0x${hash}`, `${hash.slice(1)}g`, '']) expect(() => ledgerHashToBytes32(bad)).toThrow()
  })
})
