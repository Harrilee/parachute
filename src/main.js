import PyMobileDevice3Client from './pymobiledevice3client'

const { app, BrowserWindow, ipcMain } = require('electron')
const path = require('node:path')
const { exec } = require('child_process')

// Handle creating/removing shortcuts on Windows when installing/uninstalling.
if (require('electron-squirrel-startup')) {
    app.quit()
}

const createWindow = () => {
    const mainWindow = new BrowserWindow({
        width: 1000,
        height: 800,
        webPreferences: {
            preload: MAIN_WINDOW_PRELOAD_WEBPACK_ENTRY,
        },
    })

    mainWindow.loadURL(MAIN_WINDOW_WEBPACK_ENTRY)
    mainWindow.webContents.openDevTools()
}
app.whenReady().then(() => {
    /* IPC Registration */
    // Renderer to Main (two-way communication)
    ipcMain.handle('is-developer-mode-enabled', isDeveloperModeEnabled)
    // Main to Renderer
    setInterval(async () => {
        const client = new PyMobileDevice3Client(path.join(app.getAppPath(), 'src', 'venv', 'bin', 'python3'))
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

async function isDeveloperModeEnabled() {
    const client = new PyMobileDevice3Client(path.join(app.getAppPath(), 'src', 'venv', 'bin', 'python3'))
    const isEnabled = await client.isDeveloperModeEnabled()
    return isEnabled
}

function sendToRenderer(channel, data) {
    BrowserWindow.getAllWindows().forEach(win => {
        win.webContents.send(channel, data)
    })
}
