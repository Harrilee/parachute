const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('electronAPI', {
    isDeveloperModeEnabled: () => ipcRenderer.invoke('is-developer-mode-enabled'),
    onDeviceListUpdate: callback => ipcRenderer.on('device-list-update', (_event, value) => callback(value)),
})
