import os

# Startup script to install dependencies and start the Flask app

STARTUP_SCRIPT = """#!/bin/bash

apt update -y
apt install -y python3 python3-pip stress
pip3 install flask psutil
echo 'from flask import Flask, jsonify
import psutil

app = Flask(__name__)

@app.route("/")

def home():

  cpu_usage = psutil.cpu_percent(interval=1)

  return jsonify({"message": "Hi! I am Prem, implementing autoscaling in GCP using a local VM"})



if __name__ == "__main__":

  app.run(host="0.0.0.0", port=5000)' > app.py

nohup python3 app.py > flask.log 2>&1 &

"""

# Save the startup script to a file
with open("startup.sh", "w") as f:
  f.write(STARTUP_SCRIPT)

# GCP command to create an autoscaling instance group

command = f"""gcloud beta compute instance-groups managed create instance-group-4 --project=omega-tenure-449909-u0 \
--base-instance-name=instance-group-4 \
--template=projects/omega-tenure-449909-u0/regions/us-central1/instanceTemplates/instance-template-20250303-080709 \
--size=1 --zone=us-central1-b --list-managed-instances-results=pageless && \
gcloud beta compute instance-groups managed set-autoscaling instance-group-4 --project=omega-tenure-449909-u0 \
--zone=us-central1-b --mode=on --min-num-replicas=1 --max-num-replicas=5 --target-cpu-utilization=0.75 \
--cpu-utilization-predictive-method=none --cool-down-period=60"""

# Execute the GCP command

os.system(command)
