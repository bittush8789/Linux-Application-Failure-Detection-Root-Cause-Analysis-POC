import os
import time
from datetime import datetime, timezone
from fastapi import FastAPI

app = FastAPI(
    title="Linux Application Troubleshooting POC",
    description="A lightweight API used to demonstrate Linux failure detection and root-cause analysis.",
    version="1.0.0"
)

# Application startup timestamp
START_TIME = time.time()

@app.get("/")
def read_root():
    """
    Root endpoint: returns basic status to confirm application is reachable.
    """
    return {
        "status": "online",
        "message": "Welcome to Linux Application Troubleshooting POC",
        "timestamp": datetime.now(timezone.utc).isoformat()
    }

@app.get("/health")
def read_health():
    """
    Health check endpoint: used by monitoring scripts, load balancers, or systemd checks.
    """
    uptime_seconds = round(time.time() - START_TIME, 2)
    return {
        "status": "healthy",
        "uptime_seconds": uptime_seconds,
        "pid": os.getpid(),
        "timestamp": datetime.now(timezone.utc).isoformat()
    }

@app.get("/info")
def read_info():
    """
    Application metadata endpoint: returns version, environment, and system context.
    """
    return {
        "app_name": "linux-app-troubleshooting-poc",
        "version": "1.0.0",
        "environment": os.getenv("APP_ENV", "production"),
        "python_version": os.sys.version.split()[0],
        "default_port": 8000
    }
