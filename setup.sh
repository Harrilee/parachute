#!/bin/sh

# Install dependencies
npm install

# Create Python virtual environment
cd src
python3 -m venv venv
source venv/bin/activate
python3 -m pip install -U pymobiledevice3