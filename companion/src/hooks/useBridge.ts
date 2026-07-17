import { useEffect, useMemo, useRef, useState } from 'react'
import { findNearestMarkerId, projectWorld, worldToMap } from '../coords'
import { inferPickupFromPossessCount } from '../lib/relicTracking'
import type {
  BridgeMessage,
  BridgeStatus,
  EffigyMarker,
  PlayerPos,
  ProgressEntry,
} from '../types'

type Options = {
  markers: EffigyMarker[]
  progress: Record<string, ProgressEntry>
  setCollected: (
    id: string,
    collected: boolean,
    source: 'manual' | 'auto',
  ) => Promise<void>
}

const TRACKED_KEY = 'palworldAssist.trackedPlayerId'

function toPlayerPos(raw: {
  id: string
  name: string
  x: number
  y: number
  z: number
  local?: boolean
  relicPossessNum?: number | null
}): PlayerPos | null {
  const x = Number(raw.x)
  const y = Number(raw.y)
  const z = Number(raw.z)
  if (!Number.isFinite(x) || !Number.isFinite(y)) return null
  const { mapX, mapY } = worldToMap(x, y)
  const { area, u, v } = projectWorld(x, y)
  return {
    id: raw.id || `${Math.round(x)}:${Math.round(y)}`,
    name: raw.name || 'Player',
    x,
    y,
    z: Number.isFinite(z) ? z : 0,
    mapX,
    mapY,
    area,
    u,
    v,
    isLocal: Boolean(raw.local),
    relicPossessNum:
      typeof raw.relicPossessNum === 'number' && Number.isFinite(raw.relicPossessNum)
        ? raw.relicPossessNum
        : null,
  }
}

function readStoredTrackedId(): string | null {
  try {
    return localStorage.getItem(TRACKED_KEY)
  } catch {
    return null
  }
}

function writeStoredTrackedId(id: string | null) {
  try {
    if (id) localStorage.setItem(TRACKED_KEY, id)
    else localStorage.removeItem(TRACKED_KEY)
  } catch {
    // ignore
  }
}

