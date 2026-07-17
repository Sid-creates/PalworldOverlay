import {
  app,
  BrowserWindow,
  globalShortcut,
  ipcMain,
  Menu,
  Tray,
  nativeImage,
} from 'electron'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { startBridgeServer } from './bridgeServer.mjs'
import { startLiveWatcher } from './liveWatcher.mjs'
import { createProgressStore } from './progress.mjs'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const isDev = !app.isPackaged
const BRIDGE_PORT = 17321

/** @type {BrowserWindow | null} */
let mainWindow = null
/** @type {Tray | null} */
let tray = null
let alwaysOnTop = true
let quitting = false

const progressStore = createProgressStore(app)

function toggleWindowVisibility() {
  if (!mainWindow || mainWindow.isDestroyed()) {
    createWindow()
    return
  }
  if (mainWindow.isVisible()) {
    mainWindow.hide()
  } else {
    mainWindow.show()
    mainWindow.focus()
  }
  updateTrayMenu()
}

function createTray() {
  // Tiny generated icon (green-ish pixel) so we don't need an asset file.
  const png = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAKElEQVQ4T2NkYGD4z0ABYBzVMKoBQzUMhiYGAwMDAyMDHRgNxRgYBgAAeG0BAfk0YdQAAAAASUVORK5CYII=',
    'base64',
  )
  const icon = nativeImage.createFromBuffer(png)
  tray = new Tray(icon.isEmpty() ? nativeImage.createEmpty() : icon)
  tray.setToolTip('PalworldAssist — F8 hide/show')
  tray.on('double-click', () => toggleWindowVisibility())
  updateTrayMenu()
}

function updateTrayMenu() {
  if (!tray) return
  const visible = Boolean(mainWindow && !mainWindow.isDestroyed() && mainWindow.isVisible())
  const menu = Menu.buildFromTemplate([
    {
      label: visible ? 'Hide map (F8)' : 'Show map (F8)',
      click: () => toggleWindowVisibility(),
    },
    {
      label: alwaysOnTop ? 'Unpin from top' : 'Pin on top',
      click: () => {
        toggleAlwaysOnTop()
        updateTrayMenu()
      },
    },
    { type: 'separator' },
    {
      label: 'Quit',
      click: () => {
        quitting = true
        app.quit()
      },
    },
  ])
  tray.setContextMenu(menu)
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 800,
    minWidth: 720,
    minHeight: 480,
    title: 'PalworldAssist',
    backgroundColor: '#0e1410',
    alwaysOnTop,
    show: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  })

  Menu.setApplicationMenu(null)

  if (isDev) {
    mainWindow.loadURL('http://127.0.0.1:5173')
  } else {
    mainWindow.loadFile(path.join(__dirname, '../dist/index.html'))
  }

  // Close = hide to tray (keeps bridge alive). Quit from tray menu.
  mainWindow.on('close', (event) => {
    if (!quitting) {
      event.preventDefault()
      mainWindow?.hide()
      updateTrayMenu()
    }
  })

  mainWindow.on('closed', () => {
    mainWindow = null
  })
}

function broadcast(channel, payload) {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send(channel, payload)
  }
}

function toggleAlwaysOnTop() {
  alwaysOnTop = !alwaysOnTop
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.setAlwaysOnTop(alwaysOnTop)
  }
  broadcast('settings:alwaysOnTop', alwaysOnTop)
}

app.whenReady().then(() => {
  // Ensure live.json folder exists before the UE4SS mod writes (no game-side mkdir).
  const liveDir = path.join(
    process.env.LOCALAPPDATA || app.getPath('home'),
    'PalworldAssist',
  )
  fs.mkdirSync(liveDir, { recursive: true })

  createWindow()
  createTray()

  const onMessage = (msg) => broadcast('bridge:message', msg)
  const onStatus = (status) => broadcast('bridge:status', status)

  const bridge = startBridgeServer({
    port: BRIDGE_PORT,
    onMessage,
    onStatus,
  })

  const liveWatcher = startLiveWatcher({ onMessage, onStatus })
  console.log(`[bridge] watching ${liveWatcher.livePath}`)

  ipcMain.handle('progress:getAll', () => progressStore.getAll())
  ipcMain.handle('progress:set', (_event, id, collected, source) => {
    return progressStore.set(id, collected, source)
  })
  ipcMain.handle('progress:reset', () => {
    progressStore.reset()
    return progressStore.getAll()
  })
  ipcMain.handle('settings:get', () => ({
    alwaysOnTop,
    bridgePort: BRIDGE_PORT,
    bridgeClients: bridge.clientCount(),
    livePath: liveWatcher.livePath,
    hideShortcut: 'F8',
  }))
  ipcMain.handle('settings:toggleAlwaysOnTop', () => {
    toggleAlwaysOnTop()
    updateTrayMenu()
    return alwaysOnTop
  })
  ipcMain.handle('settings:toggleWindow', () => {
    toggleWindowVisibility()
    return Boolean(mainWindow && mainWindow.isVisible())
  })

  // F8 — easy in-game toggle. Also keep Ctrl+Shift+O.
  globalShortcut.register('F8', () => toggleWindowVisibility())
  globalShortcut.register('CommandOrControl+Shift+O', () => toggleWindowVisibility())
  globalShortcut.register('CommandOrControl+Shift+A', () => {
    toggleAlwaysOnTop()
    updateTrayMenu()
  })

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('before-quit', () => {
  quitting = true
  globalShortcut.unregisterAll()
})

// Stay alive in the tray; only tray Quit ends the process.
app.on('window-all-closed', () => {
  /* no-op on Windows/Linux while tray is active */
})
