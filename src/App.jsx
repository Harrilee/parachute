import { LanguageProvider, LanguageButton } from './i18n.jsx'
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
                <LanguageButton />
                {map === '高德地图' && (
                    <AMap longitude={longitude} latitude={latitude} setLongitude={setLongitude} setLatitude={setLatitude} setMapLoaded={setMapLoaded} />
                )}
                {map === 'Open Street Map' && (
                    <OpenStreetMap longitude={longitude} latitude={latitude} setLongitude={setLongitude} setLatitude={setLatitude} setMapLoaded={setMapLoaded} />
                )}
                {mapLoaded && (
                    <>
                        <ControlCenter
                            setLongitude={setLongitude}
                            setLatitude={setLatitude}
                            longitude={longitude}
                            latitude={latitude}
                            phoneConnectionStatus={phoneConnectionStatus}
                            setPhoneConnectionStatus={setPhoneConnectionStatus}
                            locationSimulationStatus={locationSimulationStatus}
                            setLocationSimulationStatus={setLocationSimulationStatus}
                        />
                        <MapSource map={map} setMap={setMap} />
                    </>
                )}
            </ThemeProvider>
        </>
    )
}
root.render(<LanguageProvider><App /></LanguageProvider>)
