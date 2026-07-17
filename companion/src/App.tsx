import { useEffect, useMemo, useRef, useState } from 'react'
import { MapView } from './components/MapView'
import { Toolbar } from './components/Toolbar'
import { DEFAULT_MAP_AREA, type MapArea } from './coords'
import { useBridge } from './hooks/useBridge'
import { useProgress } from './hooks/useProgress'
import type { FilterMode, SeedFile } from './types'
import './App.css'

export default function App() {
  const [seed, setSeed] = useState<SeedFile | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [filter, setFilter] = useState<FilterMode>('remaining')
  const [area, setArea] = useState<MapArea>(DEFAULT_MAP_AREA)
  const [enabledCategories, setEnabledCategories] = useState<Set<string>>(
    new Set(),
  )
  const [alwaysOnTop, setAlwaysOnTop] = useState(true)
  const lastPlayerArea = useRef<MapArea | null>(null)
  const { progress, setCollected, reset } = useProgress()
  const inElectron = Boolean(window.palworldAssist)

  useEffect(() => {
    let cancelled = false
    ;(async () => {
      try {
        const res = await fetch('/data/relics.json')
        if (!res.ok) throw new Error(`Failed to load seed (${res.status})`)
        const json = (await res.json()) as SeedFile
        if (cancelled) return
        setSeed(json)
        setEnabledCategories(new Set(json.categories.map((c) => c.id)))
      } catch (err) {
        if (!cancelled) {
          setLoadError(err instanceof Error ? err.message : 'Failed to load seed')
        }
      }
    })()
    return () => {
      cancelled = true
    }
  }, [])

  useEffect(() => {
    const api = window.palworldAssist
    if (!api) return
    void api.getSettings().then((s) => setAlwaysOnTop(s.alwaysOnTop))
    return api.onAlwaysOnTop(setAlwaysOnTop)
  }, [])

  const markers = useMemo(() => seed?.markers ?? [], [seed])
  const categories = useMemo(() => seed?.categories ?? [], [seed])

  const {
    player,
    players,
    trackedPlayerId,
    setTrackedPlayerId,
    status,
    connectedHint,
    relicPossessNum,
    bridgeRev,
  } = useBridge({
    markers,
    progress,
    setCollected,
  })

  // Follow the player when they cross into a different map area.
  useEffect(() => {
    if (!player?.area) return
    if (lastPlayerArea.current !== player.area) {
      lastPlayerArea.current = player.area
      setArea(player.area)
    }
  }, [player?.area])

  const scopedMarkers = useMemo(
    () =>
      markers.filter(
        (m) => m.area === area && enabledCategories.has(m.category),
      ),
    [markers, area, enabledCategories],
  )

  const collectedCount = useMemo(() => {
    let n = 0
    for (const m of scopedMarkers) {
      if (progress[m.id]?.collected) n += 1
    }
    return n
  }, [scopedMarkers, progress])

  if (loadError) {
    return (
      <div className="app shell-error">
        <h1>PalworldAssist</h1>
        <p>{loadError}</p>
      </div>
    )
  }

  if (!seed) {
    return (
      <div className="app shell-loading">
        <p>Loading relic catalog…</p>
      </div>
    )
  }

  return (
    <div className="app">
      <Toolbar
        filter={filter}
        onFilterChange={setFilter}
        collected={collectedCount}
        total={scopedMarkers.length}
        bridgeStatus={status}
        connectedHint={connectedHint}
        alwaysOnTop={alwaysOnTop}
        onToggleAlwaysOnTop={() => {
          void window.palworldAssist?.toggleAlwaysOnTop().then(setAlwaysOnTop)
        }}
        onReset={() => {
          void reset()
        }}
        inElectron={inElectron}
        area={area}
        onAreaChange={setArea}
        categories={categories}
        enabledCategories={enabledCategories}
        onToggleCategory={(id) => {
          setEnabledCategories((prev) => {
            const next = new Set(prev)
            if (next.has(id)) next.delete(id)
            else next.add(id)
            return next
          })
        }}
        onSetAllCategories={(enabled) => {
          setEnabledCategories(
            enabled ? new Set(categories.map((c) => c.id)) : new Set(),
          )
        }}
        player={player}
        players={players}
        trackedPlayerId={trackedPlayerId}
        onTrackPlayer={setTrackedPlayerId}
        relicPossessNum={relicPossessNum}
        bridgeRev={bridgeRev}
      />
      <MapView
        markers={markers}
        progress={progress}
        filter={filter}
        enabledCategories={enabledCategories}
        categories={categories}
        area={area}
        player={player}
        players={players}
        onToggle={(id, next) => {
          void setCollected(id, next, 'manual')
        }}
      />
      <footer className="footer">
        <span>
          {seed.count} relics · Palworld {seed.gameVersion ?? '1.0'} · F8
          hide/show · Ctrl+Shift+A pin · close → tray
        </span>
        <span className="muted">{seed.source}</span>
      </footer>
    </div>
  )
}
