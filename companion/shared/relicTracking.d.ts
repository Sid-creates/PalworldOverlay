export const COORD_BUCKET_CM: number
export const PRESENT_NEAR_CM: number
export const STICKY_DROP_CM: number
export const DISAPPEAR_CONFIRM_CM: number
export const PRESENT_MAX: number
export const MATCH_MAX_CM: number
export const POSSESS_PICK_MAX_CM: number
export const STILL_PRESENT_CM: number

export function isFiniteNumber(n: unknown): n is number
export function coordKey(x: number, y: number, z?: number): string
export function isValidWorldLocation(x: number, y: number, z?: number): boolean
export function dist2(ax: number, ay: number, bx: number, by: number): number
export function anyPlayerNear(
  players: Array<{ x: number; y: number }>,
  x: number,
  y: number,
  maxDist: number,
): boolean
export function minDist2ToPlayers(
  players: Array<{ x: number; y: number }>,
  x: number,
  y: number,
): number

export type RelicSample = {
  x: number
  y: number
  z?: number
  picked?: boolean
}
export type PlayerSample = { x: number; y: number }
export type WatchedRelic = { x: number; y: number; z: number }

export function selectPresent(
  samples: RelicSample[],
  players: PlayerSample[],
  opts?: { nearCm?: number; max?: number },
): Array<{ x: number; y: number; z: number; picked: boolean }>

export function updateWatched(
  watched: Record<string, WatchedRelic>,
  samples: RelicSample[],
  players: PlayerSample[],
  opts?: { nearCm?: number; dropCm?: number; watchMax?: number },
): Record<string, WatchedRelic>

export function detectDisappearedCollected(
  watched: Record<string, WatchedRelic>,
  currentSamples: RelicSample[],
  players: PlayerSample[],
  alreadyCollected: Set<string> | Record<string, boolean>,
  opts?: { confirmCm?: number },
): WatchedRelic[]

export function inferPickupFromPossessCount(
  prevCount: number | null | undefined,
  nextCount: number | null | undefined,
  markers: Array<{ id: string; x: number; y: number }>,
  progress: Record<string, { collected?: boolean }>,
  player: PlayerSample | null | undefined,
  opts?: { maxCm?: number },
): string | null

export function findNearestMarkerId(
  markers: Array<{ id: string; x: number; y: number }>,
  x: number,
  y: number,
  maxDist?: number,
): string | null

export function nextScanIntervalMs(
  watched: Record<string, WatchedRelic>,
  players: PlayerSample[],
  alreadyCollected: Set<string> | Record<string, boolean>,
  opts?: { hotCm?: number; hotMs?: number; coldMs?: number },
): number
