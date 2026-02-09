## Overview

This repository provides a production-ready **Docker Compose homelab stack** plus an **`install.sh`** bootstrap script that prepares the host and deploys everything in one command.  
All services share a single Docker network for easy inter-service communication, while all persistent data lives under **`/home/homelab_data`** and the compose/config lives under **`/home/homelab`**.  
The installer supports **Ubuntu/Debian (apt)** and **Alpine (apk)** and is designed to be repeatable and safe to re-run.

## Features

- **One-command deploy:** `sudo ./install.sh`
- **Ports mapped to:** `8060–8069`
- **Persistent storage under:** `/home/homelab_data`
- **Works on:** Ubuntu/Debian + Alpine
- **Services included:** Filebrowser, BentoPDF, IT-Tools, FreshRSS, Immich, Joplin, Paperless-ngx, n8n, OnlyOffice
