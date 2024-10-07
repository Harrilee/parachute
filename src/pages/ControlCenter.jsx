import React from 'react'

export default function ControlCenter(props) {
    const { longitude, latitude } = props
    return (
        <div className="float-toolbox">
            <p>已连接 Harry's iPhone 18 Pro Max</p>
            <p className="info">经度: {longitude}</p>
            <p className="info">维度: {latitude}</p>
            <button>降落</button>
        </div>
    )
}
