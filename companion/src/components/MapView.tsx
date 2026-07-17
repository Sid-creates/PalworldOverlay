import { useEffect, useMemo, useRef, useState } from 'react'
import { MAP_AREAS, MAP_SIZE, worldToUv, type MapArea } from '../coords'
import type {
  CategoryInfo,
  EffigyMarker,
  FilterMode,
  PlayerPos,
  ProgressEntry,
} from '../types'

type Props = {
  markers: EffigyMarker[]
  progress: Record<string, ProgressEntry>
  filter: FilterMode
  enabledCategories: Set<string>
  categories: CategoryInfo[]
  area: MapArea
  player: PlayerPos | null
  players: PlayerPos[]
  onToggle: (id: string, nextCollected: boolean) => void
}

type ViewState = {
  scale: number
  offsetX: number
  offsetY: number
}

const PAD = 24

const PLAYER_COLORS = ['#5ec8ff', '#ffb86b', '#c3a6ff', '#7dce6a', '#ff7eb6']

export function MapView({
  markers,
  progress,
  filter,
  enabledCategories,
  categories,
  area,
  player,
  players,
  onToggle,
}: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const wrapRef = useRef<HTMLDivElement>(null)
  const [size, setSize] = useState({ w: 800, h: 600 })
  const [view, setView] = useState<ViewState>({ scale: 1, offsetX: 0, offsetY: 0 })
  const [mapImage, setMapImage] = useState<HTMLImageElement | null>(null)
  const dragRef = useRef<{ x: number; y: number; ox: number; oy: number } | null>(
    null,
  )
  const fittedAreaRef = useRef<MapArea | null>(null)

  const colorByCategory = useMemo(() => {
    const map = new Map<string, string>()
    for (const c of categories) map.set(c.id, c.color)
    return map
  }, [categories])

  const areaMarkers = useMemo(
    () => markers.filter((m) => m.area === area),
    [markers, area],
  )

  const visible = useMemo(() => {
    return areaMarkers.filter((m) => {
      if (!enabledCategories.has(m.category)) return false
      const collected = Boolean(progress[m.id]?.collected)
      switch (filter) {
        case 'remaining':
          return !collected
        case 'collected':
          return collected
        case 'all':
          return true
        default: {
          const _never: never = filter
          return _never
        }
      }
    })
  }, [areaMarkers, progress, filter, enabledCategories])

  useEffect(() => {
    const el = wrapRef.current
    if (!el) return
    const ro = new ResizeObserver((entries) => {
      const entry = entries[0]
      if (!entry) return
      const { width, height } = entry.contentRect
      setSize({ w: Math.max(1, Math.floor(width)), h: Math.max(1, Math.floor(height)) })
    })
    ro.observe(el)
    return () => ro.disconnect()
  }, [])

  useEffect(() => {
    let cancelled = false
    setMapImage(null)
    const img = new Image()
    img.decoding = 'async'
    img.src = MAP_AREAS[area].texture
    img.onload = () => {
      if (!cancelled) setMapImage(img)
    }
    img.onerror = () => {
      if (!cancelled) setMapImage(null)
    }
    return () => {
      cancelled = true
    }
  }, [area])

  useEffect(() => {
    if (size.w < 10 || size.h < 10) return
    if (fittedAreaRef.current === area) return
    const side = Math.min(size.w - PAD * 2, size.h - PAD * 2)
    const scale = side / MAP_SIZE
    setView({
      scale,
      offsetX: (size.w - MAP_SIZE * scale) / 2,
      offsetY: (size.h - MAP_SIZE * scale) / 2,
    })
    fittedAreaRef.current = area
  }, [area, size.h, size.w])

  function markerUv(m: EffigyMarker) {
    // Always reproject from world coords — seed UVs can be stale/wrong.
    return worldToUv(m.x, m.y, area)
  }

  function toScreen(u: number, v: number, vstate: ViewState = view) {
    return {
      x: u * MAP_SIZE * vstate.scale + vstate.offsetX,
      y: v * MAP_SIZE * vstate.scale + vstate.offsetY,
    }
  }

  function hitTest(clientX: number, clientY: number): EffigyMarker | null {
    const canvas = canvasRef.current
    if (!canvas) return null
    const rect = canvas.getBoundingClientRect()
    const px = clientX - rect.left
    const py = clientY - rect.top
    const hitR = 10
    const hitR2 = hitR * hitR
    let best: EffigyMarker | null = null
    let bestD = hitR2
    for (const m of visible) {
      const { u, v } = markerUv(m)
      const p = toScreen(u, v)
      const dx = p.x - px
      const dy = p.y - py
      const d2 = dx * dx + dy * dy
      if (d2 <= bestD) {
        bestD = d2
        best = m
      }
    }
    return best
  }

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const ctx = canvas.getContext('2d')
    if (!ctx) return

    canvas.width = size.w
    canvas.height = size.h

    // Layer 1: background
    ctx.fillStyle = '#0a100c'
    ctx.fillRect(0, 0, size.w, size.h)

    const mapW = MAP_SIZE * view.scale
    const mapH = MAP_SIZE * view.scale
    const mx = view.offsetX
    const my = view.offsetY

    // Layer 2: map texture (under markers)
    if (mapImage) {
      ctx.imageSmoothingEnabled = true
      ctx.imageSmoothingQuality = 'high'
      ctx.drawImage(mapImage, mx, my, mapW, mapH)
    } else {
      ctx.fillStyle = '#152018'
      ctx.fillRect(mx, my, mapW, mapH)
      ctx.strokeStyle = 'rgba(120, 160, 120, 0.2)'
      ctx.strokeRect(mx, my, mapW, mapH)
    }

    // Layer 3: markers on top of map
    const r = Math.max(4.5, Math.min(7, 5.5 / Math.sqrt(Math.max(view.scale, 0.05))))

    for (const m of visible) {
      const collected = Boolean(progress[m.id]?.collected)
      const { u, v } = worldToUv(m.x, m.y, area)
      const p = {
        x: u * MAP_SIZE * view.scale + view.offsetX,
        y: v * MAP_SIZE * view.scale + view.offsetY,
      }
      const color = colorByCategory.get(m.category) ?? '#c8e06a'

      // Outer halo so pins read on busy map art
      ctx.beginPath()
      ctx.arc(p.x, p.y, r + 2.5, 0, Math.PI * 2)
      ctx.fillStyle = collected ? 'rgba(0,0,0,0.35)' : 'rgba(0,0,0,0.55)'
      ctx.fill()

      ctx.beginPath()
      ctx.arc(p.x, p.y, r, 0, Math.PI * 2)
      if (collected) {
        ctx.fillStyle = 'rgba(90, 110, 90, 0.55)'
        ctx.strokeStyle = 'rgba(230, 240, 220, 0.7)'
      } else {
        ctx.fillStyle = color
        ctx.strokeStyle = '#fff8e8'
      }
      ctx.fill()
      ctx.lineWidth = 1.6
      ctx.stroke()
    }

    // Layer 4: all players on top of markers
    const trackedId = player?.id
    for (let i = 0; i < players.length; i++) {
      const pl = players[i]
      if (pl.area !== area) continue
      const { u, v } = worldToUv(pl.x, pl.y, area)
      const p = {
        x: u * MAP_SIZE * view.scale + view.offsetX,
        y: v * MAP_SIZE * view.scale + view.offsetY,
      }
      const color = PLAYER_COLORS[i % PLAYER_COLORS.length]
      const tracked = pl.id === trackedId

      if (tracked) {
        ctx.beginPath()
        ctx.arc(p.x, p.y, r + 14, 0, Math.PI * 2)
        ctx.strokeStyle = 'rgba(94, 200, 255, 0.35)'
        ctx.lineWidth = 3
        ctx.stroke()
      }

      ctx.beginPath()
      ctx.arc(p.x, p.y, tracked ? r + 6 : r + 4, 0, Math.PI * 2)
      ctx.fillStyle = color
      ctx.fill()
      ctx.lineWidth = tracked ? 2.5 : 1.5
      ctx.strokeStyle = tracked ? '#ffffff' : 'rgba(255,255,255,0.75)'
      ctx.stroke()

      ctx.beginPath()
      ctx.arc(p.x, p.y, 2.5, 0, Math.PI * 2)
      ctx.fillStyle = '#062030'
      ctx.fill()

      const label = pl.name || 'Player'
      ctx.font = '600 11px ui-sans-serif, system-ui, sans-serif'
      ctx.textAlign = 'center'
      ctx.textBaseline = 'bottom'
      ctx.lineWidth = 3
      ctx.strokeStyle = 'rgba(6, 16, 12, 0.85)'
      ctx.strokeText(label, p.x, p.y - (tracked ? r + 10 : r + 7))
      ctx.fillStyle = tracked ? '#e8f7ff' : '#d8e8dc'
      ctx.fillText(label, p.x, p.y - (tracked ? r + 10 : r + 7))
    }
  }, [size, view, visible, progress, player, players, area, mapImage, colorByCategory])

  return (
    <div
      ref={wrapRef}
      className="map-wrap"
      onContextMenu={(e) => {
        e.preventDefault()
        const hit = hitTest(e.clientX, e.clientY)
        if (!hit) return
        const collected = Boolean(progress[hit.id]?.collected)
        onToggle(hit.id, !collected)
      }}
      onWheel={(e) => {
        e.preventDefault()
        const canvas = canvasRef.current
        if (!canvas) return
        const rect = canvas.getBoundingClientRect()
        const cx = e.clientX - rect.left
        const cy = e.clientY - rect.top
        const factor = e.deltaY > 0 ? 0.9 : 1.1
        setView((v) => {
          const nextScale = Math.min(8, Math.max(0.04, v.scale * factor))
          const worldU = (cx - v.offsetX) / (MAP_SIZE * v.scale)
          const worldV = (cy - v.offsetY) / (MAP_SIZE * v.scale)
          return {
            scale: nextScale,
            offsetX: cx - worldU * MAP_SIZE * nextScale,
            offsetY: cy - worldV * MAP_SIZE * nextScale,
          }
        })
      }}
      onPointerDown={(e) => {
        if (e.button !== 0) return
        ;(e.target as HTMLElement).setPointerCapture?.(e.pointerId)
        dragRef.current = {
          x: e.clientX,
          y: e.clientY,
          ox: view.offsetX,
          oy: view.offsetY,
        }
      }}
      onPointerMove={(e) => {
        const d = dragRef.current
        if (!d) return
        setView((v) => ({
          ...v,
          offsetX: d.ox + (e.clientX - d.x),
          offsetY: d.oy + (e.clientY - d.y),
        }))
      }}
      onPointerUp={() => {
        dragRef.current = null
      }}
      onPointerLeave={() => {
        dragRef.current = null
      }}
      onDoubleClick={(e) => {
        const hit = hitTest(e.clientX, e.clientY)
        if (!hit) return
        const collected = Boolean(progress[hit.id]?.collected)
        onToggle(hit.id, !collected)
      }}
    >
      <canvas ref={canvasRef} className="map-canvas" />
      <p className="map-hint">
        {visible.length} markers · scroll zoom · drag pan · right-click to toggle
        {players.length > 0
          ? ` · ${players.length} player${players.length === 1 ? '' : 's'}${
              player ? ` · tracking ${player.name} @ ${player.mapX}, ${player.mapY}` : ''
            }`
          : ' · player: waiting for bridge'}
      </p>
    </div>
  )
}
