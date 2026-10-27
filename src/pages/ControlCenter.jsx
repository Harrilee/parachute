import React, { useEffect, useRef, useState } from 'react'

import { PHONE_CONNECTION_STATUS, LOCATION_SIMULATION_STATUS } from '../utils.js'

import Dialog from '@mui/material/Dialog'
import DialogContent from '@mui/material/DialogContent'
import DialogContentText from '@mui/material/DialogContentText'
import DialogTitle from '@mui/material/DialogTitle'
import DialogActions from '@mui/material/DialogActions'
import TextField from '@mui/material/TextField'
import Button from '@mui/material/Button'

import Snackbar from '@mui/material/Snackbar'
import Alert from '@mui/material/Alert'

import trustComputer from '../images/trust-computer.png'
import enableDevMode from '../images/enable-devmode.png'

export default function ControlCenter(props) {
    const {
        setLongitude,
        setLatitude,
        longitude,
        latitude,
        phoneConnectionStatus,
        setPhoneConnectionStatus,
        locationSimulationStatus,
        setLocationSimulationStatus,
    } = props

    const [deviceName, setDeviceName] = useState()

    const [coordinateDialogOpen, setCoordinateDialogOpen] = useState(false)
    const [longitudeInput, setLongitudeInput] = useState('')
    const [latitudeInput, setLatitudeInput] = useState('')
    const [coordinateError, setCoordinateError] = useState('')

    function openCoordinateDialog() {
        setLongitudeInput(longitude === '-' ? '' : String(longitude))
        setLatitudeInput(latitude === '-' ? '' : String(latitude))
        setCoordinateError('')
        setCoordinateDialogOpen(true)
    }

    function applyCoordinates(event) {
        event.preventDefault()
        const lng = Number(longitudeInput)
        const lat = Number(latitudeInput)
        if (!longitudeInput.trim() || !latitudeInput.trim() ||
            !Number.isFinite(lng) || !Number.isFinite(lat) ||
            lng < -180 || lng > 180 || lat < -90 || lat > 90) {
            setCoordinateError('请输入有效坐标：经度 -180～180，纬度 -90～90。')
            return
        }
        setLongitude(lng)
        setLatitude(lat)
        setCoordinateDialogOpen(false)
    }

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
        devModeChecked.current = false
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

    function isDeveloperModeEnabled() {
        window.electronAPI.isDeveloperModeEnabled().then(status => {
            if (status === 'true') {
                setPhoneConnectionStatus(PHONE_CONNECTION_STATUS.CONNECTED_DEVELOPER_MODE_ON)
            } else if (status === 'false') {
                setPhoneConnectionStatus(PHONE_CONNECTION_STATUS.CONNECTED_DEVELOPER_MODE_OFF)
            } else if (status === 'unpaired') {
                setPhoneConnectionStatus(PHONE_CONNECTION_STATUS.CONNECTED_UNTRUSTED)
            } else {
                setPhoneConnectionStatus(PHONE_CONNECTION_STATUS.CABLE_CONNECTED)
            }
        })
    }

    function enableDeveloperMode() {
        handleOpenDevTips()
        window.electronAPI.enableDeveloperMode()
            .then(() => {
                handleSnackbarOpen('开发者模式已启用，请在手机上确认并重启设备', 'success')
                devModeChecked.current = false
                isDeveloperModeEnabled()
            })
            .catch(e => {
                console.error(e)
                handleSnackbarOpen('启用开发者模式失败，请在设置中手动开启', 'warning')
            })
    }

    function mockLocation() {
        console.log(latitude, longitude)
        if (latitude === '-' || longitude === '-') {
            handleSnackbarOpen('请先在地图上选择位置或手动输入经纬度', 'error')
            return
        }
        setLocationSimulationStatus(LOCATION_SIMULATION_STATUS.LOADING)
        window.electronAPI
            .mockLocation(latitude, longitude)
            .then(() => {
                setLocationSimulationStatus(LOCATION_SIMULATION_STATUS.COMPLETED)
                handleSnackbarOpen('位置设置成功，断开连接/重启后自动恢复', 'success')
            })
            .catch(e => {
                setLocationSimulationStatus(LOCATION_SIMULATION_STATUS.STOPPED)
                console.error(e)
                handleSnackbarOpen('位置模拟失败，请重试', 'error')
            })
    }

    const lastDeviceUdid = useRef(null)
    const devModeChecked = useRef(false)

    useEffect(() => {
        const handler = devices => {
            const usbDevices = JSON.parse(devices).filter(device => device.ConnectionType === 'USB')
            if (usbDevices.length > 0) {
                const device = usbDevices[0]
                const udid = device.Udid || device.udid || ''
                setDeviceName(device.DeviceName || 'iOS Device')

                if (device.PairingStatus === 'unpaired') {
                    setLocationSimulationStatus(LOCATION_SIMULATION_STATUS.STOPPED)
                    setPhoneConnectionStatus(PHONE_CONNECTION_STATUS.CONNECTED_UNTRUSTED)
                    devModeChecked.current = false
                    lastDeviceUdid.current = udid
                } else if (udid !== lastDeviceUdid.current || !devModeChecked.current) {
                    lastDeviceUdid.current = udid
                    devModeChecked.current = true
                    isDeveloperModeEnabled()
                }
            } else {
                setLocationSimulationStatus(LOCATION_SIMULATION_STATUS.STOPPED)
                setPhoneConnectionStatus(PHONE_CONNECTION_STATUS.DISCONNECTED)
                setDeviceName('')
                devModeChecked.current = false
                lastDeviceUdid.current = null
            }
        }
        window.electronAPI.onDeviceListUpdate(handler)
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
        case PHONE_CONNECTION_STATUS.CONNECTED_UNTRUSTED:
            buttonText = '信任设备'
            handleClick = handleOpenConnectionTips
            break
        case PHONE_CONNECTION_STATUS.CONNECTED_DEVELOPER_MODE_OFF:
            handleClick = enableDeveloperMode
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
                    buttonText = '更新位置'
                    handleClick = mockLocation
                    break
            }
            break
        default:
            break
    }
    return (
        <>
            <div className="float-toolbox">
                <p>
                    {deviceName
                        ? phoneConnectionStatus === PHONE_CONNECTION_STATUS.CONNECTED_UNTRUSTED
                            ? `请在手机上点击“信任”按钮`
                            : `已连接 ${deviceName}`
                        : '等待 USB 设备连接'}
                </p>
                <p className="info">经度: {longitude === '-' ? '-' : Math.round(longitude * 10e4) / 10e4}</p>
                <p className="info">纬度: {latitude === '-' ? '-' : Math.round(latitude * 10e4) / 10e4}</p>
                <button onClick={openCoordinateDialog}>手动输入经纬度</button>
                <button onClick={handleClick} disabled={buttonDisabled}>
                    {buttonText}
                </button>
            </div>
            <Dialog open={coordinateDialogOpen} onClose={() => setCoordinateDialogOpen(false)} fullWidth maxWidth="xs">
                <form onSubmit={applyCoordinates} noValidate>
                    <DialogTitle>手动输入经纬度</DialogTitle>
                    <DialogContent>
                        <DialogContentText>输入十进制度坐标，确认后可点击“模拟位置”或“更新位置”。</DialogContentText>
                        <TextField
                            autoFocus fullWidth margin="normal" label="经度" type="number"
                            value={longitudeInput} onChange={event => setLongitudeInput(event.target.value)}
                            inputProps={{ min: -180, max: 180, step: 'any' }}
                            helperText="-180～180，东经为正，西经为负"
                        />
                        <TextField
                            fullWidth margin="normal" label="纬度" type="number"
                            value={latitudeInput} onChange={event => setLatitudeInput(event.target.value)}
                            inputProps={{ min: -90, max: 90, step: 'any' }}
                            helperText="-90～90，北纬为正，南纬为负"
                        />
                        {coordinateError && <Alert severity="error">{coordinateError}</Alert>}
                    </DialogContent>
                    <DialogActions>
                        <Button onClick={() => setCoordinateDialogOpen(false)}>取消</Button>
                        <Button type="submit">确认位置</Button>
                    </DialogActions>
                </form>
            </Dialog>
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
                                <p>1. 打开设置，搜索“开发者模式”并启用（或者设置 -&gt; 隐私与安全性 -&gt; 开发者模式）</p>
                                <p>2. 重启手机进入开发者模式</p>
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
