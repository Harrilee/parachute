const { spawn, execFile, execSync } = require('child_process')
const path = require('path')
const fs = require('fs')
const { app } = require('electron')

const logPath = path.join(app.getPath('userData'), 'app.log')
const logFile = fs.createWriteStream(logPath, { flags: 'a' })
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
    this._killOrphanedProcesses()
  }

  _killOrphanedProcesses() {
    try {
      execSync(
        "ps aux | grep -E 'ios (tunnel|setlocation|resetlocation)' | grep -v grep | awk '{print $2}' | xargs kill -9 2>/dev/null",
        { stdio: 'ignore' },
      )
    } catch (_) {
      // no orphaned processes
    }
  }

  _exec(args, timeout = 15000) {
    return new Promise((resolve, reject) => {
      execFile(this.binaryPath, args, { timeout, killSignal: 'SIGKILL' }, (error, stdout, stderr) => {
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

    this._killOrphanedProcesses()

    return new Promise((resolve, reject) => {
      console.log('Starting go-ios tunnel...')
      this.tunnelProcess = spawn(this.binaryPath, ['tunnel', 'start'], {
        stdio: ['ignore', 'pipe', 'pipe'],
      })

      let resolved = false
      const onOutput = data => {
        const text = data.toString()
        console.log(`tunnel: ${text}`)
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
        if (!resolved) {
          resolved = true
          if (code !== 0) {
            reject(new Error(`tunnel process exited with code ${code}`))
          } else {
            resolve('tunnel closed')
          }
        }
      })

      // If the process is still alive after 2s, the tunnel is running
      setTimeout(() => {
        if (!resolved && this.tunnelProcess) {
          resolved = true
          resolve('tunnel started')
        }
      }, 2000)

      setTimeout(() => {
        if (!resolved) {
          resolved = true
          resolve('tunnel started (timeout)')
        }
      }, 30000)
    })
  }

  _spawnWithHangDetection(args, timeoutMs = 5000) {
    return new Promise((resolve, reject) => {
      const child = spawn(this.binaryPath, args, {
        stdio: ['ignore', 'pipe', 'pipe'],
      })

      let resolved = false
      let output = ''

      const onData = data => {
        output += data.toString()
      }

      child.stdout.on('data', onData)
      child.stderr.on('data', onData)

      child.on('close', code => {
        if (resolved) return
        resolved = true
        console.log(`${args[0]} exited with code ${code}: ${output}`)
        if (code === 0) {
          resolve('done')
        } else {
          reject(new Error(`${args[0]} failed: ${output}`))
        }
      })

      child.on('error', err => {
        if (resolved) return
        resolved = true
        reject(err)
      })

      // go-ios hangs after successfully completing location operations;
      // if the process is still running after timeoutMs, treat as success
      setTimeout(() => {
        if (resolved) return
        resolved = true
        child.kill('SIGKILL')
        console.log(`${args[0]} still running after ${timeoutMs}ms, assuming success`)
        resolve('done')
      }, timeoutMs)
    })
  }

  async mockLocation(latitude, longitude) {
    if (latitude !== null && longitude !== null) {
      console.log(`Setting location: ${latitude}, ${longitude}`)
      await this._spawnWithHangDetection(['setlocation', `--lat=${latitude}`, `--lon=${longitude}`])
      return 'mocked'
    } else {
      console.log('Resetting location')
      await this._spawnWithHangDetection(['resetlocation'])
      return 'reset'
    }
  }
}

export default IDeviceClient
