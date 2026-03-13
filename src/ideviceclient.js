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
      const verifyCmd = [
        `sudo -n '${this.binaryPath}' version >/dev/null 2>&1`,
        'sudo -n /bin/kill -0 $$ >/dev/null 2>&1',
        "sudo -n /usr/bin/pkill -f '^$' >/dev/null 2>&1; code=$?; [ $code -eq 0 ] || [ $code -eq 1 ]",
      ].join(' && ')
      execSync(verifyCmd, { timeout: 5000, stdio: 'ignore' })
      {
        console.log('Admin access verified for current binary')
        return
      }
    } catch (_) {}

    console.log('Requesting admin access (one-time setup)...')
    const user = process.env.USER
    const sudoersContent = `${user} ALL=(ALL) NOPASSWD: ${this.binaryPath}, /bin/kill, /usr/bin/pkill`
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

  _killCommandTree(child, useSudo = false) {
    if (!child?.pid) return

    try {
      process.kill(-child.pid, 'SIGKILL')
      return
    } catch (_) {
      // fall back below if group kill is not permitted
    }

    if (useSudo && process.platform === 'darwin') {
      try {
        execSync(`sudo -n /bin/kill -9 -- -${child.pid}`, { stdio: 'ignore' })
        return
      } catch (_) {
        // fall back to killing the wrapper if root children cannot be reached
      }
    }

    try {
      child.kill('SIGKILL')
    } catch (_) {
      // process already gone
    }
  }

  _spawnWithHangDetection(args, timeoutMs = 5000) {
    const useSudo = process.platform === 'darwin'
    return new Promise((resolve, reject) => {
      const child = useSudo
        ? spawn('sudo', ['-n', this.binaryPath, ...args], {
            stdio: ['ignore', 'pipe', 'pipe'],
            detached: true,
          })
        : spawn(this.binaryPath, args, {
            stdio: ['ignore', 'pipe', 'pipe'],
            detached: true,
          })

      let resolved = false
      let output = ''
      const timeout = setTimeout(() => {
        if (resolved) return
        resolved = true
        this._killCommandTree(child, useSudo)
        console.log(`${args[0]} still running after ${timeoutMs}ms, assuming success`)
        resolve('done')
      }, timeoutMs)

      const onData = data => {
        output += data.toString()
      }

      child.stdout.on('data', onData)
      child.stderr.on('data', onData)

      child.on('close', code => {
        if (resolved) return
        resolved = true
        clearTimeout(timeout)
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
        clearTimeout(timeout)
        reject(err)
      })
    })
  }

  async mockLocation(latitude, longitude) {
    console.log(`Setting location: ${latitude}, ${longitude}`)
    await this._spawnWithHangDetection(['setlocation', `--lat=${latitude}`, `--lon=${longitude}`], 300000)
    return 'mocked'
  }
}

export default IDeviceClient
