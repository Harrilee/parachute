const { spawn, execFile, execSync } = require('child_process')
const path = require('path')
const fs = require('fs')

const logFile = fs.createWriteStream('app.log', { flags: 'a' })
console.log = message => {
  logFile.write(`LOG ${new Date().toISOString()} - ${message}\n`)
}
console.error = message => {
  logFile.write(`ERR ${new Date().toISOString()} - ${message}\n`)
}
console.warn = message => {
  logFile.write(`WRN ${new Date().toISOString()} - ${message}\n`)
}

const ARCH_MAP = { x64: 'amd64', arm64: 'arm64' }
const PLATFORM_MAP = { darwin: 'darwin', linux: 'linux', win32: 'windows' }

function resolveGoIosBinary() {
  const platform = process.platform
  const arch = process.arch
  const binaryName = platform === 'win32' ? 'ios.exe' : 'ios'
  const goPlatform = PLATFORM_MAP[platform]
  const goArch = ARCH_MAP[arch] || 'amd64'
  const folderName = `go-ios-${goPlatform}-${goArch}_${goPlatform}_${goArch}`

  const candidates = [
    path.join(process.cwd(), 'node_modules', 'go-ios', 'dist', folderName, binaryName),
    process.resourcesPath && path.join(process.resourcesPath, binaryName),
  ].filter(Boolean)

  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      console.log(`go-ios binary found: ${candidate}`)
      return candidate
    }
  }

  throw new Error(
    `go-ios binary not found for ${platform}/${arch}. Searched:\n${candidates.join('\n')}`,
  )
}

class IDeviceClient {
  constructor() {
    this.binaryPath = resolveGoIosBinary()
    this.tunnelProcess = null
    this.deviceNameCache = {}
  }

  _exec(args, timeout = 15000) {
    return new Promise((resolve, reject) => {
      execFile(this.binaryPath, args, { timeout }, (error, stdout, stderr) => {
        if (error) {
          console.error(`go-ios exec error (${args.join(' ')}): ${error.message}`)
          reject(error)
          return
        }
        resolve(stdout.trim())
      })
    })
  }

  async _fetchDeviceName(udid) {
    try {
      const output = await this._exec(['devicename', `--udid=${udid}`])
      const lastLine = output.split('\n').filter(l => l.includes('devicename')).pop()
      if (lastLine) {
        const parsed = JSON.parse(lastLine)
        return parsed.devicename || null
      }
    } catch (error) {
      console.warn(`Failed to fetch device name for ${udid}: ${error.message}`)
    }
    return null
  }

  async listDevices() {
    try {
      const output = await this._exec(['list', '--details'])
      const data = JSON.parse(output)
      const devices = data.deviceList || (Array.isArray(data) ? data : [])

      const enriched = await Promise.all(
        devices.map(async d => {
          const udid = d.Udid || d.udid || ''
          if (udid && !this.deviceNameCache[udid]) {
            const name = await this._fetchDeviceName(udid)
            if (name) this.deviceNameCache[udid] = name
          }
          return {
            ...d,
            ConnectionType: 'USB',
            DeviceName: this.deviceNameCache[udid] || d.ProductType || 'iOS Device',
          }
        }),
      )

      return JSON.stringify(enriched)
    } catch (error) {
      console.error(`listDevices error: ${error}`)
      return '[]'
    }
  }

  async isDeveloperModeEnabled() {
    try {
      const output = await this._exec(['devmode', 'get'])
      const lower = output.toLowerCase()
      if (lower.includes('true') || lower.includes('enabled')) {
        return 'true'
      }
      this.enableDeveloperMode()
      return 'false'
    } catch (error) {
      console.error(`isDeveloperModeEnabled error: ${error}`)
      return 'false'
    }
  }

  async enableDeveloperMode() {
    try {
      await this._exec(['devmode', 'enable'], 30000)
    } catch (error) {
      console.error(`enableDeveloperMode error: ${error}`)
    }
  }

  async startTunnel() {
    if (this.tunnelProcess) {
      console.log('Tunnel already running')
      return 'tunnel already running'
    }

    if (process.platform === 'darwin') {
      try {
        execSync('pkill -SIGSTOP remoted', { stdio: 'ignore' })
        console.log('Paused remoted process')
      } catch (_) {
        // remoted may not be running
      }
    }

    try {
      execSync(
        "ps aux | grep 'ios tunnel' | grep -v grep | awk '{print $2}' | xargs kill -9 2>/dev/null",
        { stdio: 'ignore' },
      )
    } catch (_) {
      // no existing tunnel process
    }

    return new Promise((resolve, reject) => {
      console.log('Starting go-ios tunnel...')
      this.tunnelProcess = spawn(this.binaryPath, ['tunnel', 'start'], {
        stdio: ['ignore', 'pipe', 'pipe'],
      })

      let resolved = false
      const onOutput = data => {
        const text = data.toString()
        console.log(`tunnel: ${text}`)
        if (!resolved && text.toLowerCase().includes('tunnel')) {
          resolved = true
          resolve('tunnel started')
        }
      }

      this.tunnelProcess.stdout.on('data', onOutput)
      this.tunnelProcess.stderr.on('data', onOutput)

      this.tunnelProcess.on('error', err => {
        console.error(`tunnel error: ${err}`)
        this.tunnelProcess = null
        if (!resolved) {
          resolved = true
          reject(err)
        }
      })

      this.tunnelProcess.on('close', code => {
        console.log(`tunnel process exited with code ${code}`)
        this.tunnelProcess = null
      })

      setTimeout(() => {
        if (!resolved) {
          resolved = true
          resolve('tunnel started (timeout)')
        }
      }, 30000)
    })
  }

  async mockLocation(latitude, longitude, retry = 0) {
    if (latitude !== null && longitude !== null) {
      console.log(`Setting location: ${latitude}, ${longitude}`)
      try {
        await this._exec(['setlocation', `--lat=${latitude}`, `--lon=${longitude}`])
        return 'mocked'
      } catch (error) {
        if (retry > 0) {
          console.log(`Retrying setlocation... attempts left: ${retry}`)
          await new Promise(r => setTimeout(r, 2000))
          return this.mockLocation(latitude, longitude, retry - 1)
        }
        throw error
      }
    } else {
      console.log('Resetting location')
      await this._exec(['resetlocation'])
      return 'reset'
    }
  }
}

export default IDeviceClient
