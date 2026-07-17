const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('palworldAssist', {
  getProgress: () => ipcRenderer.invoke('progress:getAll'),
  setProgress: (id, collected, source) =>
    ipcRenderer.invoke('progress:set', id, collected, source),
  resetProgress: () => ipcRenderer.invoke('progress:reset'),
  getSettings: () => ipcRenderer.invoke('settings:get'),
  toggleAlwaysOnTop: () => ipcRenderer.invoke('settings:toggleAlwaysOnTop'),
  toggleWindow: () => ipcRenderer.invoke('settings:toggleWindow'),
  onBridgeMessage: (callback) => {
    const handler = (_event, msg) => callback(msg)
    ipcRenderer.on('bridge:message', handler)
    return () => ipcRenderer.removeListener('bridge:message', handler)
  },
  onBridgeStatus: (callback) => {
    const handler = (_event, status) => callback(status)
    ipcRenderer.on('bridge:status', handler)
    return () => ipcRenderer.removeListener('bridge:status', handler)
  },
  onAlwaysOnTop: (callback) => {
    const handler = (_event, value) => callback(value)
    ipcRenderer.on('settings:alwaysOnTop', handler)
    return () => ipcRenderer.removeListener('settings:alwaysOnTop', handler)
  },
})
