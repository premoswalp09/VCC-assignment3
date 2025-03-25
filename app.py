from flask import Flask, jsonify
import psutil
import os
import time
import threading

#CPU threshold to tripper GCPVm creation

THRESHOLD = 75  

app = Flask(__name__)

def check_cpu():

  """Monitors CPU usage and starts GCP VM if usage crosses the threshold."""

  while True:

    cpu_usage = psutil.cpu_percent(interval=5)

    print(f"Current CPU Usage: {cpu_usage}%")



    if cpu_usage > THRESHOLD:

      print("⚠️ High CPU detected! Launching GCP VM...")

      # Run GCP VM creation script

      os.system("python3 create_gcp_vm.py")  

    time.sleep(10) 



@app.route("/")

def home():

  cpu_usage = psutil.cpu_percent(interval=1)

  return jsonify({"message": "Local Machine Running", "CPU_Usage": cpu_usage})

if __name__ == "__main__":

  # Start CPU monitoring in background

  threading.Thread(target=check_cpu, daemon=True).start()   

  # Start Flask app

  app.run(host="0.0.0.0", port=5000)

