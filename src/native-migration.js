const BRIDGE_VERSION = '0.3.9'
const NATIVE_VERSION = '1.0.0'
const FEED_ROOT = 'https://raw.githubusercontent.com/Harrilee/parachute/main/updates'

function isNativeMigrationBridge({ isPackaged, platform, version }) {
    return isPackaged && platform === 'darwin' && version === BRIDGE_VERSION
}

function migrationFeedURL({ platform, arch, systemVersion }) {
    const match = /^(\d+)\.(\d+)(?:\.|$)/.exec(systemVersion || '')
    if (platform !== 'darwin' || !['arm64', 'x64'].includes(arch) || !match || Number(match[1]) < 14) return null
    return `${FEED_ROOT}/electron-migration-${arch}.json`
}

function hasNativeRelease(manifest, arch) {
    if (manifest?.currentRelease !== NATIVE_VERSION || !Array.isArray(manifest.releases)) return false
    const release = manifest.releases.find(item => item.version === NATIVE_VERSION)?.updateTo
    return release?.version === NATIVE_VERSION && release.url ===
        `https://github.com/Harrilee/parachute/releases/download/v${NATIVE_VERSION}/Parachute-native-${arch}-${NATIVE_VERSION}.zip`
}

// Keep the bridge's upgrade path independent of optional device privileges.
// Register IPC first, because opening the renderer can immediately call it.
async function initializeSession({ bridge, registerHandlers, openInterface,
    authorizeDevice, startDevice, onAuthorizationError }) {
    registerHandlers()
    if (bridge) openInterface()
    try {
        await authorizeDevice()
    } catch (error) {
        onAuthorizationError(error)
        return false
    }
    startDevice()
    if (!bridge) openInterface()
    return true
}

// Start after the existing window is created. Missing feeds and unpublished
// native releases never delay or close the working Electron interface.
function startNativeMigration({ autoUpdater, platform, arch, systemVersion, fetchManifest,
    onReady, logger = console, intervalMilliseconds = 10 * 60_000,
    timeoutMilliseconds = 10_000, schedule = setTimeout, unschedule = clearTimeout,
    repeat = setInterval, stopRepeating = clearInterval }) {
    const url = migrationFeedURL({ platform, arch, systemVersion })
    if (!url) return { initialCheck: Promise.resolve(false), check: async () => false, stop() {} }
    let stopped = false
    let checking = false
    let waitingForUpdater = false
    let ready = false
    let controller
    let fetchTimer
    const finishCheck = () => { checking = false; waitingForUpdater = false }
    const failed = error => {
        finishCheck()
        if (!stopped) logger.warn(`Native migration check unavailable: ${error.message || error}`)
    }
    const downloaded = async () => {
        if (stopped || ready) return
        ready = true
        finishCheck()
        stopRepeating(interval)
        try {
            const install = await onReady()
            if (install && !stopped) autoUpdater.quitAndInstall()
        } catch (error) {
            if (!stopped) logger.warn(`Native migration restart unavailable: ${error.message || error}`)
        }
    }
    autoUpdater.on('error', failed)
    autoUpdater.on('update-not-available', finishCheck)
    autoUpdater.on('update-downloaded', downloaded)

    const check = async () => {
        if (stopped || checking || ready) return false
        checking = true
        controller = new AbortController()
        fetchTimer = schedule(() => controller?.abort(), timeoutMilliseconds)
        fetchTimer?.unref?.()
        try {
            const response = await fetchManifest(url, { signal: controller.signal })
            if (response.status === 404 || response.status === 204) return false
            if (!response.ok) throw new Error(`Manifest request returned HTTP ${response.status}`)
            const text = await response.text()
            if (!text.trim()) return false
            if (text.length > 64 * 1024) throw new Error('Migration manifest is too large')
            const manifest = JSON.parse(text)
            if (stopped || !hasNativeRelease(manifest, arch)) return false
            // Keep the static JSON feed pinned to the first native release.
            // Squirrel performs publisher, bundle, and nested-signature checks.
            autoUpdater.setFeedURL({ url, serverType: 'json' })
            waitingForUpdater = true
            autoUpdater.checkForUpdates()
            return true
        } catch (error) {
            failed(error)
            return false
        } finally {
            unschedule(fetchTimer)
            controller = undefined
            if (!waitingForUpdater) checking = false
        }
    }
    const interval = repeat(() => { void check() }, intervalMilliseconds)
    interval?.unref?.()
    return {
        check,
        initialCheck: check(),
        stop() {
            stopped = true
            controller?.abort()
            unschedule(fetchTimer)
            stopRepeating(interval)
            autoUpdater.removeListener('update-not-available', finishCheck)
            autoUpdater.removeListener('update-downloaded', downloaded)
            // An already running macOS updater cannot be cancelled. Keep its
            // harmless error listener so a late EventEmitter error cannot crash.
        },
    }
}

module.exports = { BRIDGE_VERSION, NATIVE_VERSION, initializeSession, isNativeMigrationBridge,
    migrationFeedURL, hasNativeRelease, startNativeMigration }
