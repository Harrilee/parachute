const { FusesPlugin } = require('@electron-forge/plugin-fuses')
const { FuseV1Options, FuseVersion } = require('@electron/fuses')
const path = require('path')
const os = require('os')

const binaryName = os.platform() === 'win32' ? 'ios.exe' : 'ios'

module.exports = {
    packagerConfig: {
        asar: true,
        icon: path.join(__dirname, 'icon'),
        extendInfo: {
            NSLocationWhenInUseUsageDescription: 'Parachute needs your location to center the map on your current position.',
            NSLocationUsageDescription: 'Parachute needs your location to center the map on your current position.',
        },
        extraResource: [
            path.join(__dirname, 'bin', binaryName),
        ],
        osxSign: {
            optionsForFile: () => ({
                entitlements: path.join(__dirname, 'entitlements.plist'),
                entitlementsInherit: path.join(__dirname, 'entitlements.child.plist'),
            }),
        },
        osxNotarize: {
            appleId: process.env.APPLE_ID,
            appleIdPassword: process.env.APPLE_PASSWORD,
            teamId: process.env.APPLE_TEAM_ID,
        },
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
