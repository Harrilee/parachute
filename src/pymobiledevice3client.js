const { spawn, exec } = require('child_process')
const { BrowserWindow } = require('electron')
const path = require('node:path')

class PyMobileDevice3Client {
    constructor(pythonPath) {
        this.pythonPath = pythonPath
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
}

export default PyMobileDevice3Client
