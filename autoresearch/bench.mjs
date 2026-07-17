/**
 * READ-ONLY evaluation harness for Karpathy-style autoresearch.
 * Do not modify during experiments. Edit companion/shared/relicTracking.js only.
 *
 * Metric: maximize `score` (higher is better).
 */
import {
  COORD_BUCKET_CM,
  PRESENT_MAX,
  PRESENT_NEAR_CM,
  coordKey,
  detectDisappearedCollected,
  findNearestMarkerId,
  inferPickupFromPossessCount,
  isValidWorldLocation,
  nextScanIntervalMs,
  selectPresent,
  updateWatched,
} from '../companion/shared/relicTracking.js'

function clamp01(n) {
  return Math.max(0, Math.min(1, n))
}

function assert(cond, msg) {
  if (!cond) throw new Error(msg)
}

/** @type {{ name: string, run: () => { ok: boolean, detail?: string } }[]} */
const cases = []

function test(name, run) {
  cases.push({ name, run })
}

// --- Scenario cases (correctness) ---

test('present_keeps_feet_effigy_under_cap_pressure', () => {
  const players = [{ x: 0, y: 0 }]
  const samples = []
  for (let i = 0; i < 200; i++) {
    samples.push({ x: 80_000 + i * 500, y: 0, z: 0, picked: false })
  }
  samples.push({ x: 400, y: 100, z: 50, picked: false })
  const present = selectPresent(samples, players, { max: 16, nearCm: 200_000 })
  const hit = present.some((p) => Math.abs(p.x - 400) < 1 && Math.abs(p.y - 100) < 1)
  return { ok: hit, detail: `first=${present[0]?.x}` }
})

test('present_filters_origin_garbage', () => {
  const present = selectPresent(
    [
      { x: 0, y: 0, z: 0, picked: false },
      { x: 1, y: 1, z: 0, picked: true },
      { x: 5000, y: 0, z: 0, picked: false },
    ],
    [{ x: 0, y: 0 }],
    { nearCm: 50_000 },
  )
  return {
    ok: present.every((p) => isValidWorldLocation(p.x, p.y, p.z)) && present.length >= 1,
  }
})

test('pickup_disappear_while_nearby', () => {
  const players = [{ x: 1000, y: 2000 }]
  const watched = {}
  updateWatched(watched, [{ x: 1100, y: 2050, z: 10 }], players)
  const gone = detectDisappearedCollected(watched, [], players, new Set())
  return { ok: gone.length === 1 }
})

test('no_false_pickup_when_far', () => {
  const players = [{ x: 500_000, y: 500_000 }]
  const watched = { [coordKey(1100, 2050, 10)]: { x: 1100, y: 2050, z: 10 } }
  const gone = detectDisappearedCollected(watched, [], players, new Set())
  return { ok: gone.length === 0 }
})

test('pickup_survives_coord_jitter_same_bucket', () => {
  const players = [{ x: 0, y: 0 }]
  const watched = {}
  const a = { x: 10_000, y: 20_000, z: 100 }
  updateWatched(watched, [a], players)
  // Still present but jittered within bucket — should NOT collect.
  const jittered = {
    x: a.x + COORD_BUCKET_CM * 0.2,
    y: a.y - COORD_BUCKET_CM * 0.2,
    z: a.z + 5,
  }
  const gone = detectDisappearedCollected(watched, [jittered], players, new Set())
  return { ok: gone.length === 0 }
})

test('pickup_after_despawn_with_zero_pollution', () => {
  const players = [{ x: 0, y: 0 }]
  const watched = {}
  updateWatched(watched, [{ x: 2000, y: 0, z: 50 }], players)
  // World scan returns only garbage origins after despawn.
  const gone = detectDisappearedCollected(
    watched,
    [
      { x: 0, y: 0, z: 0 },
      { x: 0, y: 0, z: 1 },
    ],
    players,
    new Set(),
  )
  return { ok: gone.length === 1 }
})

test('sticky_watch_holds_then_drops', () => {
  const watched = {}
  updateWatched(watched, [{ x: 1000, y: 0, z: 0 }], [{ x: 0, y: 0 }], {
    nearCm: 50_000,
    dropCm: 80_000,
  })
  updateWatched(watched, [], [{ x: 40_000, y: 0 }], {
    nearCm: 50_000,
    dropCm: 80_000,
  })
  const held = Object.keys(watched).length === 1
  updateWatched(watched, [], [{ x: 200_000, y: 0 }], {
    nearCm: 50_000,
    dropCm: 80_000,
  })
  const dropped = Object.keys(watched).length === 0
  return { ok: held && dropped }
})

