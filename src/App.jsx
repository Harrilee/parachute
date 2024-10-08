import React, { useState } from 'react'
import { createRoot } from 'react-dom/client'
import Maps from './pages/Maps.jsx'
import ControlCenter from './pages/ControlCenter.jsx'
import { ThemeProvider, createTheme } from '@mui/material/styles'
import CssBaseline from '@mui/material/CssBaseline'

const darkTheme = createTheme({
    palette: {
        mode: 'light',
    },
})
import _ from './app.css'
import { PHONE_CONNECTION_STATUS, LOCATION_SIMULATION_STATUS } from './utils.js'

const root = createRoot(document.getElementById('root'))

const App = () => {
    const [longitude, setLongitude] = useState('-')
    const [latitude, setLatitude] = useState('-')
    const [mapLoaded, setMapLoaded] = useState(false)
    const [phoneConnectionStatus, setPhoneConnectionStatus] = useState(PHONE_CONNECTION_STATUS.DISCONNECTED)
    const [locationSimulationStatus, setLocationSimulationStatus] = useState(LOCATION_SIMULATION_STATUS.STOPPED)

    return (
        <>
            <ThemeProvider theme={darkTheme}>
                <CssBaseline />
                <Maps setLatitude={setLatitude} setLongitude={setLongitude} setMapLoaded={setMapLoaded} />
                {mapLoaded && (
                    <ControlCenter
                        longitude={longitude}
                        latitude={latitude}
                        phoneConnectionStatus={phoneConnectionStatus}
                        setPhoneConnectionStatus={setPhoneConnectionStatus}
                        locationSimulationStatus={locationSimulationStatus}
                        setLocationSimulationStatus={setLocationSimulationStatus}
                    />
                )}
            </ThemeProvider>
        </>
    )
}
root.render(<App />)
