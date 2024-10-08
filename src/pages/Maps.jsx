import * as React from 'react'
import { useEffect, useState } from 'react'
import AMapLoader from '@amap/amap-jsapi-loader'

export default function Maps(props) {
    const { setLatitude, setLongitude, setMapLoaded } = props
    let marker = null
    useEffect(() => {
        window._AMapSecurityConfig = {
            securityJsCode: 'faf5f3851ee68c2b113279a6d9dcc9ee',
        }
        AMapLoader.load({
            key: '1628def42dc9e4415cfba3138e370e59',
            version: '2.0',
        })
            .then(AMap => {
                window.map = new AMap.Map('map-container', {
                    viewMode: '2D',
                    zoom: 7,
                    center: [116.3975, 39.9087],
                })

                window.map.on('complete', () => {
                    setMapLoaded(true)
                })

                window.map.on('click', function (ev) {
                    const { lng, lat } = ev.lnglat
                    setLatitude(lat)
                    setLongitude(lng)
                    if (marker) {
                        marker.setMap(null)
                    }
                    marker = new AMap.Marker({
                        position: [lng, lat],
                        title: 'Your Location',
                    })
                    marker.setMap(window.map)
                })
            })
            .catch(e => {
                console.error(e)
            })
    }, [])
    return (
        <>
            <div id="map-container"></div>
        </>
    )
}
