import { describe, expect, it } from 'vitest'
import {
  anyPlayerNear,
  coordKey,
  detectDisappearedCollected,
  findNearestMarkerId,
  inferPickupFromPossessCount,
  isValidWorldLocation,
  nextScanIntervalMs,
  selectPresent,
  updateWatched,
} from '../../shared/relicTracking.js'

describe('coordKey + location validity', () => {
  it('buckets nearby jitter into the same key', () => {
    expect(coordKey(1000, 2000, 300)).toBe(coordKey(1040, 1960, 900))
  })

  it('rejects origin garbage locations', () => {
    expect(isValidWorldLocation(0, 0, 0)).toBe(false)
    expect(isValidWorldLocation(10, -5, 100)).toBe(false)
    expect(isValidWorldLocation(-1487, -140052, 5577)).toBe(true)
  })
})

describe('selectPresent', () => {
  const players = [{ x: 0, y: 0 }]

  it('keeps the nearest relics when capping, not first-seen', () => {
    const samples = []
    for (let i = 0; i < 80; i++) {
      samples.push({ x: 200_000 + i * 1000, y: 0, z: 0, picked: false })
    }
    samples.push({ x: 500, y: 0, z: 10, picked: false })

    const present = selectPresent(samples, players, { max: 8, nearCm: 300_000 })
    expect(present[0].x).toBe(500)
    expect(present.length).toBe(8)
  })

  it('always includes picked relics even when far', () => {
    const present = selectPresent(
      [
        { x: 900_000, y: 900_000, z: 0, picked: true },
        { x: 100, y: 0, z: 0, picked: false },
      ],
      players,
      { max: 2, nearCm: 50_000 },
    )
    expect(present.some((p) => p.picked)).toBe(true)
  })

  it('drops invalid zero locations', () => {
    const present = selectPresent(
      [
        { x: 0, y: 0, z: 0, picked: false },
        { x: 1000, y: 0, z: 0, picked: false },
      ],
      players,
      { nearCm: 50_000 },
    )
    expect(present).toHaveLength(1)
    expect(present[0].x).toBe(1000)
  })
})

describe('disappearance pickup detection', () => {
  it('marks vanished nearby watched relics as collected', () => {
    const watched = {
      [coordKey(1000, 2000, 0)]: { x: 1000, y: 2000, z: 0 },
    }
    const players = [{ x: 1200, y: 2100 }]
    const gone = detectDisappearedCollected(watched, [], players, new Set())
    expect(gone).toHaveLength(1)
    expect(gone[0].x).toBe(1000)
  })

  it('does not mark far vanish as collected', () => {
    const watched = {
      [coordKey(1000, 2000, 0)]: { x: 1000, y: 2000, z: 0 },
    }
    const players = [{ x: 500_000, y: 500_000 }]
    const gone = detectDisappearedCollected(watched, [], players, new Set())
    expect(gone).toHaveLength(0)
  })

  it('does not remount already collected keys', () => {
    const key = coordKey(1000, 2000, 0)
    const watched = { [key]: { x: 1000, y: 2000, z: 0 } }
    const players = [{ x: 1000, y: 2000 }]
    const gone = detectDisappearedCollected(watched, [], players, new Set([key]))
    expect(gone).toHaveLength(0)
  })
})

describe('sticky watch', () => {
  it('keeps a relic after player walks a bit, drops when far', () => {
    const watched = {}
    updateWatched(
      watched,
      [{ x: 1000, y: 0, z: 0 }],
      [{ x: 0, y: 0 }],
      { nearCm: 50_000, dropCm: 80_000 },
    )
    expect(Object.keys(watched)).toHaveLength(1)

    updateWatched(watched, [], [{ x: 40_000, y: 0 }], {
      nearCm: 50_000,
      dropCm: 80_000,
    })
    expect(Object.keys(watched)).toHaveLength(1)

    updateWatched(watched, [], [{ x: 200_000, y: 0 }], {
      nearCm: 50_000,
      dropCm: 80_000,
    })
    expect(Object.keys(watched)).toHaveLength(0)
  })
})

describe('possess-count pickup inference', () => {
  const markers = [
    { id: 'a', x: 0, y: 0 },
    { id: 'b', x: 10_000, y: 0 },
    { id: 'c', x: 80_000, y: 0 },
  ]

  it('marks the nearest remaining seed when count rises', () => {
    const id = inferPickupFromPossessCount(
      3,
      4,
      markers,
      { a: { collected: true } },
      { x: 9500, y: 100 },
    )
    expect(id).toBe('b')
  })

  it('does nothing when count is flat or falling', () => {
    expect(
      inferPickupFromPossessCount(4, 4, markers, {}, { x: 0, y: 0 }),
    ).toBeNull()
    expect(
      inferPickupFromPossessCount(4, 3, markers, {}, { x: 0, y: 0 }),
    ).toBeNull()
  })

  it('ignores seeds outside pickup radius', () => {
    const id = inferPickupFromPossessCount(
      1,
      2,
      markers,
      {},
      { x: 500_000, y: 0 },
      { maxCm: 25_000 },
    )
    expect(id).toBeNull()
  })
})

describe('marker matching + scan cadence', () => {
  it('matches live coords to seed within radius', () => {
    const id = findNearestMarkerId(
      [{ id: 'shrine', x: -1487, y: -140052 }],
      -1490,
      -140050,
      8000,
    )
    expect(id).toBe('shrine')
  })

  it('speeds up scanning when standing on a watched relic', () => {
    const watched = { k: { x: 0, y: 0, z: 0 } }
    expect(nextScanIntervalMs(watched, [{ x: 100, y: 0 }], new Set())).toBe(1500)
    expect(
      nextScanIntervalMs(watched, [{ x: 100_000, y: 0 }], new Set()),
    ).toBe(5000)
  })

  it('reports players near a point', () => {
    expect(anyPlayerNear([{ x: 0, y: 0 }], 1000, 0, 2000)).toBe(true)
    expect(anyPlayerNear([{ x: 0, y: 0 }], 5000, 0, 2000)).toBe(false)
  })
})
