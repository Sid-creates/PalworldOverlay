import fs from 'node:fs'
import path from 'node:path'

/**
 * @typedef {'manual' | 'auto'} ProgressSource
 * @typedef {{ collected: boolean, source: ProgressSource, updatedAt: string }} ProgressEntry
 */

/**
 * @param {import('electron').App} app
 */
export function createProgressStore(app) {
  const filePath = path.join(app.getPath('userData'), 'progress.json')

  /** @type {Record<string, ProgressEntry>} */
  let data = load()

  function load() {
    try {
      if (!fs.existsSync(filePath)) return {}
      const raw = JSON.parse(fs.readFileSync(filePath, 'utf8'))
      return raw && typeof raw === 'object' ? raw : {}
    } catch {
      return {}
    }
  }

  function save() {
    fs.mkdirSync(path.dirname(filePath), { recursive: true })
    fs.writeFileSync(filePath, JSON.stringify(data, null, 2), 'utf8')
  }

  return {
    getAll() {
      return data
    },

    /**
     * @param {string} id
     * @param {boolean} collected
     * @param {ProgressSource} source
     */
    set(id, collected, source = 'manual') {
      if (!collected) {
        delete data[id]
      } else {
        data[id] = {
          collected: true,
          source,
          updatedAt: new Date().toISOString(),
        }
      }
      save()
      return data
    },

    reset() {
      data = {}
      save()
    },
  }
}
