/**
 * Pure relic / Lifmunk tracking helpers shared by the companion + tests.
 * Keep in sync with bridge/PalworldAssistBridge/Scripts/main.lua behavior.
 */

export const COORD_BUCKET_CM = 200
export const PRESENT_NEAR_CM = 120_000
export const STICKY_DROP_CM = 180_000
export const DISAPPEAR_CONFIRM_CM = 45_000
export const PRESENT_MAX = 48
export const MATCH_MAX_CM = 12_000
export const POSSESS_PICK_MAX_CM = 25_000

/** @param {number} n */
export function isFiniteNumber(n) {
  return typeof n === 'number' && Number.isFinite(n)
}

/**
 * Stable spatial bucket used by bridge + liveWatcher for collected dedupe.
 * @param {number} x
 * @param {number} y
 * @param {number} [z]
 */
export function coordKey(x, y, z = 0) {
  return `${Math.round(x / COORD_BUCKET_CM)}:${Math.round(y / COORD_BUCKET_CM)}:${Math.round(z / COORD_BUCKET_CM)}`
}

/**
 * Reject origin/garbage actor locations (common after despawn / invalid root).
 * @param {number} x
 * @param {number} y
 * @param {number} [z]
 */
export function isValidWorldLocation(x, y, z = 0) {
  if (!isFiniteNumber(x) || !isFiniteNumber(y) || !isFiniteNumber(z)) return false
  if (Math.abs(x) < 50 && Math.abs(y) < 50) return false
  return true
}

/**
 * @param {number} ax
 * @param {number} ay
 * @param {number} bx
 * @param {number} by
 */
export function dist2(ax, ay, bx, by) {
  const dx = ax - bx
  const dy = ay - by
  return dx * dx + dy * dy
}

/**
 * @param {{ x: number, y: number }[]} players
 * @param {number} x
 * @param {number} y
 * @param {number} maxDist
 */
export function anyPlayerNear(players, x, y, maxDist) {
  const max2 = maxDist * maxDist
  for (const p of players) {
    if (!isFiniteNumber(p.x) || !isFiniteNumber(p.y)) continue
    if (dist2(p.x, p.y, x, y) <= max2) return true
  }
  return false
}

/**
 * @param {{ x: number, y: number }[]} players
 * @param {number} x
 * @param {number} y
 */
export function minDist2ToPlayers(players, x, y) {
  let best = Number.POSITIVE_INFINITY
  for (const p of players) {
    if (!isFiniteNumber(p.x) || !isFiniteNumber(p.y)) continue
    const d2 = dist2(p.x, p.y, x, y)
    if (d2 < best) best = d2
  }
  return best
}

/**
 * @typedef {{ x: number, y: number, z?: number, picked?: boolean }} RelicSample
 * @typedef {{ x: number, y: number }} PlayerSample
 * @typedef {{ x: number, y: number, z: number }} WatchedRelic
 */

/**
 * Build the emit list: picked relics + nearest-to-players, capped.
 * Sorts by distance so PRESENT_MAX cannot drop the effigy at your feet.
 *
 * @param {RelicSample[]} samples
 * @param {PlayerSample[]} players
 * @param {{ nearCm?: number, max?: number }} [opts]
 */
export function selectPresent(samples, players, opts = {}) {
  const nearCm = opts.nearCm ?? PRESENT_NEAR_CM
  const max = opts.max ?? PRESENT_MAX
  const near2 = nearCm * nearCm
  const noPlayers = !players || players.length === 0

  /** @type {Array<RelicSample & { dist2: number }>} */
  const scored = []
  for (const s of samples) {
    if (!s || !isValidWorldLocation(s.x, s.y, s.z ?? 0)) continue
    const d2 = noPlayers ? 0 : minDist2ToPlayers(players, s.x, s.y)
    const picked = s.picked === true
    if (!picked && !noPlayers && d2 > near2) continue
    scored.push({
      x: s.x,
      y: s.y,
      z: s.z ?? 0,
      picked,
      dist2: picked ? -1 : d2,
    })
  }

  scored.sort((a, b) => a.dist2 - b.dist2)

  /** @type {RelicSample[]} */
  const out = []
  const seen = new Set()
  for (const s of scored) {
    const key = coordKey(s.x, s.y, s.z)
    if (seen.has(key)) continue
    seen.add(key)
    out.push({ x: s.x, y: s.y, z: s.z, picked: s.picked })
    if (out.length >= max) break
  }
  return out
}

/**
 * Sticky watch update: keep nearby relics until players walk far away.
 *
 * @param {Record<string, WatchedRelic>} watched
 * @param {RelicSample[]} samples
 * @param {PlayerSample[]} players
 * @param {{ nearCm?: number, dropCm?: number, watchMax?: number }} [opts]
 */
