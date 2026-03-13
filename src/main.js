import IDeviceClient from './ideviceclient'

const { app, BrowserWindow, ipcMain } = require('electron')

// Handle creating/removing shortcuts on Windows when installing/uninstalling.
if (require('electron-squirrel-startup')) {
    app.quit()
}

const client = new IDeviceClient()

const createWindow = () => {
    const mainWindow = new BrowserWindow({
        width: 1000,
        height: 800,
        webPreferences: {
            preload: MAIN_WINDOW_PRELOAD_WEBPACK_ENTRY,
        },
    })

    mainWindow.loadURL(MAIN_WINDOW_WEBPACK_ENTRY)
    // mainWindow.webContents.openDevTools()
}
app.whenReady().then(async () => {
    try {
        await client.ensureAdminAccess()
    } catch (err) {
        console.error(`Admin access is required. Quitting: ${err.message}`)
        app.quit()
        return
    }
    client.startTunnel().catch(err => {
        console.warn(`Tunnel start at launch failed: ${err.message}`)
    })

    /* IPC Registration */
    // Renderer to Main (two-way communication)
    ipcMain.handle('is-developer-mode-enabled', isDeveloperModeEnabled)
    ipcMain.handle('mock-location', mockLocation)
    // Main to Renderer
    setInterval(async () => {
        const devices = await client.listDevices()
        sendToRenderer('device-list-update', devices)
    }, 1000)

    /* Window management */
    createWindow()

    // Mac OS specific window handling
    app.on('activate', () => {
        if (BrowserWindow.getAllWindows().length === 0) {
            createWindow()
        }
    })
})

app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') {
        app.quit()
    }
})

app.on('before-quit', () => {
    client.cleanup()
})

async function isDeveloperModeEnabled() {
    const isEnabled = await client.isDeveloperModeEnabled()
    return isEnabled
}

function sendToRenderer(channel, data) {
    BrowserWindow.getAllWindows().forEach(win => {
        win.webContents.send(channel, data)
    })
}

async function mockLocation(_event, latitude, longitude) {
    await client.startTunnel()
    await client.mockLocation(latitude, longitude)
    return true
}
