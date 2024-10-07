import React, { useEffect, useState } from 'react'

import { PHONE_CONNECTION_STATUS } from '../utils.js'

import Dialog from '@mui/material/Dialog'
import DialogContent from '@mui/material/DialogContent'
import DialogContentText from '@mui/material/DialogContentText'
import DialogTitle from '@mui/material/DialogTitle'

import trustComputer from '../images/trust-computer.png'
import enableDevMode from '../images/enable-devmode.png'

export default function ControlCenter(props) {
    const { longitude, latitude, phoneConnectionStatus, setPhoneConnectionStatus } = props

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
            buttonText = '模拟位置'
            handleClick = () => alert('Not implemented')
            break
        default:
            break
    }
    return (
        <>
            <div className="float-toolbox">
                <p>{deviceName ? `已连接 ${deviceName}` : '等待 USB 设备连接'}</p>
                <p className="info">经度: {longitude}</p>
                <p className="info">维度: {latitude}</p>
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
        </>
    )
}
