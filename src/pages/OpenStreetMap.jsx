import * as React from 'react'
import { useEffect, useState } from 'react'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'

export default function Maps(props) {
    const { setLatitude, setLongitude, setMapLoaded } = props
    let marker = null
    useEffect(() => {
        const map = L.map('map-container', {
            zoomControl: false,
            attributionControl: false,
            wheelPxPerZoomLevel: 30,
        }).setView([37.3346, -122.009], 15)
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

            // Add or move the marker
            if (marker) {
                marker.setLatLng([lat, lng])
            } else {
                marker = L.marker([lat, lng]).addTo(map)
            }
        })
    }, [])
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
