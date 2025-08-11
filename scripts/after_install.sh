#!/usr/bin/env bash
set -e

# Install Python dependencies
yum install -y python3-pip || true
python3 -m venv /opt/myapp/venv || true
source /opt/myapp/venv/bin/activate
pip install --upgrade pip
pip install -r /opt/myapp/src/requirements.txt

# Create a systemd service for the Flask app
cat >/etc/systemd/system/myapp.service <<'UNIT'
[Unit]
Description=Flask App
After=network.target

[Service]
User=ec2-user
WorkingDirectory=/opt/myapp/src
ExecStart=/bin/bash -lc '/opt/myapp/venv/bin/gunicorn -w 2 -b 0.0.0.0:8000 app:app'
Restart=always

[Install]
WantedBy=multi-user.target
UNIT

# Reload systemd to pick up the new service
systemctl daemon-reload