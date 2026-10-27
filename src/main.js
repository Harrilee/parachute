/* global MAIN_WINDOW_WEBPACK_ENTRY, MAIN_WINDOW_PRELOAD_WEBPACK_ENTRY */
import IDeviceClient from './ideviceclient'

const { app, autoUpdater, BrowserWindow, ipcMain, session } = require('electron')
const { updateElectronApp, UpdateSourceType } = require('update-electron-app')
const { isNativeMigrationBridge, migrateToNative } = require('./native-migration')

// Handle creating/removing shortcuts on Windows when installing/uninstalling.
if (require('electron-squirrel-startup')) {
    app.quit()
}

const migrationBridge = isNativeMigrationBridge({
    isPackaged: app.isPackaged, platform: process.platform, version: app.getVersion(),
})

if (app.isPackaged && !migrationBridge) {
    updateElectronApp({
        updateSource: {
            type: UpdateSourceType.ElectronPublicUpdateService,
            repo: 'Harrilee/parachute',
        },
    })
}

let client

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
    if (migrationBridge) {
        // The compatibility UI has no permission-dependent browser features.
        // In particular, never ask for the Mac's location during migration/fallback.
        session.defaultSession.setPermissionCheckHandler(() => false)
        session.defaultSession.setPermissionRequestHandler((_contents, _permission, callback) => callback(false))
    }
    if (migrationBridge && await migrateToNative({
        app, autoUpdater, platform: process.platform, arch: process.arch,
        systemVersion: process.getSystemVersion(),
    })) return

    client = new IDeviceClient()
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
    ipcMain.handle('enable-developer-mode', enableDeveloperMode)
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
    client?.cleanup()
})

async function isDeveloperModeEnabled() {
    const isEnabled = await client.isDeveloperModeEnabled()
    return isEnabled
}

async function enableDeveloperMode() {
    return await client.enableDeveloperMode()
}

function sendToRenderer(channel, data) {
    BrowserWindow.getAllWindows().forEach(win => {
        win.webContents.send(channel, data)
    })
}

async function mockLocation(_event, latitude, longitude) {
    const developerModeStatus = await client.isDeveloperModeEnabled()
    if (developerModeStatus !== 'true') {
        throw new Error(`Developer Mode is required before mocking location (${developerModeStatus})`)
    }
    await client.startTunnel()
    await client.mockLocation(latitude, longitude)
    return true
}
