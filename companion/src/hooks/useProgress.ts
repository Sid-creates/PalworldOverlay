import { useCallback, useEffect, useState } from 'react'
import type { ProgressEntry, ProgressSource } from '../types'

const LOCAL_KEY = 'palworldAssist.progress'

function loadLocal(): Record<string, ProgressEntry> {
  try {
    const raw = localStorage.getItem(LOCAL_KEY)
    if (!raw) return {}
    const parsed = JSON.parse(raw) as Record<string, ProgressEntry>
    return parsed && typeof parsed === 'object' ? parsed : {}
  } catch {
    return {}
  }
}

function saveLocal(data: Record<string, ProgressEntry>) {
  localStorage.setItem(LOCAL_KEY, JSON.stringify(data))
}

export function useProgress() {
  const [progress, setProgress] = useState<Record<string, ProgressEntry>>({})
  const api = typeof window !== 'undefined' ? window.palworldAssist : undefined

  useEffect(() => {
    let cancelled = false
    ;(async () => {
      if (api) {
        const all = await api.getProgress()
        if (!cancelled) setProgress(all)
      } else {
        setProgress(loadLocal())
      }
    })()
    return () => {
      cancelled = true
    }
  }, [api])

  const setCollected = useCallback(
    async (id: string, collected: boolean, source: ProgressSource = 'manual') => {
      if (api) {
        const next = await api.setProgress(id, collected, source)
        setProgress(next)
        return
      }
      setProgress((prev) => {
        const next = { ...prev }
        if (!collected) {
          delete next[id]
        } else {
          next[id] = {
            collected: true,
            source,
            updatedAt: new Date().toISOString(),
          }
        }
        saveLocal(next)
        return next
      })
    },
    [api],
  )

  const reset = useCallback(async () => {
    if (api) {
      const next = await api.resetProgress()
      setProgress(next)
      return
    }
    saveLocal({})
    setProgress({})
  }, [api])

  return { progress, setCollected, reset }
}
