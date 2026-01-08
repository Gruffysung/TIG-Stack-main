[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/N4N41E59SA)

# TIG Stack - Monitoring System with Telegraf, InfluxDB, and Grafana
This repository provides a simple setup script to deploy a TIG Stack (Telegraf, InfluxDB, Grafana) using Docker and Docker Compose.

# What's Included
Telegraf – Metrics collection agent

InfluxDB – Time-series database

Grafana – Visualization and dashboard platform

Installation Script (tig-setup.sh) – Helps install the latest versions of Docker and Docker Compose automatically

The docker-compose.yml file will set up all necessary services and automatically generate the following environment files:

.env.influxdb-admin-username

.env.influxdb-admin-password

.env.influxdb-admin-token

These files store your InfluxDB admin credentials and token securely.

# How to use
chmod +x tig-setup.sh

./tig-setup.sh
