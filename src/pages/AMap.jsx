import React, { useEffect, useRef, useState } from 'react'
import AMapLoader from '@amap/amap-jsapi-loader'

export default function Maps(props) {
    const { latitude, longitude, setLatitude, setLongitude, setMapLoaded } = props
    const mapRef = useRef(null)
    const markerRef = useRef(null)
    const [api, setApi] = useState(null)
    useEffect(() => {
        let disposed = false
        window._AMapSecurityConfig = {
            securityJsCode: 'faf5f3851ee68c2b113279a6d9dcc9ee',
        }
        AMapLoader.load({
            key: '1628def42dc9e4415cfba3138e370e59',
            version: '2.0',
        })
            .then(AMap => {
                if (disposed) return
                window.map = new AMap.Map('map-container', {
                    viewMode: '2D',
                    zoom: 7,
                    center: [116.3975, 39.9087],
                })

                mapRef.current = window.map
                setApi(AMap)

                window.map.on('complete', () => {
                    setMapLoaded(true)
                })

                window.map.on('click', function (ev) {
                    const { lng, lat } = ev.lnglat
                    setLatitude(lat)
                    setLongitude(lng)
                })
            })
            .catch(e => {
                console.error(e)
            })
        return () => {
            disposed = true
            if (mapRef.current) {
                mapRef.current.destroy()
                if (window.map === mapRef.current) delete window.map
                mapRef.current = null
                markerRef.current = null
            }
        }
    }, [setLatitude, setLongitude, setMapLoaded])

    useEffect(() => {
        const map = mapRef.current
        if (!api || !map || !Number.isFinite(latitude) || !Number.isFinite(longitude)) return
        if (markerRef.current) {
            markerRef.current.setPosition([longitude, latitude])
        } else {
            markerRef.current = new api.Marker({ position: [longitude, latitude], title: 'Your Location' })
            markerRef.current.setMap(map)
        }
        map.setCenter([longitude, latitude])
    }, [api, latitude, longitude])
    return (
        <>
            <div id="map-container"></div>
        </>
    )
}
