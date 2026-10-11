# Linux Application Failure Detection & Root Cause Analysis POC

[![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-orange?logo=ubuntu)](https://ubuntu.com/)
[![FastAPI](https://img.shields.io/badge/FastAPI-0.115.6-009688?logo=fastapi)](https://fastapi.tiangolo.com/)
[![systemd](https://img.shields.io/badge/systemd-Service%20Management-blue)](https://systemd.io/)
[![Nginx](https://img.shields.io/badge/Nginx-Reverse%20Proxy-green?logo=nginx)](https://nginx.org/)
[![License](https://img.shields.io/badge/License-MIT-brightgreen.svg)](LICENSE)

A beginner-friendly, production-grade DevOps Proof-of-Concept (POC) demonstrating how to identify root causes when an application fails on a Linux server, fix issues using standard Linux diagnostic tools, and verify recovery.

---

## 📑 Table of Contents
1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites & EC2 Setup](#2-prerequisites--ec2-setup)
3. [Repository Structure](#3-repository-structure)
4. [Phase 1: Application Setup & Baseline Testing](#phase-1-application-setup--baseline-testing)
5. [Phase 2: systemd Service Configuration](#phase-2-systemd-service-configuration)
6. [Phase 3: Failure Simulations & Root Cause Analysis (RCA)](#phase-3-failure-simulations--root-cause-analysis-rca)
   - [Scenario 1: Service Stopped Outage](#scenario-1-service-stopped-outage)
   - [Scenario 2: Port Misconfiguration Mismatch](#scenario-2-port-misconfiguration-mismatch)
   - [Scenario 3: Missing Python Dependency Crash Loop](#scenario-3-missing-python-dependency-crash-loop)
7. [Phase 4: Nginx Reverse Proxy & 502 Bad Gateway Simulation](#phase-4-nginx-reverse-proxy--502-bad-gateway-simulation)
8. [Phase 5: Automated Symptom Check Script](#phase-5-automated-symptom-check-script)
9. [Phase 6: Incident Documentation](#phase-6-incident-documentation)
10. [Troubleshooting Command Cheat Sheet](#troubleshooting-command-cheat-sheet)
11. [Git Publishing Guide](#git-publishing-guide)
12. [AWS Resource Cleanup (Cost Avoidance)](#aws-resource-cleanup-cost-avoidance)

---

## 1. Architecture Overview

In modern production environments, backend applications run behind an ingress web server or reverse proxy and are managed by an init system (`systemd`):

```
┌─────────────────────────────────────────────────────────────┐
│                       AWS EC2 Instance                      │
│                                                             │
│  [Public Internet]                                          │
│         │ Port 80 (HTTP)                                    │
│         ▼                                                   │
│   ┌───────────┐                                             │
│   │   Nginx   │ (Reverse Proxy)                             │
│   └─────┬─────┘                                             │
│         │ Internal Proxy Pass (127.0.0.1:8000)              │
│         ▼                                                   │
│   ┌───────────┐      Managed by      ┌───────────────┐      │
│   │  Uvicorn  │ ◄─────────────────── │ systemd Unit  │      │
│   │  FastAPI  │   (Auto-Restart)     │ myapp.service │      │
│   └───────────┘                      └───────────────┘      │
│     /, /health, /info                                       │
└─────────────────────────────────────────────────────────────┘
```

### Key Principles
- **Loopback Isolation:** The FastAPI ASGI server listens exclusively on `127.0.0.1:8000` (private to the instance). Port 8000 is never exposed to the public internet.
- **Process Supervision:** `systemd` acts as the process supervisor, managing auto-start on boot, logging via `journald`, and auto-recovery on failure.
- **Observability:** Linux diagnostic tools (`ss`, `ps`, `journalctl`, `curl`, `tail`) are used systematically to differentiate *observed symptoms* from the *true root cause*.

---

## 2. Prerequisites & EC2 Setup

1. **AWS EC2 Instance:**
   - **Type:** `t2.micro` or `t3.micro` (AWS Free Tier eligible)
   - **AMI:** Ubuntu 22.04 LTS or Ubuntu 24.04 LTS
   - **Storage:** Default 8 GB gp3 disk
2. **Security Group Inbound Rules:**
   - `Port 22 (SSH)`: Restricted to **My IP**
   - `Port 80 (HTTP)`: Source **0.0.0.0/0** (Needed for Phase 4 Nginx testing)
   - `Port 8000`: **Do NOT open port 8000** in the security group.

---

## 3. Repository Structure

```
linux-app-troubleshooting-poc/
├── app/
│   └── main.py              # FastAPI application with /, /health, /info
├── requirements.txt         # Pinned Python package dependencies
├── systemd/
│   └── myapp.service        # Production systemd unit configuration
├── nginx/
│   └── myapp.conf           # Nginx reverse proxy server block
├── scripts/
│   └── health_check.sh      # Bash symptom reporter script
├── docs/
│   └── incident-report.md   # Post-mortem incident analysis records
├── .gitignore               # Ignores venv, bytecode, logs
└── README.md                # Comprehensive documentation
```

---

## Phase 1: Application Setup & Baseline Testing

### 1. Update OS and Install System Packages
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y python3 python3-pip python3-venv git curl net-tools
```

### 2. Clone or Create Repository
```bash
mkdir -p ~/linux-app-troubleshooting-poc/app
cd ~/linux-app-troubleshooting-poc
```

### 3. Setup Isolated Python Virtual Environment
```bash
python3 -m venv venv
source venv/bin/activate
```
*Verify:*
```bash
which python
# Output should point to /home/ubuntu/linux-app-troubleshooting-poc/venv/bin/python
```

### 4. Install Dependencies
```bash
pip install -r requirements.txt
pip list | grep -E "fastapi|uvicorn"
```

### 5. Run Foreground Baseline Test
```bash
uvicorn app.main:app --host 127.0.0.1 --port 8000
```
Open a secondary terminal on EC2 or run curl:
```bash
curl -s http://127.0.0.1:8000/health
# Expected Output: {"status":"healthy","uptime_seconds":...}
```
Stop the foreground test using `CTRL + C`.

---

## Phase 2: systemd Service Configuration

Managing applications with systemd ensures persistence across crashes and server reboots.

### 1. Deploy the Unit File
```bash
sudo cp systemd/myapp.service /etc/systemd/system/myapp.service
```

### 2. Key Configuration Breakdown
| Directive | Purpose |
|---|---|
| `WorkingDirectory=` | Sets root working directory so relative imports in Python work. |
| `ExecStart=` | Full path to virtual environment uvicorn binary and app module. |
| `Restart=always` | Automatically restarts service if it exits with error or crash. |
| `RestartSec=5` | Waits 5 seconds before attempting restart to prevent rapid thrashing. |
| `StandardOutput=journal` | Sends standard stdout/stderr streams to `systemd-journald`. |

### 3. Enable and Start the Service
```bash
sudo systemctl daemon-reload
sudo systemctl enable myapp.service
sudo systemctl start myapp.service
```

### 4. Verify Service State
```bash
sudo systemctl status myapp.service
```
*Expected Output:*
```
● myapp.service - FastAPI Application Service - Linux Troubleshooting POC
     Loaded: loaded (/etc/systemd/system/myapp.service; enabled)
     Active: active (running) since Sun 2026-10-11 ...
```

### 5. Verify Socket Binding
```bash
sudo ss -tulpn | grep :8000
# Output confirms 127.0.0.1:8000 is LISTEN state
```

---

## Phase 3: Failure Simulations & Root Cause Analysis (RCA)

---

### Scenario 1: Service Stopped Outage

#### A. Failure Simulation
```bash
sudo systemctl stop myapp.service
```

#### B. Observed Symptoms
- Client request fails:
  ```bash
  curl http://127.0.0.1:8000/health
  # curl: (7) Failed to connect to 127.0.0.1 port 8000: Connection refused
  ```

#### C. Investigation & Diagnostic Commands
```bash
# Step 1: Check unit status
sudo systemctl status myapp.service
# Evidence: Active: inactive (dead)

# Step 2: Check socket
sudo ss -tulpn | grep :8000
# Evidence: Empty output (No process listening on port 8000)

# Step 3: Check process list
ps aux | grep uvicorn
```

#### D. Root Cause
The process supervisor stopped the service due to an explicit stop command or system shutdown.

#### E. Corrective Action & Verification
```bash
sudo systemctl start myapp.service
curl -s http://127.0.0.1:8000/health
```

---

### Scenario 2: Port Misconfiguration Mismatch

#### A. Failure Simulation
Simulate a configuration mistake where the service binds to port `8080` instead of `8000`:
```bash
sudo sed -i 's/--port 8000/--port 8080/' /etc/systemd/system/myapp.service
sudo systemctl daemon-reload
sudo systemctl restart myapp.service
```

#### B. Observed Symptoms
- Standard endpoint fails:
  ```bash
  curl http://127.0.0.1:8000/health
  # curl: (7) Failed to connect to 127.0.0.1 port 8000: Connection refused
  ```
- Paradoxical symptom: `systemctl status myapp` shows `Active: active (running)`!

#### C. Investigation & Diagnostic Commands
```bash
# Step 1: Service says active, but port 8000 fails. Which port is the process actually using?
sudo ss -tulpn | grep python3
# Evidence: tcp LISTEN 0 128 127.0.0.1:8080 (Listening on 8080!)

# Step 2: Check unit definition for ExecStart
grep ExecStart /etc/systemd/system/myapp.service
# Evidence: ExecStart=... --port 8080
```

#### D. Root Cause
Port mismatch between expected client communication port (8000) and configured listening port (8080).

#### E. Corrective Action & Verification
```bash
sudo sed -i 's/--port 8080/--port 8000/' /etc/systemd/system/myapp.service
sudo systemctl daemon-reload
sudo systemctl restart myapp.service

# Verify correct socket binding
sudo ss -tulpn | grep :8000
curl -s http://127.0.0.1:8000/health
```

---

### Scenario 3: Missing Python Dependency Crash Loop

#### A. Failure Simulation
Simulate an environment where a critical package is uninstalled:
```bash
/home/ubuntu/linux-app-troubleshooting-poc/venv/bin/pip uninstall -y fastapi
sudo systemctl restart myapp.service
```

#### B. Observed Symptoms
- Endpoint fails with `Connection refused`.
- `systemctl status myapp` shows `activating (auto-restart)` or `failed (Result: exit-code)`.

#### C. Investigation & Diagnostic Commands
```bash
# Step 1: Inspect system logs for the unit
sudo journalctl -u myapp.service -n 25 --no-pager
# Evidence:
# Traceback (most recent call last):
#   File "app/main.py", line 4, in <module>
#     from fastapi import FastAPI
# ModuleNotFoundError: No module named 'fastapi'

# Step 2: Check virtualenv packages
/home/ubuntu/linux-app-troubleshooting-poc/venv/bin/pip list | grep fastapi
# Evidence: (No output - package missing)
```

#### D. Root Cause
`ModuleNotFoundError` caused by missing dependency `fastapi` inside the targeted virtual environment.

#### E. Corrective Action & Verification
```bash
/home/ubuntu/linux-app-troubleshooting-poc/venv/bin/pip install -r /home/ubuntu/linux-app-troubleshooting-poc/requirements.txt
sudo systemctl restart myapp.service

# Verification
sudo systemctl status myapp.service
curl -s http://127.0.0.1:8000/health
```

---

## Phase 4: Nginx Reverse Proxy & 502 Bad Gateway Simulation

### 1. Install Nginx
```bash
sudo apt install -y nginx
```

### 2. Configure Reverse Proxy
```bash
sudo cp nginx/myapp.conf /etc/nginx/sites-available/myapp.conf
sudo ln -sf /etc/nginx/sites-available/myapp.conf /etc/nginx/sites-enabled/myapp.conf
sudo rm -f /etc/nginx/sites-enabled/default
```

### 3. Test & Reload Nginx
```bash
sudo nginx -t
sudo systemctl restart nginx
```

### 4. Verify Normal Proxy Functionality
```bash
curl -I http://127.0.0.1/
# Output: HTTP/1.1 200 OK
curl -s http://127.0.0.1/info
```

### 5. Simulate 502 Bad Gateway Outage
```bash
# Intentionally stop backend application
sudo systemctl stop myapp.service

# Test via Nginx
curl -I http://127.0.0.1/
```
*Observed Output:*
```http
HTTP/1.1 502 Bad Gateway
Server: nginx/...
```

### 6. Investigation & Root Cause Analysis
```bash
# The golden rule of 502 errors: Inspect Nginx Error Log!
sudo tail -n 15 /var/log/nginx/myapp_error.log
```
*Log Evidence:*
```
[error] ... connect() failed (111: Connection refused) while connecting to upstream, upstream: "http://127.0.0.1:8000/"
```
*Conclusion:* Nginx is running normally; the upstream backend (`myapp.service`) is refusing connections.

### 7. Restore & Recovery Validation
```bash
sudo systemctl start myapp.service
curl -I http://127.0.0.1/
# Output: HTTP/1.1 200 OK
```

---

## Phase 5: Automated Symptom Check Script

The script [scripts/health_check.sh](scripts/health_check.sh) validates the system layers without guessing the root cause.

### 1. Make Script Executable
```bash
chmod +x scripts/health_check.sh
```

### 2. Execute Health Check
```bash
./scripts/health_check.sh
```

*Sample Passing Output:*
```
====================================================
   Linux Application Health Check (DevOps POC)      
====================================================
Timestamp: 2026-10-11T09:12:15Z
Target Service : myapp
Target Port    : 8000
Health Endpoint: http://127.0.0.1:8000/health
----------------------------------------------------
[Check 1] Systemd Service State (myapp): [PASS] Service is ACTIVE
[Check 2] Port Listening State (Port 8000): [PASS] Port 8000 is LISTENING
[Check 3] HTTP Health Endpoint: [PASS] HTTP 200 OK
----------------------------------------------------
Overall Status: ALL HEALTH CHECKS PASSED (0 failures)
```

---

## Phase 6: Incident Documentation

Detailed post-mortem records for all four incidents are documented in:
👉 [`docs/incident-report.md`](docs/incident-report.md)

---

## Troubleshooting Command Cheat Sheet

| Task | Command |
|---|---|
| Check systemd status | `sudo systemctl status myapp.service` |
| View live journal logs | `sudo journalctl -u myapp.service -f` |
| View last 50 log lines | `sudo journalctl -u myapp.service -n 50 --no-pager` |
| View open TCP sockets | `sudo ss -tulpn` |
| Filter socket by port | `sudo ss -tulpn \| grep :8000` |
| Check running processes | `ps aux \| grep -E "uvicorn\|python"` |
| Check memory usage | `free -h` |
| Check disk space | `df -h /` |
| Test Nginx config syntax | `sudo nginx -t` |
| Read Nginx error logs | `sudo tail -n 50 /var/log/nginx/myapp_error.log` |

---

## Git Publishing Guide

Push this project to your GitHub account:

```bash
cd ~/linux-app-troubleshooting-poc
git init
git config user.name "Your Name"
git config user.email "your.email@example.com"
git add .
git commit -m "feat: complete Linux application troubleshooting POC with systemd, nginx, and RCA docs"

# Add your GitHub repository remote
git branch -M main
git remote add origin https://github.com/<your-username>/linux-app-troubleshooting-poc.git
git push -u origin main
```

---

## AWS Resource Cleanup (Cost Avoidance)

Once your POC testing is complete, prevent unexpected AWS billing:

1. **Terminate EC2 Instance:**
   - Go to **AWS Console** > **EC2** > **Instances**.
   - Select your POC instance > **Instance State** > **Terminate Instance**.
2. **Release Elastic IP (if assigned):**
   - **EC2** > **Network & Security** > **Elastic IPs** > **Release Elastic IP addresses**.
3. **Delete POC Security Group (Optional):**
   - **EC2** > **Security Groups** > Select POC group > **Delete**.
