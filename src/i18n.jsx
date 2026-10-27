import React, { createContext, useContext, useEffect, useState } from 'react'

const english = {
    "请输入有效坐标：经度 -180～180，纬度 -90～90。": "Enter valid coordinates: longitude −180 to 180, latitude −90 to 90.",
    "开发者模式已启用，请在手机上确认并重启设备": "Developer Mode enabled. Confirm on your phone and restart it.",
    "启用开发者模式失败，请在设置中手动开启": "Could not enable Developer Mode. Enable it manually in Settings.",
    "请先在地图上选择位置或手动输入经纬度": "Select a location on the map or enter coordinates first.",
    "位置设置成功，断开连接/重启后自动恢复": "Location set. Disconnect or restart to restore your location.",
    "位置模拟失败，请重试": "Could not simulate location. Please try again.",
    "连接设备": "Connect device",
    "模拟位置": "Simulate location",
    "信任设备": "Trust device",
    "开发者模式": "Developer Mode",
    "加载中...": "Loading...",
    "更新位置": "Update location",
    "请在手机上点击“信任”按钮": "Tap “Trust” on your phone",
    "已连接 {deviceName}": "Connected to {deviceName}",
    "等待 USB 设备连接": "Waiting for a USB device",
    "经度": "Longitude",
    "纬度": "Latitude",
    "经": "Lon",
    "纬": "Lat",
    "编辑经纬度": "Edit coordinates",
    "手动输入经纬度": "Enter coordinates",
    "输入十进制度坐标，确认后可点击“模拟位置”或“更新位置”。": "Enter decimal degrees, then select “Simulate location” or “Update location”.",
    "-180～180，东经为正，西经为负": "−180 to 180; east is positive, west is negative",
    "-90～90，北纬为正，南纬为负": "−90 to 90; north is positive, south is negative",
    "取消": "Cancel",
    "确认位置": "Confirm location",
    "设备连接指南": "Connect your device",
    "如图所示，将您的 iPhone 通过 USB 线连接到电脑上。在手机上点击“信任”按钮。": "Connect your iPhone to your computer with a USB cable, then tap “Trust” on your phone.",
    "如果您的手机没有显示“信任”按钮，或者您之前已经点击了“不信任”，请尝试拔出 USB 数据线并重新连接手机。": "If “Trust” does not appear, or you previously tapped “Don’t Trust”, unplug the USB cable and reconnect your phone.",
    "启动开发者模式": "Enable Developer Mode",
    "开发者模式是一种允许您在手机上调试应用程序的模式，是开启位置模拟功能的必要条件。": "Developer Mode allows app debugging on your phone and is required for location simulation.",
    "1. 打开设置，搜索“开发者模式”并启用（或者设置 → 隐私与安全性 → 开发者模式）": "1. Open Settings → Privacy & Security → Developer Mode and enable it.",
    "2. 重启手机进入开发者模式": "2. Restart your phone to enter Developer Mode.",
    "选择地图源": "Choose a map",
    "位置信息更丰富": "Detailed location information",
    "高德地图": "AMap",
    "适合中国大陆": "Recommended for mainland China",
    "回到当前位置": "Go to current location",
    "切换到英文": "Switch to Chinese",
    "信任电脑示意图": "Trust This Computer instructions",
    "启用开发者模式示意图": "Developer Mode instructions",
    "地图图层": "Map layers",
    "Parachute – 虚拟定位": "Parachute – Virtual Location"
}

const LanguageContext = createContext(null)
const storageKey = 'parachute.language'

export function getInitialLanguage() {
    try {
        const saved = localStorage.getItem(storageKey)
        if (saved === 'zh' || saved === 'en') return saved
    } catch { /* Use the system language when storage is unavailable. */ }
    return /^zh(?:-|$)/i.test(navigator.language || '') ? 'zh' : 'en'
}

export function LanguageProvider({ children }) {
    const [language, setLanguage] = useState(getInitialLanguage)
    const t = (message, values = {}) => {
        const translated = language === 'en' ? (english[message] || message) : message
        return translated.replace(/\{(\w+)\}/g, (match, key) => values[key] ?? match)
    }

    useEffect(() => {
        document.documentElement.lang = language === 'zh' ? 'zh-CN' : 'en'
        document.title = language === 'zh' ? 'Parachute – 虚拟定位' : 'Parachute – Virtual Location'
    }, [language])

    const toggleLanguage = () => {
        const next = language === 'zh' ? 'en' : 'zh'
        setLanguage(next)
        try { localStorage.setItem(storageKey, next) } catch { /* Switching still works without storage. */ }
    }

    return <LanguageContext.Provider value={{ language, toggleLanguage, t }}>{children}</LanguageContext.Provider>
}

export const useLanguage = () => useContext(LanguageContext)

export function LanguageButton() {
    const { toggleLanguage, t } = useLanguage()
    return (
        <button className="language-btn" type="button" onClick={toggleLanguage} title={t('切换到英文')} aria-label={t('切换到英文')}>
            <span lang="zh">文</span><span className="language-divider">/</span><span lang="en">A</span>
        </button>
    )
}
