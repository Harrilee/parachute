import React, { useState } from 'react'
import layerBlack from '../images/layer-black.png'
import amapLogo from '../images/amap.png'
import openStreetMapLogo from '../images/openstreetmap.png'

import Dialog from '@mui/material/Dialog'
import DialogContent from '@mui/material/DialogContent'
import DialogContentText from '@mui/material/DialogContentText'
import DialogTitle from '@mui/material/DialogTitle'


export default function MapSource(props) {
    const {map, setMap} = props
    const [open, setOpen] = useState(false)
    const handleOpen = () => setOpen(true)
    const handleClose = () => setOpen(false)

    return (
        <div className="map-source float-toolbox">
            <div className="title" onClick={handleOpen}>
                <img src={layerBlack} alt="layer" width={20} height={20} />
                <div className="layer-text">{map}</div>
            </div>
            <Dialog open={open} onClose={handleClose}>
                <DialogTitle id="alert-dialog-title">选择地图源</DialogTitle>
                <DialogContent>
                    <DialogContentText id="alert-dialog-description">
                        <div className="map-source-list">
                            <div
                                className="map-source-item"
                                onClick={() => {
                                    setMap('Open Street Map')
                                    handleClose()
                                }}
                            >
                                <img src={openStreetMapLogo} alt="Open Street Map" width={128} height={128} />
                                <div className="map-source-text">
                                    <span>Open Street Map</span>
                                    <span className="description">位置信息更丰富</span>
                                </div>
                            </div>
                            <div
                                className="map-source-item"
                                onClick={() => {
                                    setMap('高德地图')
                                    handleClose()
                                }}
                            >
                                <img src={amapLogo} alt="高德地图" width={128} height={128} />
                                <div className="map-source-text">
                                    <span>高德地图</span>
                                    <span className="description">适合中国大陆</span>
                                </div>
                            </div>
                        </div>
                    </DialogContentText>
                </DialogContent>
            </Dialog>
        </div>
    )
}