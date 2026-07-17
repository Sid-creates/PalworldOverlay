import type { MapArea } from './coords'

export type ProgressSource = 'manual' | 'auto'

export type ProgressEntry = {
  collected: boolean
  source: ProgressSource
  updatedAt: string
}

export type FilterMode = 'remaining' | 'collected' | 'all'

export type CategoryInfo = {
  id: string
  label: string
  count: number
  color: string
}

export type EffigyMarker = {
  id: string
  worldId: string
  category: string
  label: string
  pal?: string | null
  className?: string
  x: number
  y: number
  z: number
  mapX: number
  mapY: number
  area: MapArea
  u: number
  v: number
  region?: string
}

export type SeedFile = {
  version: number
  source: string
  type: string
  gameVersion?: string
  count: number
  categories: CategoryInfo[]
  markers: EffigyMarker[]
}

export type PlayerPos = {
  x: number
  y: number
  z: number
  mapX: number
  mapY: number
  area: MapArea
  u: number
  v: number
}

export type BridgeMessage =
  | { type: 'player'; x: number; y: number; z: number }
  | { type: 'effigy'; x: number; y: number; z: number; collected?: boolean }
  | {
      type: 'effigies_present'
      items: Array<{ x: number; y: number; z: number; picked?: boolean }>
    }
  | { type: 'relic_possess_num'; count: number }
  | { type: 'hello'; version?: string }
  | { type: string; [key: string]: unknown }

export type BridgeStatus = {
  clients: number
  lastSeen: string | null
}

export type PalworldAssistApi = {
  getProgress: () => Promise<Record<string, ProgressEntry>>
  setProgress: (
    id: string,
    collected: boolean,
    source: ProgressSource,
  ) => Promise<Record<string, ProgressEntry>>
  resetProgress: () => Promise<Record<string, ProgressEntry>>
  getSettings: () => Promise<{
    alwaysOnTop: boolean
    bridgePort: number
    bridgeClients: number
  }>
  toggleAlwaysOnTop: () => Promise<boolean>
  toggleWindow?: () => Promise<boolean>
  onBridgeMessage: (callback: (msg: BridgeMessage) => void) => () => void
  onBridgeStatus: (callback: (status: BridgeStatus) => void) => () => void
  onAlwaysOnTop: (callback: (value: boolean) => void) => () => void
}

declare global {
  interface Window {
    palworldAssist?: PalworldAssistApi
  }
}