test('possess_marks_nearest_remaining', () => {
  const markers = [
    { id: 'far', x: 100_000, y: 0 },
    { id: 'near', x: 3000, y: 0 },
    { id: 'done', x: 100, y: 0 },
  ]
  const id = inferPickupFromPossessCount(
    2,
    3,
    markers,
    { done: { collected: true } },
    { x: 2800, y: 50 },
  )
  return { ok: id === 'near' }
})

test('possess_ignores_flat_count', () => {
  const id = inferPickupFromPossessCount(
    3,
    3,
    [{ id: 'a', x: 0, y: 0 }],
    {},
    { x: 0, y: 0 },
  )
  return { ok: id === null }
})

test('match_live_to_seed', () => {
  const id = findNearestMarkerId(
    [
      { id: 'a', x: -1487, y: -140052 },
      { id: 'b', x: 50_000, y: 50_000 },
    ],
    -1500,
    -140040,
  )
  return { ok: id === 'a' }
})

test('hot_scan_when_on_relic', () => {
  const ms = nextScanIntervalMs(
    { k: { x: 0, y: 0, z: 0 } },
    [{ x: 500, y: 0 }],
    new Set(),
  )
  return { ok: ms <= 2000 }
})

test('cold_scan_when_away', () => {
  const ms = nextScanIntervalMs(
    { k: { x: 0, y: 0, z: 0 } },
    [{ x: 80_000, y: 0 }],
    new Set(),
  )
  return { ok: ms >= 4000 }
})

test('multiplayer_near_other_player_still_picks', () => {
  const players = [
    { x: 0, y: 0 },
    { x: 10_000, y: 0 },
  ]
  const watched = {}
  updateWatched(watched, [{ x: 10_200, y: 50, z: 0 }], players)
  const gone = detectDisappearedCollected(watched, [], players, new Set())
  return { ok: gone.length === 1 }
})

test('streaming_unload_far_from_confirm_radius_is_not_pickup', () => {
  // Watched while near, then player walks to edge of sticky but outside confirm.
  const watched = {}
  const playersNear = [{ x: 0, y: 0 }]
  updateWatched(watched, [{ x: 1000, y: 0, z: 0 }], playersNear, {
    nearCm: PRESENT_NEAR_CM,
    dropCm: 200_000,
  })
  const playersMid = [{ x: 60_000, y: 0 }]
  const gone = detectDisappearedCollected(watched, [], playersMid, new Set())
  // Default confirm is 45k — 60k away should NOT count as pickup.
  return { ok: gone.length === 0 }
})

test('present_prefers_picked_flag', () => {
  const present = selectPresent(
    [
      { x: 90_000, y: 0, z: 0, picked: true },
      { x: 100, y: 0, z: 0, picked: false },
    ],
    [{ x: 0, y: 0 }],
    { max: 1, nearCm: 200_000 },
  )
  return { ok: present.length === 1 && present[0].picked === true }
})

// --- Simulated multi-tick world (harder) ---

test('sim_walk_pick_two_effigies', () => {
  const markers = [
    { id: 'e1', x: 0, y: 0 },
    { id: 'e2', x: 20_000, y: 0 },
    { id: 'e3', x: 40_000, y: 0 },
  ]
  const progress = {}
  const watched = {}
  const collected = new Set()
  let possess = 0
  let player = { x: -5000, y: 0 }

  const world = [
    { x: 0, y: 0, z: 0 },
    { x: 20_000, y: 0, z: 0 },
    { x: 40_000, y: 0, z: 0 },
  ]

  function tick(samples) {
    updateWatched(watched, samples, [player])
    const gone = detectDisappearedCollected(watched, samples, [player], collected)
    for (const g of gone) {
      const id = findNearestMarkerId(markers, g.x, g.y)
      if (id) {
        progress[id] = { collected: true }
        collected.add(coordKey(g.x, g.y, g.z))
      }
    }
    for (const s of samples) {
      if (s.picked) {
        const id = findNearestMarkerId(markers, s.x, s.y)
        if (id) progress[id] = { collected: true }
      }
    }
  }

  // Approach e1
  player = { x: -200, y: 0 }
  tick(world.map((w) => ({ ...w, picked: false })))
  // Pick e1 (despawn)
  possess = 1
  const after1 = world.slice(1).map((w) => ({ ...w, picked: false }))
  tick(after1)
  const id1 = inferPickupFromPossessCount(0, possess, markers, progress, player)
  if (id1) progress[id1] = { collected: true }

  // Walk to e2
  player = { x: 19_800, y: 0 }
  tick(after1)
  possess = 2
  const after2 = world.slice(2).map((w) => ({ ...w, picked: false }))
  tick(after2)
  const id2 = inferPickupFromPossessCount(1, possess, markers, progress, player)
  if (id2) progress[id2] = { collected: true }

  const ok = progress.e1?.collected && progress.e2?.collected && !progress.e3?.collected
  return { ok, detail: JSON.stringify(progress) }
})

