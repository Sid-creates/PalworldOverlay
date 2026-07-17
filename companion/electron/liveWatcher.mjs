import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

/**
 * Watch the UE4SS bridge live.json and emit structured bridge messages.
 *
 * @param {{
 *   onMessage: (msg: unknown) => void,
 *   onStatus: (status: { clients: number, lastSeen: string | null }) => void,
 * }} opts
 */
export function startLiveWatcher({ onMessage, onStatus }) {
  const localAppData =
    process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local')
  const livePath = path.join(localAppData, 'PalworldAssist', 'live.json')
  /** @type {string | null} */
  let lastSeen = null
  /** @type {Set<string>} */
  const emittedCollected = new Set()
  let lastRaw = ''

  function emitStatus() {
    onStatus({ clients: fs.existsSync(livePath) ? 1 : 0, lastSeen })
  }

  function readOnce() {
    try {
      if (!fs.existsSync(livePath)) {
        emitStatus()
        return
      }
      const raw = fs.readFileSync(livePath, 'utf8')
      if (!raw || raw === lastRaw) return
      lastRaw = raw
      const data = JSON.parse(raw)
      lastSeen = new Date().toISOString()

      if (typeof data.bridgeRev === 'string' || typeof data.version === 'number') {
        onMessage({
          type: 'bridge_meta',
          version: Number(data.version) || 0,
          bridgeRev: String(data.bridgeRev ?? ''),
          playerCount: Number(data.playerCount) || 0,
        })
      }

      if (Array.isArray(data.players) && data.players.length > 0) {
        onMessage({
          type: 'players',
          players: data.players.map((p) => ({
            id: String(p?.id ?? ''),
            name: String(p?.name ?? 'Player'),
            x: Number(p?.x),
            y: Number(p?.y),
            z: Number(p?.z ?? 0),
            local: Boolean(p?.local),
            relicPossessNum:
              typeof p?.relicPossessNum === 'number' ? p.relicPossessNum : null,
          })),
        })
      } else if (data.player && typeof data.player.x === 'number') {
        // Old bridge still running in memory — fully restart Palworld.
        onMessage({
          type: 'players',
          players: [
            {
              id: String(data.player.id ?? 'player'),
              name: String(data.player.name || 'Player (restart Palworld)'),
              x: data.player.x,
              y: data.player.y,
              z: data.player.z ?? 0,
              local: Boolean(data.player.local ?? true),
              relicPossessNum:
                typeof data.relicPossessNum === 'number'
                  ? data.relicPossessNum
                  : null,
            },
          ],
        })
      }

      if (typeof data.relicPossessNum === 'number') {
        onMessage({
          type: 'relic_possess_num',
          count: data.relicPossessNum,
        })
      }

      if (Array.isArray(data.present)) {
        onMessage({
          type: 'effigies_present',
          items: data.present,
        })
        // Memory flag on loaded actors: already picked in this save.
        for (const item of data.present) {
          if (!item || typeof item.x !== 'number' || !item.picked) continue
          const key = `${Math.round(item.x / 200)}:${Math.round(item.y / 200)}:${Math.round((item.z ?? 0) / 200)}`
          if (emittedCollected.has(key)) continue
          emittedCollected.add(key)
          onMessage({
            type: 'effigy',
            x: item.x,
            y: item.y,
            z: item.z ?? 0,
            collected: true,
          })
        }
      }

      if (Array.isArray(data.collected)) {
        for (const item of data.collected) {
          if (!item || typeof item.x !== 'number') continue
          const key = `${Math.round(item.x / 200)}:${Math.round(item.y / 200)}:${Math.round((item.z ?? 0) / 200)}`
          if (emittedCollected.has(key)) continue
          emittedCollected.add(key)
          onMessage({
            type: 'effigy',
            x: item.x,
            y: item.y,
            z: item.z ?? 0,
            collected: true,
          })
        }
      }

      emitStatus()
    } catch {
      // partial write / parse race — ignore until next tick
    }
  }

  fs.mkdirSync(path.dirname(livePath), { recursive: true })

  let watcher = null
  try {
    watcher = fs.watch(path.dirname(livePath), (event, filename) => {
      if (!filename || filename === 'live.json') readOnce()
    })
  } catch {
    // fall through to polling
  }

  const poll = setInterval(readOnce, 400)
  readOnce()
  emitStatus()

  return {
    livePath,
    close() {
      clearInterval(poll)
      watcher?.close()
    },
  }
}
