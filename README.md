# Auto-Scaling Local VM to GCP with Prometheus & Grafana

## Overview

This project sets up a **local virtual machine (VM)** using **Ubuntu 24.04.1** on **VirtualBox**, monitors system resource usage with **Prometheus & Grafana**, and implements **auto-scaling** on **Google Cloud Platform (GCP)** when CPU utilization exceeds **75%**.

## Features

- **Local VM Setup**: Ubuntu VM with monitoring tools
- **Prometheus & Grafana Integration**: Real-time resource usage visualization
- **Auto-Scaling on GCP**: Dynamic scaling based on CPU load
- **Sample Python Application**: For testing monitoring and scaling

---

## 1️⃣ Prerequisites

### **Local Machine Requirements**

- VirtualBox installed
- Ubuntu 24.04.1 VM (3 CPU, 4GB RAM)
- Internet access

### **Google Cloud Setup**

- GCP account ([Sign up here](https://cloud.google.com/))
- `gcloud` CLI installed
- Billing enabled

---

## 2️⃣ Setting Up the Local VM

### **Step 1: Install Prometheus & Grafana**

Run the following Bash script in your Ubuntu VM to install and configure Prometheus & Grafana:

```bash
#!/bin/bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install dependencies
sudo apt install -y wget curl unzip

# Install Prometheus
wget https://github.com/prometheus/prometheus/releases/latest/download/prometheus-*.linux-amd64.tar.gz
tar -xvf prometheus-*.linux-amd64.tar.gz
sudo mv prometheus-*/ /usr/local/prometheus

# Create Prometheus config file
cat <<EOF | sudo tee /usr/local/prometheus/prometheus.yml
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: 'ubuntu_vm'
    static_configs:
      - targets: ['localhost:9090']
  - job_name: 'sample_app'
    static_configs:
      - targets: ['localhost:5000']
EOF

# Install Grafana
sudo apt install -y grafana
sudo systemctl enable --now grafana-server

# Start Prometheus
/usr/local/prometheus/prometheus --config.file=/usr/local/prometheus/prometheus.yml &
```

### **Step 2: Start Prometheus & Grafana**

```bash
/usr/local/prometheus/prometheus --config.file=/usr/local/prometheus/prometheus.yml &
sudo systemctl start grafana-server
```

### **Step 3: Access Grafana**

- Open **[http://localhost:3000](http://localhost:3000)** in your browser
- Default login: **admin / admin**
- Add **Prometheus** as a data source (`http://localhost:9090`)
- Create a new **dashboard** and add visualizations

---

## 3️⃣ Deploying Sample Python Application

Create a simple Flask application to expose metrics:

```bash
pip install flask prometheus_client
```

```python
from flask import Flask
from prometheus_client import start_http_server, Gauge
import random, time

app = Flask(__name__)
metric = Gauge('cpu_usage', 'CPU usage of the system')

@app.route('/')
def index():
    return "Sample Application Running"

if __name__ == "__main__":
    start_http_server(5000)
    while True:
        metric.set(random.uniform(30, 90))
        time.sleep(5)
```

Run the app:

```bash
python app.py &
```

---

## 4️⃣ Configuring Auto-Scaling on GCP

### **Step 1: Create Instance Group with Auto-Scaling**

1. Go to **GCP Console → Compute Engine → Instance Groups**
2. Click **Create Instance Group**
3. Choose **Managed Instance Group**
4. Set **VM template** (Ubuntu, 2vCPUs, 4GB RAM)
5. Enable **Auto-Scaling**:
   - **Min instances:** 1
   - **Max instances:** 3
   - **CPU Utilization Target:** 75%
6. Click **Create**

### **Step 2: Install Monitoring Agent on GCP VM**

Run on GCP VM:

```bash
curl -sSO https://dl.google.com/cloudagents/add-monitoring-agent-repo.sh
sudo bash add-monitoring-agent-repo.sh
sudo apt update
sudo apt install stackdriver-agent -y
sudo systemctl restart stackdriver-agent
```

---

## 5️⃣ Testing Auto-Scaling

### **Step 1: Simulate High CPU Usage**

Run:

```bash
yes > /dev/null & yes > /dev/null & yes > /dev/null &
```

Check CPU load:

```bash
top
```

Once usage crosses **75%**, new instances will be created in **GCP Console → Compute Engine → Instance Groups**.

### **Step 2: Stop CPU Load**

```bash
killall yes
```

---

## 📌 Conclusion

This project successfully sets up **local monitoring** with **Prometheus & Grafana**, and implements **auto-scaling to GCP** when CPU usage exceeds **75%**.

✅ **Next Steps:**

- Add **memory & disk monitoring**
- Use **Kubernetes (GKE)** for scaling instead of instance groups

### **Contributors**

- **Prem Oswal - M23AID037**

---

## 📜 License

This project is licensed under the **MIT License**.

