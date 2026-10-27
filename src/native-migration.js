// This compatibility build is the permanent destination of the old public feed.
// Native ZIP names deliberately do not match update.electronjs.org's heuristics.
const BRIDGE_VERSION = '0.3.9'
const FEED_ROOT = 'https://raw.githubusercontent.com/Harrilee/parachute/main/updates'

function isNativeMigrationBridge({ isPackaged, platform, version }) {
    return isPackaged && platform === 'darwin' && version === BRIDGE_VERSION
}

function migrationFeedURL({ platform, arch, systemVersion }) {
    const match = /^(\d+)\.(\d+)(?:\.|$)/.exec(systemVersion || '')
    if (platform !== 'darwin' || !['arm64', 'x64'].includes(arch) || !match || Number(match[1]) < 14) {
        return null
    }
    return `${FEED_ROOT}/electron-migration-${arch}.json`
}

// Called only after app.whenReady(). The bridge is installed through the old
// updater's existing update flow. Its second step uses the same signed-bundle
// validation, without starting device processes or requesting administrator access.
function migrateToNative({ app, autoUpdater, platform, arch, systemVersion, logger = console,
    timeoutMilliseconds = 90_000, schedule = setTimeout, unschedule = clearTimeout }) {
    const url = migrationFeedURL({ platform, arch, systemVersion })
    if (!url) return Promise.resolve(false)

    return new Promise(resolve => {
        let finished = false
        let timer
        const finish = migrated => {
            if (finished) return
            finished = true
            if (timer !== undefined) unschedule(timer)
            // Keep a harmless error listener after fallback: an in-flight native
            // updater can still report a late network error on this EventEmitter.
            autoUpdater.removeListener('update-not-available', unavailable)
            autoUpdater.removeListener('update-downloaded', downloaded)
            resolve(migrated)
        }
        const failed = error => {
            logger.error(`Native migration unavailable; opening the current version: ${error.message || error}`)
            finish(false)
        }
        const unavailable = () => finish(false)
        const downloaded = () => {
            if (finished) return
            try {
                // On macOS Squirrel validates the publisher and bundle identity
                // before this event. The native bundle supplies the relaunch shim.
                autoUpdater.quitAndInstall()
                finish(true)
            } catch (error) {
                failed(error)
            }
        }
        autoUpdater.on('error', failed)
        autoUpdater.on('update-not-available', unavailable)
        autoUpdater.on('update-downloaded', downloaded)
        timer = schedule(() => failed(new Error('The native update timed out')), timeoutMilliseconds)
        try {
            logger.log(`Parachute ${app.getVersion()}: checking the native migration feed`)
            autoUpdater.setFeedURL({ url, serverType: 'json' })
            autoUpdater.checkForUpdates()
        } catch (error) {
            failed(error)
        }
    })
}

module.exports = { BRIDGE_VERSION, isNativeMigrationBridge, migrationFeedURL, migrateToNative }
