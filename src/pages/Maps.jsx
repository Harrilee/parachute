import * as React from 'react'
import { useEffect, useState } from 'react'
import AMapLoader from '@amap/amap-jsapi-loader'

export default function Maps(props) {
    const { setLatitude, setLongitude } = props
    let marker = null
    useEffect(() => {
        window._AMapSecurityConfig = {
            securityJsCode: 'faf5f3851ee68c2b113279a6d9dcc9ee',
        }
        AMapLoader.load({
            key: '1628def42dc9e4415cfba3138e370e59', // 申请好的Web端开发者Key，首次调用 load 时必填
            version: '2.0', // 指定要加载的 JSAPI 的版本，缺省时默认为 1.4.15
            plugins: ['AMap.Scale', 'AMap.PlaceSearch'], //需要使用的的插件列表，如比例尺'AMap.Scale'，支持添加多个如：['...','...']
        })
            .then(AMap => {
                window.map = new AMap.Map('map-container', {
                    viewMode: '2D',
                    zoom: 7,
                    center: [116.3975, 39.9087], //初始化地图中心点位置
                    mapStyle: 'amap://styles/grey', //设置地图的显示样式
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
