import React, { useEffect, useState } from 'react'

import { PHONE_CONNECTION_STATUS, LOCATION_SIMULATION_STATUS } from '../utils.js'

import Dialog from '@mui/material/Dialog'
import DialogContent from '@mui/material/DialogContent'
import DialogContentText from '@mui/material/DialogContentText'
import DialogTitle from '@mui/material/DialogTitle'

import Snackbar from '@mui/material/Snackbar'
import Alert from '@mui/material/Alert'

import trustComputer from '../images/trust-computer.png'
import enableDevMode from '../images/enable-devmode.png'

export default function ControlCenter(props) {
    const {
        longitude,
        latitude,
        phoneConnectionStatus,
        setPhoneConnectionStatus,
        locationSimulationStatus,
        setLocationSimulationStatus,
    } = props

    const [deviceName, setDeviceName] = useState()

    // dialog
    const [openConnectionTips, setOpenConnectionTips] = useState(false)
    const [openDevTips, setOpenDevTips] = useState(false)
    const handleCloseConnectionTips = () => {
        setOpenConnectionTips(false)
    }
    const handleOpenConnectionTips = () => {
        setOpenConnectionTips(true)
    }
    const handleCloseDevTips = () => {
        setOpenDevTips(false)
    }
    const handleOpenDevTips = () => {
        setOpenDevTips(true)
    }

    // snackbar
    const [snackbarOpen, setSnackbarOpen] = useState(false)
    const [snackbarMessage, setSnackbarMessage] = useState('')
    const [snackbarSeverity, setSnackbarSeverity] = useState('success')
    const handleSnackbarOpen = (message, severity) => {
        setSnackbarMessage(message)
        setSnackbarSeverity(severity)
        setSnackbarOpen(true)
    }
    const handleSnackbarClose = () => {
        setSnackbarOpen(false)
    }

    // check if developer mode is enabled
    function isDeveloperModeEnabled() {
        window.electronAPI.isDeveloperModeEnabled().then(isEnabled => {
            if (isEnabled.includes('true')) {
                setPhoneConnectionStatus(PHONE_CONNECTION_STATUS.CONNECTED_DEVELOPER_MODE_ON)
            } else {
                setPhoneConnectionStatus(PHONE_CONNECTION_STATUS.CONNECTED_DEVELOPER_MODE_OFF)
            }
        })
    }

    function mockLocation() {
        console.log(latitude, longitude)
        if (latitude === '-' || longitude === '-') {
            handleSnackbarOpen('请先在地图上选择一个位置', 'error')
            return
        }
        setLocationSimulationStatus(LOCATION_SIMULATION_STATUS.LOADING)
        window.electronAPI
            .mockLocation(latitude, longitude)
            .then(res => {
                setLocationSimulationStatus(LOCATION_SIMULATION_STATUS.COMPLETED)
                handleSnackbarOpen('位置模拟成功', 'success')
            })
            .catch(e => {
                setLocationSimulationStatus(LOCATION_SIMULATION_STATUS.STOPPED)
                console.error(e)
                handleSnackbarOpen('位置模拟失败，请重试', 'error')
            })
    }

    function restoreLocation() {
        setLocationSimulationStatus(LOCATION_SIMULATION_STATUS.STOPPED)
        window.electronAPI
            .mockLocation(null, null)
            .then(res => {
                setLocationSimulationStatus(LOCATION_SIMULATION_STATUS.STOPPED)
                handleSnackbarOpen('已重置定位', 'success')
            })
            .catch(e => {
                setLocationSimulationStatus(LOCATION_SIMULATION_STATUS.STOPPED)
                console.error(e)
                handleSnackbarOpen('重置定位失败，请重试', 'error')
            })
    }

    // handle IPC messages
    let devicesCache = ''
    useEffect(() => {
        window.electronAPI.onDeviceListUpdate(devices => {
            if (devices === devicesCache) {
                return
            }
            devicesCache = devices
            const usbDevices = JSON.parse(devices).filter(device => device.ConnectionType === 'USB')
            if (usbDevices.length > 0) {
                setPhoneConnectionStatus(PHONE_CONNECTION_STATUS.CABLE_CONNECTED)
                setDeviceName(usbDevices[0].DeviceName)
                isDeveloperModeEnabled()
            } else {
                setPhoneConnectionStatus(PHONE_CONNECTION_STATUS.DISCONNECTED)
                setDeviceName('')
            }
        })
    }, [])

    // get button text
    let buttonText = ''
    let buttonDisabled = false
    let handleClick = () => {}
    switch (phoneConnectionStatus) {
        case PHONE_CONNECTION_STATUS.DISCONNECTED:
            buttonText = '连接设备'
            handleClick = handleOpenConnectionTips
            break
        case PHONE_CONNECTION_STATUS.CABLE_CONNECTED:
            buttonText = '模拟位置'
            buttonDisabled = true
            break
        case PHONE_CONNECTION_STATUS.CONNECTED_DEVELOPER_MODE_OFF:
            handleClick = handleOpenDevTips
            buttonText = '开发者模式'
            break
        case PHONE_CONNECTION_STATUS.CONNECTED_DEVELOPER_MODE_ON:
            switch (locationSimulationStatus) {
                case LOCATION_SIMULATION_STATUS.STOPPED:
                    buttonText = '模拟位置'
                    handleClick = mockLocation
                    break
                case LOCATION_SIMULATION_STATUS.LOADING:
                    buttonText = '加载中...'
                    buttonDisabled = true
                    break
                case LOCATION_SIMULATION_STATUS.COMPLETED:
                    buttonText = '还原位置'
                    handleClick = restoreLocation
                    break
            }
            break
        default:
            break
    }
    return (
        <>
            <div className="float-toolbox">
                <p>{deviceName ? `已连接 ${deviceName}` : '等待 USB 设备连接'}</p>
                <p className="info">经度: {longitude === '-' ? '-' : Math.round(longitude * 10e4) / 10e4}</p>
                <p className="info">纬度: {latitude === '-' ? '-' : Math.round(latitude * 10e4) / 10e4}</p>
                <button onClick={handleClick} disabled={buttonDisabled}>
                    {buttonText}
                </button>
            </div>
            <Dialog open={openConnectionTips} onClose={handleCloseConnectionTips}>
                <DialogTitle id="alert-dialog-title">设备连接指南</DialogTitle>
                <DialogContent>
                    <DialogContentText id="alert-dialog-description">
                        <div style={{ display: 'flex' }}>
                            <div>
                                <p>如图所示，将您的 iPhone 通过 USB 线连接到电脑上。在手机上点击“信任”按钮。</p>
                                <p className="info">
                                    如果您的手机没有显示“信任”按钮， 或者您之前已经点击了“不信任”， 请尝试拔出 USB
                                    数据线并重新连接手机。
                                </p>{' '}
                                <p className="info">
                                    如果您的手机没有显示“信任”按钮， 或者您之前已经点击了“不信任”， 请尝试拔出 USB
                                    数据线并重新连接手机。
                                </p>
                            </div>
                            <img src={trustComputer} alt="Trust Computer" width={200} />
                        </div>
                    </DialogContentText>
                </DialogContent>
            </Dialog>
            <Dialog open={openDevTips} onClose={handleCloseDevTips}>
                <DialogTitle id="alert-dialog-title">启动开发者模式</DialogTitle>
                <DialogContent>
                    <DialogContentText id="alert-dialog-description">
                        <div style={{ display: 'flex', gap: '4px' }}>
                            <div>
                                <p>开发者模式是一种允许您在手机上调试应用程序的模式，是开启位置模拟功能的必要条件。</p>
                                <p>1. 打开设置，找到“隐私与安全性”</p>
                                <p>2. 滑动到页面的最下方，打开“开发者模式”</p>
                                <p>3. 重启手机进入开发者模式</p>
                            </div>
                            <img src={enableDevMode} alt="Enable dev mode" width={200} />
                        </div>
                    </DialogContentText>
                </DialogContent>
            </Dialog>
            <Snackbar
                open={snackbarOpen}
                autoHideDuration={3000}
                onClose={handleSnackbarClose}
                anchorOrigin={{
                    vertical: 'top',
                    horizontal: 'center',
                }}
            >
                <Alert
                    onClose={handleSnackbarClose}
                    severity={snackbarSeverity}
                    variant="filled"
                    sx={{ width: '100%' }}
                >
                    {snackbarMessage}
                </Alert>
            </Snackbar>
        </>
    )
}
