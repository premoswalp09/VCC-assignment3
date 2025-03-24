# 🚀 Auto-Scaling Local VM to Google Cloud Platform (GCP)

This project demonstrates how to **automate resource scaling** by monitoring a **local VM's CPU usage** and provisioning additional compute resources in **Google Cloud Platform (GCP)** when the threshold exceeds **75%**.

## 📌 Project Overview

When the **CPU usage** on a local Virtual Machine (**VM**) exceeds **75%**, the system:  
1. **Monitors resource utilization** using a custom script.  
2. **Uploads web content** to Google Cloud Storage.  
3. **Creates new VM instances** in a Managed Instance Group (**MIG**).  
4. **Configures a Load Balancer** for distributing traffic efficiently.  
5. **Ensures seamless scaling** of the application from local to cloud.  


## 🛠️ Technologies Used  

- **Virtualization**: VirtualBox / VMware  
- **Monitoring Tools**: Bash Script, Prometheus (optional)  
- **Cloud Provider**: Google Cloud Platform (GCP)  
- **Compute Services**: Compute Engine, Managed Instance Group (MIG)  
- **Networking**: Load Balancer, Cloud Firewall Rules  
- **Storage**: Google Cloud Storage (GCS)  
- **Automation**: Google Cloud SDK (`gcloud` CLI)  

## ⚡ Features  

✅ **Automated Resource Monitoring** – Detects high CPU usage on local VM.  
✅ **Seamless Auto-Scaling** – Triggers cloud instances automatically.  
✅ **Traffic Redirection** – Routes traffic to GCP Load Balancer when scaling.  
✅ **Cost Optimization** – Creates instances only when needed.  
✅ **Configurable Threshold** – Set CPU usage limit for scaling (default: 75%).  

## 📖 Step-by-Step Setup Guide  

### 🔹 1. Prerequisites  

#### Local Machine:  
- Install **VirtualBox** or **VMware**.  
- Create an **Ubuntu-based VM** with **at least 2 vCPUs and 4GB RAM**.  
- Install **Google Cloud SDK** (`gcloud`).  

#### Google Cloud Setup:  
- Create a **Google Cloud Project** and enable **Compute Engine API**.  
- Configure **IAM roles** for auto-scaling permissions.  
- Setup **Cloud Storage, Compute Engine, and Load Balancer**.  

### 🔹 2. Installation & Setup  

#### 🖥️ **Clone the Repository**  
```bash
git clone https://github.com/premoswalp09/VCC-assignment3.git
```


### 📝 **Update Configuration Variables**
Edit the script file and modify:

```bash
MY_CLOUD_PROJECT="your-project-id"
REGION_ZONE="us-central1-a"
SCALE_TRIGGER=75
```

#### 🚀 Run the Auto-Scaling Script
```bash

bash auto_scaling_script.sh
```

### 🔹 3. Testing Auto-Scaling
### 📊 1. Simulate High CPU Usage
To test auto-scaling, apply a stress test:

```bash
  
  sudo apt install stress -y
  stress -cpu 3 --timeout 100
```
✔️ This should trigger new instances in GCP Compute Engine.

### 🔍 2. Verify in GCP Console
Compute Engine → Instance Groups: See new VMs being created.
Load Balancer → Backend Services: Confirm traffic routing.
Cloud Storage: Check uploaded web content.


📽️ Demo Video
📌 Watch the full setup & scaling process: [google drive video link]
