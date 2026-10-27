const { test } = require('node:test')
const assert = require('node:assert/strict')
const { EventEmitter } = require('node:events')
const { BRIDGE_VERSION, NATIVE_VERSION, isNativeMigrationBridge, migrationFeedURL,
    hasNativeRelease, initializeSession, startNativeMigration } = require('../src/native-migration')

const environment = { platform: 'darwin', arch: 'arm64', systemVersion: '14.0' }
const manifest = () => ({ currentRelease: NATIVE_VERSION, releases: [{ version: NATIVE_VERSION,
    updateTo: { version: NATIVE_VERSION,
        url: 'https://github.com/Harrilee/parachute/releases/download/v0.4.0/Parachute-native-arm64-0.4.0.zip' } }] })
const response = (body, status = 200) => ({ status, ok: status >= 200 && status < 300,
    text: async () => typeof body === 'string' ? body : JSON.stringify(body) })
const tick = () => new Promise(resolve => setImmediate(resolve))

function fixture(options = {}) {
    const updater = new EventEmitter()
    const calls = { feeds: [], checks: 0, installs: 0, prompts: 0, fetches: 0, warnings: [], stopped: 0 }
    updater.setFeedURL = value => calls.feeds.push(value)
    updater.checkForUpdates = () => { calls.checks++ }
    updater.quitAndInstall = () => { calls.installs++ }
    const timers = new Map()
    let nextTimer = 0
    let periodic
    const migration = startNativeMigration({ ...environment, autoUpdater: updater,
        fetchManifest: async () => { calls.fetches++; return response(manifest()) },
        onReady: async () => { calls.prompts++; return true },
        logger: { warn: message => calls.warnings.push(message) },
        schedule: callback => { timers.set(++nextTimer, callback); return nextTimer },
        unschedule: id => timers.delete(id),
        repeat: callback => { periodic = callback; return 42 },
        stopRepeating: () => { calls.stopped++ },
        ...options,
    })
    return { migration, updater, calls, timers, periodic: () => periodic?.() }
}

test('only the packaged macOS 0.3.9 app disables the old public updater', () => {
    assert.equal(BRIDGE_VERSION, '0.3.9')
    assert.equal(isNativeMigrationBridge({ isPackaged: true, platform: 'darwin', version: '0.3.9' }), true)
    for (const value of [{ isPackaged: false, platform: 'darwin', version: '0.3.9' },
        { isPackaged: true, platform: 'win32', version: '0.3.9' },
        { isPackaged: true, platform: 'darwin', version: '0.3.8' }]) {
        assert.equal(isNativeMigrationBridge(value), false)
    }
})

test('older macOS, unsupported platforms and architectures never check the native feed', async () => {
    for (const value of [{ systemVersion: '13.7' }, { systemVersion: 'unknown' },
        { platform: 'win32' }, { arch: 'ia32' }]) {
        const f = fixture(value)
        assert.equal(await f.migration.initialCheck, false)
        assert.equal(f.calls.fetches, 0)
        assert.equal(f.updater.listenerCount('error'), 0)
        f.migration.stop()
    }
    assert.match(migrationFeedURL({ ...environment, arch: 'x64' }), /electron-migration-x64\.json$/)
})

test('missing, empty and placeholder feeds silently preserve the existing app', async () => {
    for (const result of [response('', 404), response('', 204), response(''),
        response({ currentRelease: '0.3.9', releases: [] }), response({ releases: [] })]) {
        const f = fixture({ fetchManifest: async () => result })
        assert.equal(await f.migration.initialCheck, false)
        assert.equal(f.calls.checks, 0)
        assert.equal(f.calls.prompts, 0)
        assert.deepEqual(f.calls.warnings, [])
        f.migration.stop()
    }
})

test('only the architecture-specific first native0.4.0 release is eligible', () => {
    assert.equal(hasNativeRelease(manifest(), 'arm64'), true)
    assert.equal(hasNativeRelease(manifest(), 'x64'), false)
    for (const mutate of [m => { m.currentRelease = '0.4.1' },
        m => { m.releases[0].updateTo.url = 'http://example.com/app.zip' },
        m => { m.releases[0].updateTo.version = '1.0.0' }]) {
        const m = manifest(); mutate(m)
        assert.equal(hasNativeRelease(m, 'arm64'), false)
    }
})

test('a later periodic retry discovers the native release without restarting Electron', async () => {
    let published = false
    const f = fixture({ fetchManifest: async () => response(published ? manifest() : '') })
    assert.equal(await f.migration.initialCheck, false)
    published = true
    f.periodic()
    await tick()
    assert.equal(f.calls.checks, 1)
    assert.deepEqual(f.calls.feeds, [{ url: migrationFeedURL(environment), serverType: 'json' }])
    assert.equal(await f.migration.check(), false, 'Never overlap an updater download')
    f.updater.emit('update-not-available')
    assert.equal(await f.migration.check(), true)
    f.migration.stop()
})

