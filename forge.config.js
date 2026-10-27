const { FusesPlugin } = require('@electron-forge/plugin-fuses')
const { FuseV1Options, FuseVersion } = require('@electron/fuses')
const path = require('path')
const os = require('os')

const binaryName = os.platform() === 'win32' ? 'ios.exe' : 'ios'

module.exports = {
    packagerConfig: {
        asar: true,
        icon: path.join(__dirname, 'icon'),
        extraResource: [
            path.join(__dirname, 'bin', binaryName),
        ],
        osxSign: {
            identity: process.env.APPLE_SIGN_ID,
            keychain: process.env.KEYCHAIN_PATH,
            optionsForFile: () => ({
                entitlements: path.join(__dirname, 'entitlements.plist'),
                entitlementsInherit: path.join(__dirname, 'entitlements.child.plist'),
            }),
        },
        // Shared release tooling notarizes and retries ticket stapling.
    },
    rebuildConfig: {},
    makers: [
        {
            name: '@electron-forge/maker-squirrel',
            config: {},
        },
        {
            name: '@electron-forge/maker-zip',
            platforms: ['darwin'],
        },
        {
            name: '@electron-forge/maker-pkg',
            platforms: ['darwin'],
            config: {
                keychain: process.env.PKG_KEYCHAIN || process.env.KEYCHAIN_PATH,
            },
        },
        {
            name: '@electron-forge/maker-deb',
            config: {},
        },
        {
            name: '@electron-forge/maker-rpm',
            config: {},
        },
    ],
    plugins: [
        {
            name: '@electron-forge/plugin-auto-unpack-natives',
            config: {},
        },
        {
            name: '@electron-forge/plugin-webpack',
            config: {
                mainConfig: './webpack.main.config.js',
                renderer: {
                    config: './webpack.renderer.config.js',
                    entryPoints: [
                        {
                            html: './src/index.html',
                            js: './src/renderer.js',
                            name: 'main_window',
                            preload: {
                                js: './src/preload.js',
                            },
                        },
                    ],
                },
                devContentSecurityPolicy:
                    "script-src 'self' 'unsafe-eval' 'unsafe-inline' https://webapi.amap.com https://restapi.amap.com; worker-src 'self' blob:; object-src 'self'",
            },
        },
        // Fuses are used to enable/disable various Electron functionality
        // at package time, before code signing the application
        new FusesPlugin({
            version: FuseVersion.V1,
            [FuseV1Options.RunAsNode]: false,
            [FuseV1Options.EnableCookieEncryption]: true,
            [FuseV1Options.EnableNodeOptionsEnvironmentVariable]: false,
            [FuseV1Options.EnableNodeCliInspectArguments]: false,
            [FuseV1Options.EnableEmbeddedAsarIntegrityValidation]: true,
            [FuseV1Options.OnlyLoadAppFromAsar]: true,
        }),
    ],
}
