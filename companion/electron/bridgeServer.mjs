import http from 'node:http'
import { WebSocketServer } from 'ws'

/**
 * Local bridge endpoint for the UE4SS mod.
 * - HTTP POST /bridge  { type, ... }  (Lua-friendly; no WS client needed in-game)
 * - WebSocket ws://127.0.0.1:PORT     (optional / debug)
 *
 * @param {{
 *   port: number,
 *   onMessage: (msg: unknown) => void,
 *   onStatus: (status: { clients: number, lastSeen: string | null }) => void,
 * }} opts
 */
export function startBridgeServer({ port, onMessage, onStatus }) {
  /** @type {string | null} */
  let lastSeen = null

  const server = http.createServer((req, res) => {
    if (req.method === 'OPTIONS') {
      res.writeHead(204, corsHeaders())
      res.end()
      return
    }

    if (req.method === 'GET' && req.url === '/health') {
      res.writeHead(200, { ...corsHeaders(), 'Content-Type': 'application/json' })
      res.end(JSON.stringify({ ok: true, clients: wss.clients.size, lastSeen }))
      return
    }

    if (req.method === 'POST' && (req.url === '/bridge' || req.url === '/')) {
      let body = ''
      req.on('data', (chunk) => {
        body += chunk
        if (body.length > 1_000_000) req.destroy()
      })
      req.on('end', () => {
        try {
          const msg = JSON.parse(body)
          lastSeen = new Date().toISOString()
          onMessage(msg)
          emitStatus()
          res.writeHead(204, corsHeaders())
          res.end()
        } catch {
          res.writeHead(400, { ...corsHeaders(), 'Content-Type': 'application/json' })
          res.end(JSON.stringify({ error: 'invalid_json' }))
        }
      })
      return
    }

    res.writeHead(404, corsHeaders())
    res.end()
  })

  const wss = new WebSocketServer({ server })

  wss.on('connection', (socket) => {
    emitStatus()
    socket.on('message', (raw) => {
      try {
        const msg = JSON.parse(String(raw))
        lastSeen = new Date().toISOString()
        onMessage(msg)
        emitStatus()
      } catch {
        // ignore malformed frames
      }
    })
    socket.on('close', () => emitStatus())
  })

  function emitStatus() {
    onStatus({ clients: wss.clients.size, lastSeen })
  }

  server.listen(port, '127.0.0.1', () => {
    console.log(`[bridge] listening on http://127.0.0.1:${port}/bridge`)
  })

  return {
    clientCount: () => wss.clients.size,
    close: () => {
      wss.close()
      server.close()
    },
  }
}

function corsHeaders() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  }
}
