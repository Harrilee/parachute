import React, { useState } from 'react'
import { createRoot } from 'react-dom/client'
import AMap from './pages/AMap.jsx'
import OpenStreetMap from './pages/OpenStreetMap.jsx'
import ControlCenter from './pages/ControlCenter.jsx'
import { ThemeProvider, createTheme } from '@mui/material/styles'
import CssBaseline from '@mui/material/CssBaseline'
import MapSource from './pages/MapSource.jsx'
const darkTheme = createTheme({
    palette: {
        mode: 'light',
    },
})
import './app.css'
import { PHONE_CONNECTION_STATUS, LOCATION_SIMULATION_STATUS } from './utils.js'

const root = createRoot(document.getElementById('root'))

const LocateButton = ({ map }) => {
    const [locating, setLocating] = useState(false)

    const centerMap = (latitude, longitude, source) => {
        console.log(`[Locate] Centering map (${source}): lat=${latitude}, lon=${longitude}, map=${map}`)
        if (map === '高德地图' && window.map) {
            window.map.setCenter([longitude, latitude])
            window.map.setZoom(15)
            console.log('[Locate] AMap centered')
        } else if (window.leafletMap) {
            window.leafletMap.setView([latitude, longitude], 15)
            console.log('[Locate] Leaflet centered')
        } else {
            console.warn('[Locate] No map instance found')
        }
        setLocating(false)
    }

    const handleLocate = () => {
        console.log('[Locate] Button clicked')
        setLocating(true)
        let resolved = false

        const ipPromise = fetch('https://get.geojs.io/v1/ip/geo.json')
            .then(r => r.json())
            .then(data => ({ latitude: Number(data.latitude), longitude: Number(data.longitude), source: 'IP' }))
            .catch(err => { console.error('[Locate] IP geolocation failed:', err); return null })

        if (navigator.geolocation) {
            console.log('[Locate] navigator.geolocation available, requesting position...')
            navigator.geolocation.getCurrentPosition(
                pos => {
                    resolved = true
                    console.log(`[Locate] GPS success: lat=${pos.coords.latitude}, lon=${pos.coords.longitude}, accuracy=${pos.coords.accuracy}m`)
                    centerMap(pos.coords.latitude, pos.coords.longitude, 'GPS')
                },
                async err => {
                    console.warn(`[Locate] Geolocation denied/failed: code=${err.code}, message=${err.message}`)
                    if (resolved) return
                    const result = await ipPromise
                    if (!resolved && result) {
                        resolved = true
                        console.log('[Locate] Using pre-fetched IP location')
                        centerMap(result.latitude, result.longitude, 'IP')
                    } else {
                        setLocating(false)
                    }
                },
                { enableHighAccuracy: true, timeout: 5000 },
            )
        } else {
            console.warn('[Locate] navigator.geolocation not available')
            ipPromise.then(result => {
                if (result) centerMap(result.latitude, result.longitude, 'IP')
                else setLocating(false)
            })
        }
    }

    return (
        <button className="locate-btn" onClick={handleLocate} disabled={locating} title="回到当前位置">
            {locating ? (
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" style={{ animation: 'spin 1s linear infinite' }}>
                    <circle cx="12" cy="12" r="10" strokeDasharray="32" strokeDashoffset="12" />
                </svg>
            ) : (
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                    <circle cx="12" cy="12" r="4" />
                    <line x1="12" y1="2" x2="12" y2="6" />
                    <line x1="12" y1="18" x2="12" y2="22" />
                    <line x1="2" y1="12" x2="6" y2="12" />
                    <line x1="18" y1="12" x2="22" y2="12" />
                </svg>
            )}
        </button>
    )
}

const App = () => {
    const [longitude, setLongitude] = useState('-')
    const [latitude, setLatitude] = useState('-')
    const [mapLoaded, setMapLoaded] = useState(false)
    const [phoneConnectionStatus, setPhoneConnectionStatus] = useState(PHONE_CONNECTION_STATUS.DISCONNECTED)
    const [locationSimulationStatus, setLocationSimulationStatus] = useState(LOCATION_SIMULATION_STATUS.STOPPED)
    const [map, setMap] = useState('Open Street Map')

    return (
        <>
            <ThemeProvider theme={darkTheme}>
                <CssBaseline />
                {map === '高德地图' && (
                    <AMap setLongitude={setLongitude} setLatitude={setLatitude} setMapLoaded={setMapLoaded} />
                )}
                {map === 'Open Street Map' && (
                    <OpenStreetMap setLongitude={setLongitude} setLatitude={setLatitude} setMapLoaded={setMapLoaded} />
                )}
                {mapLoaded && (
                    <>
                        <ControlCenter
                            longitude={longitude}
                            latitude={latitude}
                            phoneConnectionStatus={phoneConnectionStatus}
                            setPhoneConnectionStatus={setPhoneConnectionStatus}
                            locationSimulationStatus={locationSimulationStatus}
                            setLocationSimulationStatus={setLocationSimulationStatus}
                        />
                        <MapSource map={map} setMap={setMap} />
                        <LocateButton map={map} />
                    </>
                )}
            </ThemeProvider>
        </>
    )
}
root.render(<App />)
