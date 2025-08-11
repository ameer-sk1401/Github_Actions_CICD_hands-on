#!/bin/bash
sudo systemctl stop myapp || true
rm -rf /opt/myapp/src
mkdir -p /opt/myapp/src
