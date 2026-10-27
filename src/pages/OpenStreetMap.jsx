import React, { useEffect, useRef } from 'react'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'

export default function Maps(props) {
    const { latitude, longitude, setLatitude, setLongitude, setMapLoaded } = props
    const mapRef = useRef(null)
    const markerRef = useRef(null)
    useEffect(() => {
        const map = L.map('map-container', {
            zoomControl: false,
            attributionControl: false,
            wheelPxPerZoomLevel: 30,
        }).setView([37.3346, -122.009], 15)
        mapRef.current = map
        window.leafletMap = map
        L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
            attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
        }).addTo(map)

        // Notify that the map has loaded

        setMapLoaded(true)

        // Add a click event to update latitude and longitude
        map.on('click', (e) => {
            const { lat, lng } = e.latlng
            if (setLatitude) setLatitude(lat)
            if (setLongitude) setLongitude(lng)

        })
        return () => {
            map.remove()
            mapRef.current = null
            markerRef.current = null
            if (window.leafletMap === map) delete window.leafletMap
        }
    }, [setLatitude, setLongitude, setMapLoaded])

    useEffect(() => {
        const map = mapRef.current
        if (!map || !Number.isFinite(latitude) || !Number.isFinite(longitude)) return
        if (markerRef.current) {
            markerRef.current.setLatLng([latitude, longitude])
        } else {
            markerRef.current = L.marker([latitude, longitude]).addTo(map)
        }
        map.panTo([latitude, longitude])
    }, [latitude, longitude])
    return (
        <>
            <link
                rel="stylesheet"
                href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"
                integrity="sha256-p4NxAoJBhIIN+hmNHrzRCf9tD/miZyoHS5obTRR9BMY="
                crossOrigin=""
            />
            <div id="map-container"></div>
        </>
    )
}