export function useBridge({ markers, progress, setCollected }: Options) {
  const [players, setPlayers] = useState<PlayerPos[]>([])
  const [trackedPlayerId, setTrackedPlayerIdState] = useState<string | null>(
    () => readStoredTrackedId(),
  )
  const [status, setStatus] = useState<BridgeStatus>({
    clients: 0,
    lastSeen: null,
  })
  const [connectedHint, setConnectedHint] = useState(false)
  const [relicPossessNum, setRelicPossessNum] = useState<number | null>(null)
  const [bridgeRev, setBridgeRev] = useState<string | null>(null)

  const markersRef = useRef(markers)
  const progressRef = useRef(progress)
  const setCollectedRef = useRef(setCollected)
  const possessCountRef = useRef<number | null>(null)
  const playersRef = useRef<PlayerPos[]>([])
  const trackedPlayerIdRef = useRef(trackedPlayerId)

  markersRef.current = markers
  progressRef.current = progress
  setCollectedRef.current = setCollected
  trackedPlayerIdRef.current = trackedPlayerId

  function applyPossessCount(count: number, playersSnapshot?: PlayerPos[]) {
    const prev = possessCountRef.current
    possessCountRef.current = count
    setRelicPossessNum(count)

    const list = playersSnapshot ?? playersRef.current
    const trackedId = trackedPlayerIdRef.current
    const tracked =
      (trackedId && list.find((p) => p.id === trackedId || p.name === trackedId)) ||
      list.find((p) => p.isLocal) ||
      list[0] ||
      null

    const id = inferPickupFromPossessCount(
      prev,
      count,
      markersRef.current,
      progressRef.current,
      tracked,
    )
    if (id) {
      void setCollectedRef.current(id, true, 'auto')
    }
  }

  const setTrackedPlayerId = (id: string | null) => {
    setTrackedPlayerIdState(id)
    writeStoredTrackedId(id)
  }

  useEffect(() => {
    const api = window.palworldAssist

    const handleMessage = (msg: BridgeMessage) => {
      setConnectedHint(true)
      const type = msg.type
      if (type === 'hello') return
      if (type === 'bridge_meta') {
        if (msg.bridgeRev) setBridgeRev(String(msg.bridgeRev))
        return
      }
      if (type === 'players') {
        const next: PlayerPos[] = []
        if (Array.isArray(msg.players)) {
          for (const raw of msg.players) {
            if (!raw) continue
            const pos = toPlayerPos(raw)
            if (pos) next.push(pos)
          }
        }
        playersRef.current = next
        setPlayers(next)
        const local = next.find((p) => p.isLocal)
        const preferred = local ?? next[0]
        if (preferred?.relicPossessNum != null) {
          applyPossessCount(preferred.relicPossessNum, next)
        }
        return
      }
      if (type === 'player') {
        // Legacy single-player messages.
        const pos = toPlayerPos({
          id: String(msg.id ?? 'player'),
          name: String(msg.name ?? 'Player'),
          x: Number(msg.x),
          y: Number(msg.y),
          z: Number(msg.z),
          local: true,
        })
        if (pos) setPlayers([pos])
        return
      }
      if (type === 'effigy') {
        const x = Number(msg.x)
        const y = Number(msg.y)
        if (!Number.isFinite(x) || !Number.isFinite(y)) return
        if (msg.collected === false) return
        const id = findNearestMarkerId(markersRef.current, x, y)
        if (id && !progressRef.current[id]?.collected) {
          void setCollectedRef.current(id, true, 'auto')
        }
        return
      }
      if (type === 'effigies_present') {
        if (!Array.isArray(msg.items)) return
        for (const item of msg.items) {
          if (!item || item.picked !== true) continue
          const x = Number(item.x)
          const y = Number(item.y)
          if (!Number.isFinite(x) || !Number.isFinite(y)) continue
          const id = findNearestMarkerId(markersRef.current, x, y)
          if (id && !progressRef.current[id]?.collected) {
            void setCollectedRef.current(id, true, 'auto')
          }
        }
        return
      }
      if (type === 'relic_possess_num') {
        const count = Number(msg.count)
        if (Number.isFinite(count)) applyPossessCount(count)
        return
      }
    }

    if (api) {
      const offMsg = api.onBridgeMessage(handleMessage)
      const offStatus = api.onBridgeStatus((s) => {
        setStatus(s)
        if (s.lastSeen) setConnectedHint(true)
      })
      return () => {
        offMsg()
        offStatus()
      }
    }

    const timer = window.setInterval(async () => {
      try {
        const res = await fetch('http://127.0.0.1:17321/health')
        if (!res.ok) return
        const json = (await res.json()) as BridgeStatus & { ok?: boolean }
        setStatus({ clients: json.clients ?? 0, lastSeen: json.lastSeen ?? null })
        if (json.lastSeen) setConnectedHint(true)
      } catch {
        // companion not running
      }
    }, 2000)

    return () => window.clearInterval(timer)
  }, [])

  const player = useMemo(() => {
    if (players.length === 0) return null
    if (trackedPlayerId) {
      const tracked = players.find((p) => p.id === trackedPlayerId)
      if (tracked) return tracked
      const byName = players.find((p) => p.name === trackedPlayerId)
      if (byName) return byName
    }
    return players.find((p) => p.isLocal) ?? players[0] ?? null
  }, [players, trackedPlayerId])

  useEffect(() => {
    if (player?.relicPossessNum != null) {
      applyPossessCount(player.relicPossessNum)
    }
  }, [player?.id, player?.relicPossessNum])

  return {
    player,
    players,
    trackedPlayerId: player?.id ?? trackedPlayerId,
    setTrackedPlayerId,
    status,
    connectedHint,
    relicPossessNum,
    bridgeRev,
  }
}
