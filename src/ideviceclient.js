const { spawn, execFile, execFileSync, execSync } = require('child_process')
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
    this.locationProcess = null
    this._tunnelPromise = null
    this.deviceNameCache = {}
    this._killOrphanedProcesses()
  }

  _killOrphanedProcesses() {
    try {
      if (process.platform === 'darwin') {
        const escapedPath = this.binaryPath.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
        execSync(
          `sudo -n /usr/bin/pkill -9 -f "${escapedPath} (tunnel start|setlocation)"`,
          { stdio: 'ignore' },
        )
      } else {
        execSync(
          "ps aux | grep -E 'ios (tunnel|setlocation)' | grep -v grep | awk '{print $2}' | xargs kill -9 2>/dev/null",
          { stdio: 'ignore' },
        )
      }
    } catch (_) {
      // no orphaned processes
    }
  }

  _execAsAdmin(cmd, timeout = 15000) {
    return new Promise((resolve, reject) => {
      const prompt = 'Parachute needs administrator access to communicate with your iOS device.'
      const script = `do shell script ${JSON.stringify(cmd)} with prompt ${JSON.stringify(prompt)} with administrator privileges`

      const appDir = path.join(app.getPath('userData'), 'admin-helper')
      const appPath = path.join(appDir, 'Parachute.app')

      try { fs.rmSync(appPath, { recursive: true, force: true }) } catch (_) {}
      fs.mkdirSync(appDir, { recursive: true })

      const runWithOsascript = () => {
        execFile('osascript', ['-e', script], { timeout, killSignal: 'SIGKILL' }, (error, stdout) => {
          if (error) {
            if (error.killed) { resolve(''); return }
            reject(error); return
          }
          resolve(stdout.trim())
        })
      }

      execFile('osacompile', ['-o', appPath, '-e', script], { timeout: 10000 }, compileErr => {
        if (compileErr) {
          console.warn('osacompile failed, falling back to osascript')
          runWithOsascript()
          return
        }

        const applet = path.join(appPath, 'Contents', 'MacOS', 'applet')
        execFile(applet, [], { timeout, killSignal: 'SIGKILL' }, (error, stdout) => {
          try { fs.rmSync(appPath, { recursive: true, force: true }) } catch (_) {}
          if (error) {
            if (error.killed) { resolve(''); return }
            reject(error); return
          }
          resolve((stdout || '').trim())
        })
      })
    })
  }

  async ensureAdminAccess() {
    if (process.platform !== 'darwin') return

    try {
      execFileSync('sudo', ['-n', this.binaryPath, 'version'], {
        timeout: 5000,
        stdio: 'ignore',
      })

      const pkill = spawn('sudo', ['-n', '/usr/bin/pkill', '-f', '^$'], {
        stdio: 'ignore',
      })
      await new Promise((resolve, reject) => {
        pkill.on('error', reject)
        pkill.on('exit', code => {
          if (code === 0 || code === 1) {
            resolve()
            return
          }
          reject(new Error(`pkill verification failed with code ${code}`))
        })
      })

      console.log('Admin access verified for current binary')
      return
    } catch (_) {}

    console.log('Requesting admin access (one-time setup)...')
    const user = process.env.USER
    const sudoersContent = `${user} ALL=(ALL) NOPASSWD: ${this.binaryPath}, /usr/bin/pkill`
    const cmd = `TMPFILE=$(mktemp) && printf '%s\\n' '${sudoersContent}' > "$TMPFILE" && /usr/sbin/visudo -c -f "$TMPFILE" 2>/dev/null && mv "$TMPFILE" /etc/sudoers.d/parachute && chmod 440 /etc/sudoers.d/parachute`
    await this._execAsAdmin(cmd, 30000)
    console.log('Admin access configured')
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

  _isTunnelRunning() {
    return this.tunnelProcess !== null
  }

  async startTunnel() {
    if (this._tunnelPromise) {
      return this._tunnelPromise
    }

    if (this._isTunnelRunning()) {
      console.log('Tunnel already running')
      return 'tunnel already running'
    }

    this._killOrphanedProcesses()

    if (process.platform === 'darwin') {
      this._tunnelPromise = this._startTunnelMacOS()
        .catch(async error => {
          const message = error?.message || ''
          if (message.includes('address already in use')) {
            console.warn('Tunnel port already in use, cleaning up and retrying once')
            this._killOrphanedProcesses()
            return this._startTunnelMacOS()
          }
          throw error
        })
        .finally(() => {
          this._tunnelPromise = null
        })
      return this._tunnelPromise
    }

    return this._startTunnelDirect()
  }

  _startTunnelMacOS() {
    try {
      execSync('pkill -SIGSTOP remoted', { stdio: 'ignore' })
      console.log('Paused remoted process')
    } catch (_) {}

    return new Promise((resolve, reject) => {
      console.log('Starting go-ios tunnel with sudo...')
      this.tunnelProcess = spawn('sudo', ['-n', this.binaryPath, 'tunnel', 'start'], {
        stdio: ['ignore', 'pipe', 'pipe'],
      })

      let resolved = false
      const onOutput = data => {
        const text = data.toString()
        console.log(`tunnel: ${text}`)
        if (!resolved && text.includes('Tunnel server started')) {
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
        if (!resolved) {
          resolved = true
          if (code !== 0) {
            reject(new Error(`tunnel process exited with code ${code}`))
          } else {
            resolve('tunnel closed')
          }
        }
      })

      setTimeout(() => {
        if (!resolved && this.tunnelProcess) {
          resolved = true
          resolve('tunnel started')
        }
      }, 3000)

      setTimeout(() => {
        if (!resolved) {
          resolved = true
          resolve('tunnel started (timeout)')
        }
      }, 30000)
    })
  }

  _startTunnelDirect() {
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

  _killLocationProcesses(commandName) {
    try {
      if (process.platform === 'darwin') {
        const escapedPath = this.binaryPath.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
        execSync(`sudo -n /usr/bin/pkill -9 -f "${escapedPath} ${commandName}"`, { stdio: 'ignore' })
      } else {
        execSync(
          `ps aux | grep -E "ios ${commandName}" | grep -v grep | awk '{print $2}' | xargs kill -9 2>/dev/null`,
          { stdio: 'ignore' },
        )
      }
    } catch (_) {
      // process already gone
    }
  }

  _stopLocationProcess() {
    if (this.locationProcess) {
      try {
        this.locationProcess.kill('SIGKILL')
      } catch (_) {
        // already exited
      }
      this.locationProcess = null
    }
    this._killLocationProcesses('setlocation')
  }

  _startLocationSession(args, readyTimeoutMs = 1500) {
    const useSudo = process.platform === 'darwin'
    return new Promise((resolve, reject) => {
      this._stopLocationProcess()

      const child = useSudo
        ? spawn('sudo', ['-n', this.binaryPath, ...args], {
            stdio: ['ignore', 'pipe', 'pipe'],
          })
        : spawn(this.binaryPath, args, {
            stdio: ['ignore', 'pipe', 'pipe'],
          })

      this.locationProcess = child
      let resolved = false
      let output = ''
      const readyTimer = setTimeout(() => {
        if (resolved) return
        resolved = true
        console.log(`${args[0]} session started`)
        resolve('done')
      }, readyTimeoutMs)

      const onData = data => {
        output += data.toString()
        if (
          output.includes('"level":"fatal"') ||
          output.includes('sudo: a password is required') ||
          output.includes('InvalidService')
        ) {
          if (resolved) return
          resolved = true
          clearTimeout(readyTimer)
          this._stopLocationProcess()
          reject(new Error(`${args[0]} failed: ${output}`))
        }
      }

      child.stdout.on('data', onData)
      child.stderr.on('data', onData)

      child.on('exit', code => {
        if (this.locationProcess === child) {
          this.locationProcess = null
        }
        if (resolved) return
        resolved = true
        clearTimeout(readyTimer)
        console.log(`${args[0]} exited with code ${code}: ${output}`)
        if (code === 0) {
          resolve('done')
        } else {
          reject(new Error(`${args[0]} failed: ${output}`))
        }
      })

      child.on('error', err => {
        if (this.locationProcess === child) {
          this.locationProcess = null
        }
        if (resolved) return
        resolved = true
        clearTimeout(readyTimer)
        reject(err)
      })
    })
  }

  async mockLocation(latitude, longitude) {
    console.log(`Setting location: ${latitude}, ${longitude}`)
    await this._startLocationSession(['setlocation', `--lat=${latitude}`, `--lon=${longitude}`])
    return 'mocked'
  }

  cleanup() {
    this._stopLocationProcess()
  }
}

export default IDeviceClient
