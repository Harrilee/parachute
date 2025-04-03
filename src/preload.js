const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('electronAPI', {
    // Renderer to Main (two-way communication)
    isDeveloperModeEnabled: () => ipcRenderer.invoke('is-developer-mode-enabled'),
    mockLocation: async (latitude, longtitude) => await ipcRenderer.invoke('mock-location', latitude, longtitude),
    // Main to Renderer
    onDeviceListUpdate: callback => ipcRenderer.on('device-list-update', (_event, value) => callback(value)),
})
