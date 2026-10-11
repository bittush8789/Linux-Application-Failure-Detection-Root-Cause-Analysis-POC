# Production Incident Report & Post-Mortem Documentation

**Organization:** DevOps & Cloud Engineering  
**Project:** Linux Application Failure Detection & Root Cause Analysis POC  
**Environment:** AWS EC2 (Ubuntu 22.04 LTS)  
**Author:** Senior DevOps Engineer  

---

## Executive Summary

This document presents comprehensive incident reports and root-cause analysis (RCA) records for four distinct failure patterns simulated in the Linux Application Troubleshooting POC:
1. **Scenario 1:** Complete Application Service Outage (Systemd Inactive/Stopped)
2. **Scenario 2:** Port Mismatch / Misconfiguration (Process listening on wrong port)
3. **Scenario 3:** Missing Python Runtime Dependency (`ModuleNotFoundError`)
4. **Scenario 4:** Reverse Proxy Backend Unreachable (`HTTP 502 Bad Gateway` on Nginx)

Each scenario follows the standard ITIL / SRE post-mortem structure: **Impact, Symptoms, Investigation Commands, Log Evidence, Root Cause, Corrective Action, Recovery Validation, and Prevention Recommendations.**

---

# Incident 1: Application Service Inactive (Unexpected Outage)

### 1. Incident Summary
The FastAPI application stopped responding to client health checks and API calls. The service was found in an inactive/dead state.

### 2. Impact
- **Severity:** High (Severity 1)
- **User Impact:** 100% of incoming API requests to port 8000 failed. Clients received "Connection refused".

### 3. Observed Symptoms
- `curl http://127.0.0.1:8000/health` returns `curl: (7) Failed to connect to 127.0.0.1 port 8000: Connection refused`.
- Automated health check script (`health_check.sh`) returns exit code `1` with `Service is INACTIVE / FAILED`.

### 4. Commands Executed for Investigation
```bash
# Check service status
sudo systemctl status myapp.service

# Check system logs for termination signals
sudo journalctl -u myapp.service -n 30 --no-pager

# Check if any stray uvicorn process is still running
ps aux | grep uvicorn

# Check if port 8000 is still bound
sudo ss -tulpn | grep :8000
```

### 5. Log & State Evidence
- `systemctl status myapp`:
  ```
  ● myapp.service - FastAPI Application Service
       Loaded: loaded (/etc/systemd/system/myapp.service; enabled)
       Active: inactive (dead) since Sun 2026-10-11 10:15:22 UTC
  ```
- `ss -tulpn | grep :8000`:
  *(No output returned — socket is unallocated).*

### 6. Root Cause
The `myapp` systemd service unit was manually stopped or terminated by a SIGTERM without restart authorization, causing the ASGI server to cleanly flush and shut down.

### 7. Corrective Action
Start and re-enable the systemd service:
```bash
sudo systemctl start myapp.service
```

### 8. Recovery Validation
```bash
sudo systemctl is-active myapp.service
# Output: active

curl -s http://127.0.0.1:8000/health
# Output: {"status":"healthy","uptime_seconds":1.24,...}
```

### 9. Prevention Recommendations
- Ensure `Restart=always` and `RestartSec=5` are properly defined in the systemd unit file.
- Configure alert triggers on systemd unit state changes via cron or monitoring agents.

---

# Incident 2: Port Misconfiguration (Wrong Port Binding)

### 1. Incident Summary
The application was reported down on its standard entry point (port 8000), even though systemd reported that the service process was active and healthy.

### 2. Impact
- **Severity:** Medium / High
- **User Impact:** Traffic hitting port 8000 was rejected. External clients received connection timeouts or connection refused errors.

### 3. Observed Symptoms
- `systemctl is-active myapp` returned `active` (Misleading green state).
- `curl http://127.0.0.1:8000/` failed with `Connection refused`.
- Engineers suspected the application crashed, but process table showed Uvicorn running.

### 4. Commands Executed for Investigation
```bash
# Verify process state
ps aux | grep uvicorn

# Inspect actual open TCP sockets
sudo ss -tulpn | grep python3

# Inspect the command line arguments passed in systemd unit
cat /etc/systemd/system/myapp.service | grep ExecStart

# Test alternate ports
curl -s http://127.0.0.1:8080/health
```

### 5. Log & State Evidence
- `ss -tulpn | grep python3`:
  ```
  tcp  LISTEN  0  128  127.0.0.1:8080  0.0.0.0:*  users:(("uvicorn",pid=14201,fd=4))
  ```
- `journalctl -u myapp.service -n 10`:
  ```
  INFO: Uvicorn running on http://127.0.0.1:8080 (Press CTRL+C to quit)
  ```
- **Finding:** Process was running, but bound to `8080` instead of the expected `8000`.

### 6. Root Cause
The `ExecStart` directive in `/etc/systemd/system/myapp.service` had an accidental typo or bad configuration: `--port 8080` instead of `--port 8000`.

### 7. Corrective Action
1. Edit `/etc/systemd/system/myapp.service` and change `--port 8080` to `--port 8000`.
2. Reload systemd daemon:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl restart myapp.service
   ```

### 8. Recovery Validation
```bash
sudo ss -tulpn | grep :8000
# Output: tcp LISTEN 0 128 127.0.0.1:8000