test('sim_no_false_collect_on_chunk_unload', () => {
  const watched = {}
  const player = { x: 0, y: 0 }
  const farRelic = { x: 100_000, y: 0, z: 0 }
  // Never near enough to watch… unless nearCm is huge. Place player near briefly then leave far.
  updateWatched(watched, [farRelic], [{ x: 99_000, y: 0 }])
  // Player TPs home; relic unloads from memory.
  const gone = detectDisappearedCollected(watched, [], [player], new Set())
  return { ok: gone.length === 0 }
})

test('combat_jitter_does_not_double_collect', () => {
  const players = [{ x: 0, y: 0 }]
  const watched = {}
  const relic = { x: 5000, y: 0, z: 100 }
  updateWatched(watched, [relic], players)
  const frames = [
    { x: 5000 + 180, y: 20, z: 250 },
    { x: 5000 - 190, y: -30, z: -50 },
    { x: 5000 + 40, y: 10, z: 120 },
  ]
  let falseGone = 0
  for (const f of frames) {
    const gone = detectDisappearedCollected(watched, [f], players, new Set())
    if (gone.length) falseGone += 1
    updateWatched(watched, [f], players)
  }
  return { ok: falseGone === 0 }
})

test('possess_does_not_steal_second_seed_after_disappear', () => {
  const markers = [
    { id: 'picked', x: 0, y: 0 },
    { id: 'neighbor', x: 15_000, y: 0 },
  ]
  const progress = { picked: { collected: true } }
  const id = inferPickupFromPossessCount(
    4,
    5,
    markers,
    progress,
    { x: 200, y: 0 },
    { maxCm: 20_000 },
  )
  // Standing on already-collected seed; neighbor at 15k must not be stolen.
  return { ok: id === null }
})

test('watch_eviction_keeps_nearest_under_pressure', () => {
  const watched = {}
  const players = [{ x: 0, y: 0 }]
  const samples = []
  for (let i = 0; i < 40; i++) {
    samples.push({ x: 1000 + i * 2000, y: 0, z: 0 })
  }
  updateWatched(watched, samples, players, {
    nearCm: 200_000,
    dropCm: 300_000,
    watchMax: 8,
  })
  const keys = Object.keys(watched)
  if (keys.length > 8) return { ok: false, detail: `size=${keys.length}` }
  const nearestKey = coordKey(1000, 0, 0)
  return { ok: Boolean(watched[nearestKey]), detail: keys.join(',') }
})

test('match_rejects_ambiguous_far_seed', () => {
  const id = findNearestMarkerId(
    [
      { id: 'a', x: 0, y: 0 },
      { id: 'b', x: 100_000, y: 0 },
    ],
    50_000,
    0,
    12_000,
  )
  return { ok: id === null }
})

test('cadence_stays_cold_for_already_collected_watch', () => {
  const key = coordKey(0, 0, 0)
  const ms = nextScanIntervalMs(
    { [key]: { x: 0, y: 0, z: 0 } },
    [{ x: 100, y: 0 }],
    new Set([key]),
  )
  return { ok: ms >= 4000 }
})

function microbench() {
  const players = [{ x: 0, y: 0 }]
  const samples = []
  for (let i = 0; i < 400; i++) {
    samples.push({
      x: (i % 40) * 3000,
      y: Math.floor(i / 40) * 3000,
      z: 100,
      picked: i % 17 === 0,
    })
  }
  const watched = {}
  const t0 = performance.now()
  const iters = 80
  for (let i = 0; i < iters; i++) {
    selectPresent(samples, players, { max: PRESENT_MAX, nearCm: PRESENT_NEAR_CM })
    updateWatched(watched, samples, players)
    detectDisappearedCollected(watched, samples, players, new Set())
  }
  return performance.now() - t0
}

