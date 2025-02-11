const { spawn, exec } = require('child_process')
const { BrowserWindow } = require('electron')
const path = require('node:path')
const sudo = require('sudo-prompt')

// // Create a write stream (append mode) to a file named 'app.log'
// const fs = require('fs')
// const logFile = fs.createWriteStream('app.log', { flags: 'a' })
// console.log = message => {
//     logFile.write(`LOG ${new Date().toISOString()} - ${message}\n`)
// }
// console.error = message => {
//     logFile.write(`ERR ${new Date().toISOString()} - ${message}\n`)
// }
// console.warn = message => {
//     logFile.write(`WRN ${new Date().toISOString()} - ${message}\n`)
// }

class PyMobileDevice3Client {
    constructor(pythonPath) {
        this.pythonPath = pythonPath
        this.tunneldProcess = null
        this.simLocationProcess = null
    }

    async listDevices() {
        return new Promise((resolve, reject) => {
            exec(`${this.pythonPath} -m pymobiledevice3 usbmux list`, (error, stdout, stderr) => {
                if (error) {
                    console.error(`exec error: ${error}`)
                    reject(error)
                    return
                }
                if (stdout) {
                    resolve(stdout)
                }
                if (stderr) {
                    reject(stderr)
                }
            })
        })
    }

    async isDeveloperModeEnabled() {
        return new Promise((resolve, reject) => {
            exec(`${this.pythonPath} -m pymobiledevice3 amfi developer-mode-status`, (error, stdout, stderr) => {
                if (error) {
                    console.error(`exec error: ${error}`)
                    reject(error)
                    return
                }
                if (stdout) {
                    if (stdout.includes('false')) {
                        this.revealDeveloperMenu()
                    }
                    resolve(stdout)
                }
                if (stderr) {
                    reject(stderr)
                }
            })
        })
    }

    async revealDeveloperMenu() {
        return new Promise((resolve, reject) => {
            exec(`${this.pythonPath} -m pymobiledevice3 amfi reveal-developer-mode`, (error, stdout, stderr) => {
                if (error) {
                    console.error(`exec error: ${error}`)
                    reject(error)
                    return
                }
                if (stdout) {
                    resolve(stdout)
                }
                if (stderr) {
                    reject(stderr)
                }
            })
        })
    }

    /**
     * @deprecated startTunnelD is not necessary when mock a location
     */
    async startTunnelD() {
        const options = {
            name: 'Parachute Virtual Location',
        }
        this.tunneldProcess = sudo.exec(
            `ps aux | grep 'pymobiledevice3 remote tunneld' | grep -v grep | awk '{print $2}' | xargs kill -9 && \
            ${this.pythonPath} -m pymobiledevice3 remote tunneld`,
            options,
            (error, stdout, stderr) => {
                if (error) {
                    console.error(`exec error: ${error}`)
                }
                if (stdout) {
                    console.log(`stdout: ${stdout}`)
                }
                if (stderr) {
                    console.error(`stderr: ${stderr}`)
                }
            }
        )
    }

    async mockLocation(latitude, longitude, retry = 0) {
        try {
            await this.stopMockLocation()
        } catch (error) {
            console.warn('No existing location mock process found')
        }
        await new Promise(resolve => setTimeout(resolve, 1000))
        return new Promise((resolve, reject) => {
            let params = ['-m', 'pymobiledevice3', 'developer', 'dvt', 'simulate-location']
            if (latitude !== null && longitude !== null) {
                params = params.concat(['set', '--', latitude, longitude])
            } else {
                params = params.concat(['clear'])
            }
            const childProcess = spawn(`${this.pythonPath}`, params)
            childProcess.stdout.on('data', data => {
                if (data) console.log(`stdout: ${data}`)
                resolve('mocked')
            })
            childProcess.stderr.on('data', async data => {
                if (retry === 0) {
                    reject(data)
                } else {
                    try {
                        console.log(`Retrying... ${retry}`)
                        await new Promise(resolve => setTimeout(resolve, 2000))
                        await this.mockLocation(latitude, longitude, retry - 1)
                        resolve('mocked')
                    } catch (error) {
                        console.error(`stderr: ${data}`)
                        reject(error)
                    }
                }
            })
            childProcess.on('close', code => {
                console.log(`child process exited with code ${code}`)
                resolve('exit')
            })
        })
    }

    async stopMockLocation() {
        return new Promise((resolve, reject) => {
            const options = {
                name: 'Parachute Virtual Location',
            }
            exec(
                "ps aux | grep 'pymobiledevice3 developer dvt simulate-location' | grep -v grep | awk '{print $2}' | xargs kill -9",
                options,
                (error, stdout, stderr) => {
                    if (error) {
                        console.error(`exec error: ${error}`)
                        reject(error)
                        return
                    }
                    if (stderr) {
                        console.error(`stderr: ${stderr}`)
                    } else {
                        console.log(`stdout: ${stdout}`)
                        resolve(stdout)
                    }
                }
            )
        })
    }
}

export default PyMobileDevice3Client