test('network failure and malformed manifest recover on the next check', async () => {
    let attempt = 0
    const f = fixture({ fetchManifest: async () => {
        if (++attempt === 1) throw new Error('offline')
        return response(attempt === 2 ? 'broken JSON' : manifest())
    } })
    assert.equal(await f.migration.initialCheck, false)
    assert.equal(await f.migration.check(), false)
    assert.equal(await f.migration.check(), true)
    assert.equal(f.calls.warnings.length, 2)
    f.migration.stop()
})

test('a pending manifest fetch does not block the caller, overlap, or outlive stop', async () => {
    let resolve
    let signal
    const f = fixture({ fetchManifest: (_url, options) => {
        signal = options.signal
        return new Promise(done => { resolve = done })
    } })
    assert.equal(await f.migration.check(), false)
    f.migration.stop()
    assert.equal(signal.aborted, true)
    resolve(response(manifest()))
    assert.equal(await f.migration.initialCheck, false)
    assert.equal(f.calls.checks, 0)
})

test('a ten-second fetch timeout aborts and permits a future retry', async () => {
    const f = fixture({ fetchManifest: (_url, options) => new Promise((_resolve, reject) => {
        options.signal.addEventListener('abort', () => reject(new Error('request aborted')))
    }) })
    assert.equal(f.timers.size, 1)
    Array.from(f.timers.values())[0]()
    assert.equal(await f.migration.initialCheck, false)
    assert.equal(f.timers.size, 0)
    assert.equal(f.calls.checks, 0)
    f.migration.stop()
})

test('a downloaded update asks once and installs only after restart is chosen', async () => {
    for (const decision of [true, false]) {
        let prompts = 0
        const f = fixture({ onReady: async () => { prompts++; return decision } })
        await f.migration.initialCheck
        f.updater.emit('update-downloaded')
        f.updater.emit('update-downloaded')
        await tick()
        assert.equal(prompts, 1)
        assert.equal(f.calls.installs, decision ? 1 : 0)
        assert.equal(await f.migration.check(), false)
        f.migration.stop()
    }
})

test('stopping while the restart dialog is open prevents a late forced restart', async () => {
    let decide
    const f = fixture({ onReady: () => new Promise(resolve => { decide = resolve }) })
    await f.migration.initialCheck
    f.updater.emit('update-downloaded')
    f.migration.stop()
    decide(true)
    await tick()
    assert.equal(f.calls.installs, 0)
    assert.doesNotThrow(() => f.updater.emit('error', new Error('late updater error')))
})

test('updater errors release the request gate without quitting the working application', async () => {
    const f = fixture()
    await f.migration.initialCheck
    f.updater.emit('error', new Error('download failed'))
    assert.equal(await f.migration.check(), true)
    assert.equal(f.calls.installs, 0)
    f.migration.stop()
})

test('the bridge can update while authorization is pending or cancelled, with IPC ready before the UI', async () => {
    const events = []
    let rejectAuthorization
    let f
    const startup = initializeSession({
        bridge: true,
        registerHandlers: () => events.push('IPC ready'),
        openInterface: () => { events.push('window'); f = fixture() },
        authorizeDevice: () => new Promise((_resolve, reject) => { rejectAuthorization = reject }),
        startDevice: () => events.push('device started'),
        onAuthorizationError: error => events.push(error.message),
    })
    assert.deepEqual(events, ['IPC ready', 'window'])
    assert.equal(await f.migration.initialCheck, true)
    rejectAuthorization(new Error('authorization cancelled'))
    assert.equal(await startup, false)
    assert.deepEqual(events, ['IPC ready', 'window', 'authorization cancelled'])
    f.updater.emit('update-downloaded')
    await tick()
    assert.equal(f.calls.installs, 1, 'Upgrade must remain possible without device privileges')
    f.migration.stop()
})

test('authorized bridge starts device work once without reopening its window', async () => {
    const events = []
    assert.equal(await initializeSession({
        bridge: true,
        registerHandlers: () => events.push('IPC ready'),
        openInterface: () => events.push('window'),
        authorizeDevice: async () => events.push('authorized'),
        startDevice: () => events.push('device started'),
        onAuthorizationError: () => assert.fail('Unexpected authorization failure'),
    }), true)
    assert.deepEqual(events, ['IPC ready', 'window', 'authorized', 'device started'])
})

test('non-bridge startup preserves its authorization gate', async () => {
    let opened = false
    let failed = false
    assert.equal(await initializeSession({
        bridge: false, registerHandlers() {}, openInterface: () => { opened = true },
        authorizeDevice: async () => { throw new Error('denied') },
        startDevice: () => assert.fail('Unauthorized device operation'),
        onAuthorizationError: () => { failed = true },
    }), false)
    assert.equal(opened, false)
    assert.equal(failed, true)
})