curl -s http://127.0.0.1:8000/health
# Output: {"status":"healthy",...}
```

### 9. Prevention Recommendations
- Use environment variables (`PORT=${APP_PORT:-8000}`) rather than hardcoding arbitrary flags.
- Implement configuration linting before restarting production services.

---

# Incident 3: Missing Python Dependency (`ModuleNotFoundError`)

### 1. Incident Summary
After a deployment or environment update, the service entered a rapid restart crash-loop (`auto-restart crash loop`) and failed to start.

### 2. Impact
- **Severity:** Critical
- **User Impact:** Service remained completely offline; systemd repeatedly killed and restarted the failing process.

### 3. Observed Symptoms
- `systemctl status myapp` shows `Active: activating (auto-restart)` or `Active: failed (Result: exit-code)`.
- Process table has no active PID for the service.
- HTTP requests instantly fail.

### 4. Commands Executed for Investigation
```bash
# Check service status and exit code
sudo systemctl status myapp.service

# View detailed Python traceback from journalctl
sudo journalctl -u myapp.service -n 25 --no-pager

# Check Python environment packages
/home/ubuntu/linux-app-troubleshooting-poc/venv/bin/pip list
```

### 5. Log & State Evidence
- `journalctl -u myapp.service`:
  ```
  Process: 15120 ExecStart=/home/ubuntu/linux-app-troubleshooting-poc/venv/bin/uvicorn app.main:app (code=exited, status=1/FAILURE)
  ...
  Traceback (most recent call last):
    File "app/main.py", line 4, in <module>
      from fastapi import FastAPI
  ModuleNotFoundError: No module named 'fastapi'
  ```
- **Finding:** Python interpreter could not locate the `fastapi` module inside the active environment path.

### 6. Root Cause
The virtual environment dependencies were either desynchronized, corrupted, or not installed into the specific venv referenced by `ExecStart` (`/home/ubuntu/linux-app-troubleshooting-poc/venv`).

### 7. Corrective Action
Reinstall all required dependencies directly inside the project's virtual environment:
```bash
/home/ubuntu/linux-app-troubleshooting-poc/venv/bin/pip install -r /home/ubuntu/linux-app-troubleshooting-poc/requirements.txt
sudo systemctl restart myapp.service
```

### 8. Recovery Validation
```bash
sudo systemctl status myapp.service
# Output: Active: active (running)

sudo journalctl -u myapp.service -n 5 --no-pager
# Output: Application startup complete.
```

### 9. Prevention Recommendations
- Never rely on system Python; always pin virtualenv paths in systemd units.
- Include a pre-flight deployment check (`venv/bin/python -m py_compile app/main.py`) before reloading services.

---

# Incident 4: Reverse Proxy Failure (`HTTP 502 Bad Gateway`)

### 1. Incident Summary
Clients attempting to reach the application via public HTTP (port 80) received an `HTTP 502 Bad Gateway` error response page from Nginx.

### 2. Impact
- **Severity:** High
- **User Impact:** All external public traffic was blocked at the web tier.

### 3. Observed Symptoms
- Browser or curl displays:
  ```html
  <html>
  <head><title>502 Bad Gateway</title></head>
  <body><center><h1>502 Bad Gateway</h1></center><hr><center>nginx/1.18.0</center></body>
  </html>
  ```
- `curl -I http://<EC2-PUBLIC-IP>/` returns `HTTP/1.1 502 Bad Gateway`.

### 4. Commands Executed for Investigation
```bash
# 1. Inspect Nginx error logs (The single most important step for 502)
sudo tail -n 25 /var/log/nginx/myapp_error.log

# 2. Check if Nginx itself is running
sudo systemctl status nginx

# 3. Test if backend service is listening on port 8000
curl -s -v http://127.0.0.1:8000/health

# 4. Check backend service status
sudo systemctl status myapp.service
```

### 5. Log & State Evidence
- `/var/log/nginx/myapp_error.log`:
  ```
  2026/10/11 11:20:04 [error] 16233#16233: *1 connect() failed (111: Connection refused) while connecting to upstream, client: 49.36.12.8, server: _, request: "GET / HTTP/1.1", upstream: "http://127.0.0.1:8000/", host: "54.210.12.98"
  ```
- **Finding:** Nginx is healthy and receiving client traffic, but the upstream socket `127.0.0.1:8000` is refusing TCP connection (`111: Connection refused`). The backend service is down.

### 6. Root Cause
The upstream ASGI application (`myapp.service`) was offline, crashed, or not listening on `127.0.0.1:8000`, causing Nginx to return a 502 Bad Gateway response to downstream clients.

### 7. Corrective Action
Restore the upstream application service:
```bash
sudo systemctl restart myapp.service
```
Verify backend is accepting connections locally:
```bash
curl -s http://127.0.0.1:8000/health
```

### 8. Recovery Validation
```bash
curl -I http://127.0.0.1/
# Output: HTTP/1.1 200 OK

sudo tail -n 5 /var/log/nginx/myapp_access.log
# Output: ... "GET / HTTP/1.1" 200 ...
```

### 9. Prevention Recommendations
- Configure upstream health checks and custom 502 fallback error pages in Nginx.
- Implement proactive alerts on 5xx error spikes in Nginx access logs.

---

## Troubleshooting Quick-Reference Table

| Symptom Observed | First Command to Run | Probable Culprit | Verification Command |
|---|---|---|---|
| Connection refused on port 8000 | `systemctl status myapp` | Service stopped or crashed | `journalctl -u myapp -e` |
| Service active but 8000 unreachable | `sudo ss -tulpn \| grep python3` | Port mismatch / binding typo | `cat /etc/systemd/system/myapp.service` |
| `auto-restart` crash loop in systemd | `journalctl -u myapp -n 25` | Missing Python dependency or import bug | `pip list` in venv |
| `502 Bad Gateway` on Nginx (Port 80) | `tail -n 20 /var/log/nginx/error.log` | Backend FastAPI service down | `curl http://127.0.0.1:8000/health` |
| `504 Gateway Timeout` | `top` / `free -h` | CPU/Memory starvation or upstream deadlock | `ps aux --sort=-%cpu` |
