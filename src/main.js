/* global MAIN_WINDOW_WEBPACK_ENTRY, MAIN_WINDOW_PRELOAD_WEBPACK_ENTRY */
import IDeviceClient from './ideviceclient'

const { app, autoUpdater, BrowserWindow, dialog, ipcMain, net, session } = require('electron')
const { updateElectronApp, UpdateSourceType } = require('update-electron-app')
const { initializeSession, isNativeMigrationBridge, startNativeMigration } = require('./native-migration')

const migrationBridge = isNativeMigrationBridge({
    isPackaged: app.isPackaged, platform: process.platform, version: app.getVersion(),
})
let migration

// Handle creating/removing shortcuts on Windows when installing/uninstalling.
if (require('electron-squirrel-startup')) {
    app.quit()
}

if (app.isPackaged && !migrationBridge) {
    updateElectronApp({
        updateSource: {
            type: UpdateSourceType.ElectronPublicUpdateService,
            repo: 'Harrilee/parachute',
        },
    })
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
const openInterface = () => {
    createWindow()
    if (migrationBridge) {
        migration = startNativeMigration({
            autoUpdater, platform: process.platform, arch: process.arch,
            systemVersion: process.getSystemVersion(),
            fetchManifest: (url, options) => net.fetch(url, options),
            onReady: async () => {
                const chinese = app.getPreferredSystemLanguages()[0]?.toLowerCase().startsWith('zh')
                const result = await dialog.showMessageBox({
                    type: 'info',
                    buttons: chinese ? ['重新启动并更新', '稍后'] : ['Restart and update', 'Later'],
                    defaultId: 1, cancelId: 1,
                    title: 'Parachute 0.4.0',
                    message: chinese ? '原生 macOS 版本已准备就绪。' : 'The native macOS version is ready.',
                    detail: chinese ? '重新启动会结束当前的位置模拟会话。选择稍后将在下次退出时安装。' :
                        'Restarting ends the current location simulation session. Choosing Later installs the update the next time you quit.',
                })
                return result.response === 0
            },
        })
    }
}
app.whenReady().then(async () => {
    // This interface does not need browser permissions or the Mac's location.
    session.defaultSession.setPermissionCheckHandler(() => false)
    session.defaultSession.setPermissionRequestHandler((_contents, _permission, callback) => callback(false))
    app.on('activate', () => {
        if (BrowserWindow.getAllWindows().length === 0) createWindow()
    })
    await initializeSession({
        bridge: migrationBridge,
        registerHandlers: () => {
            ipcMain.handle('is-developer-mode-enabled', isDeveloperModeEnabled)
            ipcMain.handle('enable-developer-mode', enableDeveloperMode)
            ipcMain.handle('mock-location', mockLocation)
        },
        openInterface,
        authorizeDevice: () => client.ensureAdminAccess(),
        startDevice: () => {
            client.startTunnel().catch(err => {
                console.warn(`Tunnel start at launch failed: ${err.message}`)
            })
            setInterval(async () => {
                const devices = await client.listDevices()
                sendToRenderer('device-list-update', devices)
            }, 1000)
        },
        onAuthorizationError: error => {
            console.error(`Device administrator access unavailable: ${error.message}`)
            if (!migrationBridge) app.quit()
        },
    })
})

app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') {
        app.quit()
    }
})

app.on('before-quit', () => {
    migration?.stop()
    client.cleanup()
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
