const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('electronAPI', {
    // Renderer to Main (two-way communication)
    isDeveloperModeEnabled: () => ipcRenderer.invoke('is-developer-mode-enabled'),
    mockLocation: (latitude, longtitude) => ipcRenderer.invoke('mock-location', latitude, longtitude),
    // Main to Renderer
    onDeviceListUpdate: callback => ipcRenderer.on('device-list-update', (_event, value) => callback(value)),
})
