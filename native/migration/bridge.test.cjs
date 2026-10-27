const test = require('node:test')
const assert = require('node:assert/strict')
const { EventEmitter } = require('node:events')
const { isNativeMigrationBridge, migrationFeedURL, migrateToNative } = require('../../src/native-migration.js')

function fixture(overrides = {}) {
    const updater = new EventEmitter()
    updater.checks = 0
    updater.installs = 0
    updater.setFeedURL = value => { updater.feed = value }
    updater.checkForUpdates = () => { updater.checks += 1 }
    updater.quitAndInstall = () => { updater.installs += 1 }
    let timeout
    let cleared = false
    const options = {
        app: { getVersion: () => '0.3.9' }, autoUpdater: updater,
        platform: 'darwin', arch: 'arm64', systemVersion: '14.0',
        logger: { log() {}, error() {} },
        schedule: callback => { timeout = callback; return 42 },
        unschedule: value => { assert.equal(value, 42); cleared = true },
        ...overrides,
    }
    return { updater, run: () => migrateToNative(options), expire: () => timeout(), cleared: () => cleared }
}

test('only the packaged macOS 0.3.9 bridge takes the migration path', () => {
    const base = { isPackaged: true, platform: 'darwin', version: '0.3.9' }
    assert.equal(isNativeMigrationBridge(base), true)
    for (const changed of [{ isPackaged: false }, { platform: 'win32' }, { platform: 'linux' }, { version: '0.3.8' }, { version: '1.0.0' }]) {
        assert.equal(isNativeMigrationBridge({ ...base, ...changed }), false)
    }
})

test('old macOS and invalid/unsupported inputs never receive the native feed', () => {
    for (const systemVersion of ['10.15.7', '11.7.10', '12.7', '13.6.9', '', 'invalid', '14']) {
        assert.equal(migrationFeedURL({ platform: 'darwin', arch: 'x64', systemVersion }), null)
    }
    assert.equal(migrationFeedURL({ platform: 'win32', arch: 'x64', systemVersion: '14.0' }), null)
    assert.equal(migrationFeedURL({ platform: 'darwin', arch: 'ia32', systemVersion: '14.0' }), null)
})

test('eligible architectures use separate HTTPS feeds pinned to the migration entry point', () => {
    for (const arch of ['arm64', 'x64']) {
        assert.equal(migrationFeedURL({ platform: 'darwin', arch, systemVersion: '26.0.1' }),
            `https://raw.githubusercontent.com/Harrilee/parachute/main/updates/electron-migration-${arch}.json`)
    }
})

test('unsupported macOS immediately returns the legacy fallback without checking updates', async () => {
    const f = fixture({ systemVersion: '13.7' })
    assert.equal(await f.run(), false)
    assert.equal(f.updater.checks, 0)
})

test('signed update-downloaded proceeds once and clears the fallback timer', async () => {
    const f = fixture()
    const outcome = f.run()
    assert.equal(f.updater.feed.serverType, 'json')
    assert.equal(f.updater.checks, 1)
    f.updater.emit('update-downloaded')
    assert.equal(await outcome, true)
    f.updater.emit('update-downloaded')
    assert.equal(f.updater.installs, 1)
    assert.equal(f.cleared(), true)
})

test('network failures return legacy UI and tolerate subsequent updater errors', async () => {
    const f = fixture()
    const outcome = f.run()
    f.updater.emit('error', new Error('offline'))
    assert.equal(await outcome, false)
    assert.doesNotThrow(() => f.updater.emit('error', new Error('late network error')))
    f.updater.emit('update-downloaded')
    assert.equal(f.updater.installs, 0)
})

test('no update returns the legacy fallback', async () => {
    const f = fixture()
    const outcome = f.run()
    f.updater.emit('update-not-available')
    assert.equal(await outcome, false)
    assert.equal(f.cleared(), true)
})

test('a stalled check falls back and never triggers a late quitAndInstall', async () => {
    const f = fixture()
    const outcome = f.run()
    f.expire()
    assert.equal(await outcome, false)
    f.updater.emit('update-downloaded')
    assert.equal(f.updater.installs, 0)
    assert.doesNotThrow(() => f.updater.emit('error', new Error('late timeout')))
})

test('synchronous updater failures use the same bounded fallback', async () => {
    const f = fixture()
    f.updater.setFeedURL = () => { throw new Error('invalid feed') }
    assert.equal(await f.run(), false)
    assert.equal(f.cleared(), true)
})

test('a relaunch error returns the legacy fallback', async () => {
    const f = fixture()
    f.updater.quitAndInstall = () => { throw new Error('cannot relaunch') }
    const outcome = f.run()
    f.updater.emit('update-downloaded')
    assert.equal(await outcome, false)
})
