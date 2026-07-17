import { useEffect, useRef, useState } from 'react'
import { findNearestMarkerId, projectWorld, worldToMap } from '../coords'
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

export function useBridge({ markers, progress, setCollected }: Options) {
  const [player, setPlayer] = useState<PlayerPos | null>(null)
  const [status, setStatus] = useState<BridgeStatus>({
    clients: 0,
    lastSeen: null,
  })
  const [connectedHint, setConnectedHint] = useState(false)
  const [relicPossessNum, setRelicPossessNum] = useState<number | null>(null)

  const markersRef = useRef(markers)
  const progressRef = useRef(progress)
  const setCollectedRef = useRef(setCollected)

  markersRef.current = markers
  progressRef.current = progress
  setCollectedRef.current = setCollected

  useEffect(() => {
    const api = window.palworldAssist

    const handleMessage = (msg: BridgeMessage) => {
      setConnectedHint(true)
      const type = msg.type
      if (type === 'hello') return
      if (type === 'player') {
        const x = Number(msg.x)
        const y = Number(msg.y)
        const z = Number(msg.z)
        if (!Number.isFinite(x) || !Number.isFinite(y)) return
        const { mapX, mapY } = worldToMap(x, y)
        const { area, u, v } = projectWorld(x, y)
        setPlayer({
          x,
          y,
          z: Number.isFinite(z) ? z : 0,
          mapX,
          mapY,
          area,
          u,
          v,
        })
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
        if (Number.isFinite(count)) setRelicPossessNum(count)
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

  return { player, status, connectedHint, relicPossessNum }
}