export function updateWatched(watched, samples, players, opts = {}) {
  const nearCm = opts.nearCm ?? PRESENT_NEAR_CM
  const dropCm = opts.dropCm ?? STICKY_DROP_CM
  const watchMax = opts.watchMax ?? 256

  for (const s of samples) {
    if (!s || !isValidWorldLocation(s.x, s.y, s.z ?? 0)) continue
    if (!anyPlayerNear(players, s.x, s.y, nearCm) && s.picked !== true) continue
    const key = coordKey(s.x, s.y, s.z ?? 0)
    watched[key] = { x: s.x, y: s.y, z: s.z ?? 0 }
  }

  for (const key of Object.keys(watched)) {
    const it = watched[key]
    if (!anyPlayerNear(players, it.x, it.y, dropCm)) {
      delete watched[key]
    }
  }

  const keys = Object.keys(watched)
  if (keys.length > watchMax) {
    // Drop farthest from any player first.
    keys
      .map((key) => ({
        key,
        d2: minDist2ToPlayers(players, watched[key].x, watched[key].y),
      }))
      .sort((a, b) => b.d2 - a.d2)
      .slice(0, keys.length - watchMax)
      .forEach(({ key }) => {
        delete watched[key]
      })
  }

  return watched
}

/**
 * Previously watched relics that vanished while a player is still nearby ⇒ collected.
 *
 * @param {Record<string, WatchedRelic>} watched
 * @param {RelicSample[]} currentSamples
 * @param {PlayerSample[]} players
 * @param {Set<string> | Record<string, boolean>} alreadyCollected
 * @param {{ confirmCm?: number }} [opts]
 * @returns {WatchedRelic[]}
 */
export function detectDisappearedCollected(
  watched,
  currentSamples,
  players,
  alreadyCollected,
  opts = {},
) {
  const confirmCm = opts.confirmCm ?? DISAPPEAR_CONFIRM_CM
  const currentKeys = new Set()
  for (const s of currentSamples) {
    if (!s || !isValidWorldLocation(s.x, s.y, s.z ?? 0)) continue
    currentKeys.add(coordKey(s.x, s.y, s.z ?? 0))
  }

  /** @type {WatchedRelic[]} */
  const found = []
  for (const [key, it] of Object.entries(watched)) {
    if (currentKeys.has(key)) continue
    if (hasCollected(alreadyCollected, key)) continue
    if (!anyPlayerNear(players, it.x, it.y, confirmCm)) continue
    found.push({ x: it.x, y: it.y, z: it.z })
  }
  return found
}

/**
 * @param {Set<string> | Record<string, boolean>} bag
 * @param {string} key
 */
function hasCollected(bag, key) {
  if (bag instanceof Set) return bag.has(key)
  return Boolean(bag[key])
}

/**
 * When in-game possess count rises, pick the nearest remaining seed near the player.
 *
 * @param {number | null | undefined} prevCount
 * @param {number | null | undefined} nextCount
 * @param {{ id: string, x: number, y: number }[]} markers
 * @param {Record<string, { collected?: boolean }>} progress
 * @param {PlayerSample | null | undefined} player
 * @param {{ maxCm?: number }} [opts]
 */
export function inferPickupFromPossessCount(
  prevCount,
  nextCount,
  markers,
  progress,
  player,
  opts = {},
) {
  if (
    !isFiniteNumber(prevCount) ||
    !isFiniteNumber(nextCount) ||
    nextCount <= prevCount ||
    !player ||
    !isFiniteNumber(player.x) ||
    !isFiniteNumber(player.y)
  ) {
    return null
  }

  const maxCm = opts.maxCm ?? POSSESS_PICK_MAX_CM
  const max2 = maxCm * maxCm
  let bestId = null
  let best2 = max2

  for (const m of markers) {
    if (!m || progress[m.id]?.collected) continue
    if (!isFiniteNumber(m.x) || !isFiniteNumber(m.y)) continue
    const d2 = dist2(player.x, player.y, m.x, m.y)
    if (d2 <= best2) {
      best2 = d2
      bestId = m.id
    }
  }
  return bestId
}

/**
 * @param {{ id: string, x: number, y: number }[]} markers
 * @param {number} x
 * @param {number} y
 * @param {number} [maxDist]
 */
export function findNearestMarkerId(markers, x, y, maxDist = MATCH_MAX_CM) {
  if (!isFiniteNumber(x) || !isFiniteNumber(y)) return null
  const max2 = maxDist * maxDist
  let bestId = null
  let best2 = max2
  for (const m of markers) {
    if (!m || !isFiniteNumber(m.x) || !isFiniteNumber(m.y)) continue
    const d2 = dist2(m.x, m.y, x, y)
    if (d2 <= best2) {
      best2 = d2
      bestId = m.id
    }
  }
  return bestId
}

/**
 * Adaptive scan cadence: faster while a player is standing on a watched relic.
 *
 * @param {Record<string, WatchedRelic>} watched
 * @param {PlayerSample[]} players
 * @param {Set<string> | Record<string, boolean>} alreadyCollected
 * @param {{ hotCm?: number, hotMs?: number, coldMs?: number }} [opts]
 */
export function nextScanIntervalMs(watched, players, alreadyCollected, opts = {}) {
  const hotCm = opts.hotCm ?? 15_000
  const hotMs = opts.hotMs ?? 1500
  const coldMs = opts.coldMs ?? 5000
  for (const [key, it] of Object.entries(watched)) {
    if (hasCollected(alreadyCollected, key)) continue
    if (anyPlayerNear(players, it.x, it.y, hotCm)) return hotMs
  }
  return coldMs
}
