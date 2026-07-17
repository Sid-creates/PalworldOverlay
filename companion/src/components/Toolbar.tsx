import { MAP_AREA_ORDER, type MapArea } from '../coords'
import type { BridgeStatus, CategoryInfo, FilterMode, PlayerPos } from '../types'

type Props = {
  filter: FilterMode
  onFilterChange: (mode: FilterMode) => void
  collected: number
  total: number
  bridgeStatus: BridgeStatus
  connectedHint: boolean
  alwaysOnTop: boolean
  onToggleAlwaysOnTop: () => void
  onReset: () => void
  inElectron: boolean
  area: MapArea
  onAreaChange: (area: MapArea) => void
  categories: CategoryInfo[]
  enabledCategories: Set<string>
  onToggleCategory: (id: string) => void
  onSetAllCategories: (enabled: boolean) => void
  player: PlayerPos | null
  players: PlayerPos[]
  trackedPlayerId: string | null
  onTrackPlayer: (id: string) => void
  relicPossessNum: number | null
  bridgeRev: string | null
}

const AREA_LABEL: Record<MapArea, string> = {
  MainMap: 'Palpagos',
  Tree: 'World Tree',
}

export function Toolbar({
  filter,
  onFilterChange,
  collected,
  total,
  bridgeStatus,
  connectedHint,
  alwaysOnTop,
  onToggleAlwaysOnTop,
  onReset,
  inElectron,
  area,
  onAreaChange,
  categories,
  enabledCategories,
  onToggleCategory,
  onSetAllCategories,
  player,
  players,
  trackedPlayerId,
  onTrackPlayer,
  relicPossessNum,
  bridgeRev,
}: Props) {
  const remaining = total - collected
  const live =
    connectedHint || bridgeStatus.clients > 0 || Boolean(bridgeStatus.lastSeen)
  const bridgeStale =
    live && (!bridgeRev || players.some((p) => p.name.includes('restart Palworld')))

  return (
    <header className="toolbar">
      <div className="brand-block">
        <h1>PalworldAssist</h1>
        <p className="sub">1.0 relic / effigy tracker</p>
      </div>

      <div className="counter" title="Collected / visible (enabled types + area)">
        <span className="counter-num">
          {collected}/{total}
        </span>
        <span className="counter-label">{remaining} remaining</span>
      </div>

      <div
        className="player-chip player-track"
        title={
          players.length > 0
            ? 'All online players are drawn on the map. Choose who to follow for area switching + count.'
            : 'No live.json yet — fully close Palworld (and any trainer), then relaunch so UE4SS can inject'
        }
      >
        <span className={`dot ${player ? 'live' : 'idle'}`} />
        {players.length === 0 ? (
          <span>Player offline — restart Palworld</span>
        ) : players.length === 1 && player ? (
          <span>
            {player.name} {player.mapX}, {player.mapY}
          </span>
        ) : (
          <>
            <label className="player-select-label" htmlFor="track-player">
              Track
            </label>
            <select
              id="track-player"
              className="player-select"
              value={trackedPlayerId ?? player?.id ?? ''}
              onChange={(e) => onTrackPlayer(e.target.value)}
            >
              {players.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                  {p.isLocal ? ' (you)' : ''} · {p.mapX}, {p.mapY}
                </option>
              ))}
            </select>
          </>
        )}
      </div>

      {relicPossessNum != null && (
        <div className="player-chip" title="RelicPossessNum from game memory">
          In-game count {relicPossessNum}
        </div>
      )}

      {bridgeStale && (
        <div
          className="player-chip warn"
          title="live.json is still from the old bridge. Fully close Palworld (and any trainer), then relaunch."
        >
          Restart Palworld to load multiplayer bridge
        </div>
      )}

      <div className="filters" role="group" aria-label="Map area">
        {MAP_AREA_ORDER.map((a) => (
          <button
            key={a}
            type="button"
            className={area === a ? 'active' : ''}
            onClick={() => onAreaChange(a)}
          >
            {AREA_LABEL[a]}
          </button>
        ))}
      </div>

      <div className="filters" role="group" aria-label="Marker filter">
        {(['remaining', 'collected', 'all'] as const).map((mode) => (
          <button
            key={mode}
            type="button"
            className={filter === mode ? 'active' : ''}
            onClick={() => onFilterChange(mode)}
          >
            {mode}
          </button>
        ))}
      </div>

      <div className="status-block">
        <span className={`dot ${live ? 'live' : 'idle'}`} />
        <span>
          Bridge {live ? 'live' : 'idle'}
          {bridgeStatus.lastSeen
            ? ` · last ${new Date(bridgeStatus.lastSeen).toLocaleTimeString()}`
            : ''}
        </span>
      </div>

      <div className="actions">
        {inElectron && (
          <button type="button" onClick={onToggleAlwaysOnTop}>
            {alwaysOnTop ? 'Pinned on top' : 'Pin on top'}
          </button>
        )}
        <button
          type="button"
          className="danger"
          onClick={() => {
            if (confirm('Clear all local progress?')) onReset()
          }}
        >
          Reset
        </button>
      </div>

      <div className="category-row" role="group" aria-label="Effigy types">
        <button type="button" className="chip ghost" onClick={() => onSetAllCategories(true)}>
          All types
        </button>
        <button type="button" className="chip ghost" onClick={() => onSetAllCategories(false)}>
          None
        </button>
        {categories.map((c) => {
          const on = enabledCategories.has(c.id)
          return (
            <button
              key={c.id}
              type="button"
              className={`chip ${on ? 'on' : ''}`}
              style={{ ['--chip' as string]: c.color }}
              onClick={() => onToggleCategory(c.id)}
              title={`${c.label} (${c.count})`}
            >
              <span className="swatch" />
              {c.label}
              <span className="chip-count">{c.count}</span>
            </button>
          )
        })}
      </div>
    </header>
  )
}
