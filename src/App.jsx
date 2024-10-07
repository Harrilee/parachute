import React, { useState } from 'react'
import { createRoot } from 'react-dom/client'
import Maps from './pages/Maps.jsx'
import ControlCenter from './pages/ControlCenter.jsx'
import _ from './app.css'
import { PHONE_CONNECTION_STATUS, LOCATION_SIMULATION_STATUS } from './utils.js'

const root = createRoot(document.getElementById('root'))

const App = () => {
    const [longitude, setLongitude] = useState(116.3975)
    const [latitude, setLatitude] = useState(39.9087)
    const [phoneConnectionStatus, setPhoneConnectionStatus] = useState(PHONE_CONNECTION_STATUS.DISCONNECTED)
    const [locationSimulationStatus, setLocationSimulationStatus] = useState(LOCATION_SIMULATION_STATUS.STOPPED)

    return (
        <>
            <Maps setLatitude={setLatitude} setLongitude={setLongitude} />
            <ControlCenter longitude={longitude} latitude={latitude} />
        </>
    )
}
root.render(<App />)