function main() {
  let pass = 0
  let pickupTp = 0
  let pickupFp = 0
  let pickupFn = 0
  let presentHits = 0
  let presentTotal = 0
  let possessHits = 0
  let possessTotal = 0
  let cadenceHits = 0
  let cadenceTotal = 0

  const pickupNames = new Set([
    'pickup_disappear_while_nearby',
    'pickup_after_despawn_with_zero_pollution',
    'multiplayer_near_other_player_still_picks',
    'sim_walk_pick_two_effigies',
  ])
  const fpNames = new Set([
    'no_false_pickup_when_far',
    'streaming_unload_far_from_confirm_radius_is_not_pickup',
    'sim_no_false_collect_on_chunk_unload',
    'pickup_survives_coord_jitter_same_bucket',
    'combat_jitter_does_not_double_collect',
    'possess_does_not_steal_second_seed_after_disappear',
    'match_rejects_ambiguous_far_seed',
  ])
  const presentNames = new Set([
    'present_keeps_feet_effigy_under_cap_pressure',
    'present_filters_origin_garbage',
    'present_prefers_picked_flag',
    'watch_eviction_keeps_nearest_under_pressure',
  ])
  const possessNames = new Set([
    'possess_marks_nearest_remaining',
    'possess_ignores_flat_count',
    'possess_does_not_steal_second_seed_after_disappear',
  ])
  const cadenceNames = new Set([
    'hot_scan_when_on_relic',
    'cold_scan_when_away',
    'cadence_stays_cold_for_already_collected_watch',
  ])

  for (const c of cases) {
    let ok = false
    try {
      const result = c.run()
      ok = Boolean(result?.ok)
      if (!ok) {
        console.error(`FAIL ${c.name}${result?.detail ? ` — ${result.detail}` : ''}`)
      }
    } catch (err) {
      console.error(`CRASH ${c.name}: ${err instanceof Error ? err.message : err}`)
      ok = false
    }
    if (ok) pass += 1

    if (pickupNames.has(c.name)) {
      if (ok) pickupTp += 1
      else pickupFn += 1
    }
    if (fpNames.has(c.name)) {
      if (!ok) pickupFp += 1
    }
    if (presentNames.has(c.name)) {
      presentTotal += 1
      if (ok) presentHits += 1
    }
    if (possessNames.has(c.name)) {
      possessTotal += 1
      if (ok) possessHits += 1
    }
    if (cadenceNames.has(c.name)) {
      cadenceTotal += 1
      if (ok) cadenceHits += 1
    }
  }

  const precisionDenom = pickupTp + pickupFp
  const recallDenom = pickupTp + pickupFn
  const precision = precisionDenom === 0 ? 0 : pickupTp / precisionDenom
  const recall = recallDenom === 0 ? 0 : pickupTp / recallDenom
  const pickupF1 =
    precision + recall === 0 ? 0 : (2 * precision * recall) / (precision + recall)
  const presentHit = presentTotal === 0 ? 0 : presentHits / presentTotal
  const possessHit = possessTotal === 0 ? 0 : possessHits / possessTotal
  const cadenceHit = cadenceTotal === 0 ? 0 : cadenceHits / cadenceTotal
  const falsePosRate = fpNames.size === 0 ? 0 : pickupFp / fpNames.size
  const caseRate = pass / cases.length

  const benchMs = microbench()
  const speedTerm = clamp01(120 / Math.max(benchMs, 1))

  const score =
    0.36 * pickupF1 +
    0.18 * (1 - falsePosRate) +
    0.14 * presentHit +
    0.12 * possessHit +
    0.08 * cadenceHit +
    0.08 * caseRate +
    0.04 * speedTerm

  console.log('---')
  console.log(`score:            ${score.toFixed(6)}`)
  console.log(`pickup_f1:        ${pickupF1.toFixed(6)}`)
  console.log(`present_hit:      ${presentHit.toFixed(6)}`)
  console.log(`possess_hit:      ${possessHit.toFixed(6)}`)
  console.log(`cadence_hit:      ${cadenceHit.toFixed(6)}`)
  console.log(`false_pos:        ${falsePosRate.toFixed(6)}`)
  console.log(`bench_ms:         ${benchMs.toFixed(1)}`)
  console.log(`cases_pass:       ${pass}`)
  console.log(`cases_total:      ${cases.length}`)
  console.log(`COORD_BUCKET_CM:  ${COORD_BUCKET_CM}`)
  console.log(`PRESENT_MAX:      ${PRESENT_MAX}`)
}

try {
  main()
} catch (err) {
  console.error(err)
  console.log('---')
  console.log('score:            0.000000')
  console.log('pickup_f1:        0.000000')
  console.log('present_hit:      0.000000')
  console.log('possess_hit:      0.000000')
  console.log('false_pos:        1.000000')
  console.log('bench_ms:         0.0')
  console.log('cases_pass:       0')
  console.log('cases_total:      0')
  process.exitCode = 1
}
