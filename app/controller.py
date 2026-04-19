from fastapi import FastAPI
import subprocess

app = FastAPI()

@app.post("/run-test")
def run_test(script_name: str):
    # This runs the k6 script and streams metrics to your InfluxDB container
    cmd = f"k6 run --out influxdb=http://localhost:8086/k6 {script_name}"
    subprocess.Popen(cmd.split()) # Use Popen to run in background
    return {"status": "Test started", "script": script_name}
