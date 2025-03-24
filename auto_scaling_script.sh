#!/bin/bash

# Configuration
MY_CLOUD_PROJECT="assignment3-452416"      # Your GCP project ID
REGION_ZONE="us-central1-a"                 # GCP zone
SCALE_TRIGGER=75                            # Scaling threshold percentage
LOAD_BALANCER_IP=""
AUTOSCALER_ACCOUNT="auto-scale-sa"          # Service account name
ACCOUNT_KEYFILE="/tmp/service-account-key.json" # Service account key path
VM_CLUSTER="auto-scale-group"               # Instance group name
VM_TEMPLATE="auto-scale-template"           # Instance template name
ACTIVE_VMS_LOG="/tmp/active_gcp_vms.txt"    # Active VMs tracking file
ASSETS_BUCKET="bucket-$MY_CLOUD_PROJECT"    # Storage bucket name

# Install Google Cloud SDK
echo "[+] Installing Google Cloud SDK..."
if ! command -v gcloud &> /dev/null; then
  sudo apt update -y
  sudo apt install -y apt-transport-https ca-certificates curl gnupg
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list
  curl https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | sudo apt-key --keyring /usr/share/keyrings/cloud.google.gpg add -
  sudo apt update -y
  sudo apt install -y google-cloud-sdk
fi

# Check and authenticate
echo "[+] Checking authentication..."
ACTIVE_USER=$(gcloud auth list --filter="status:ACTIVE" --format="value(account)")
if [ -z "$ACTIVE_USER" ]; then
  echo "[-] No active session. Logging in..."
  gcloud auth login
  if [ $? -ne 0 ]; then
    echo "[-] Authentication failed"
    exit 1
  fi
else
  echo "[+] Active session: $ACTIVE_USER"
fi
gcloud config set project $MY_CLOUD_PROJECT

# Create service account
echo "[+] Creating service account..."
if ! gcloud iam service-accounts create $AUTOSCALER_ACCOUNT \
  --description="Auto-scaling service account" \
  --display-name="Cloud Autoscaler" \
  --project=$MY_CLOUD_PROJECT > /dev/null 2>&1; then
  echo "[-] Account creation failed"
fi

echo "[+] Configuring permissions..."
gcloud projects add-iam-policy-binding $MY_CLOUD_PROJECT \
  --member="serviceAccount:$AUTOSCALER_ACCOUNT@$MY_CLOUD_PROJECT.iam.gserviceaccount.com" \
  --role="roles/compute.admin" > /dev/null 2>&1

gcloud iam service-accounts add-iam-policy-binding \
  "$AUTOSCALER_ACCOUNT@$MY_CLOUD_PROJECT.iam.gserviceaccount.com" \
  --member="serviceAccount:$AUTOSCALER_ACCOUNT@$MY_CLOUD_PROJECT.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser" > /dev/null 2>&1

gcloud projects add-iam-policy-binding $MY_CLOUD_PROJECT \
  --member="serviceAccount:$AUTOSCALER_ACCOUNT@$MY_CLOUD_PROJECT.iam.gserviceaccount.com" \
  --role="roles/storage.admin" > /dev/null 2>&1

echo "[+] Generating access key..."
gcloud iam service-accounts keys create $ACCOUNT_KEYFILE \
  --iam-account="$AUTOSCALER_ACCOUNT@$MY_CLOUD_PROJECT.iam.gserviceaccount.com"

echo "[+] Activating service account..."
gcloud auth activate-service-account --key-file=$ACCOUNT_KEYFILE

# Configure local web server
echo "[+] Setting up local web server..."
sudo apt update -y
sudo apt install -y lighttpd
sudo mkdir -p /var/www/html
sudo cp /home/Himani/Documents/index.html /var/www/html/index.html
sudo chown -R www-data:www-data /var/www/html
sudo chmod -R 755 /var/www/html
sudo systemctl enable lighttpd --now
# Initialize the active GCP VMs file with a default value of 0
echo "0" > "$ACTIVE_VMS_LOG"

# Start monitoring loop
echo "[+] Starting resource monitor..."
while true; do
  CPU_LOAD=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
  MEM_LOAD=$(free | grep Mem | awk '{print $3/$2 * 100}')
  echo "System Load - CPU: ${CPU_LOAD}%, Memory: ${MEM_LOAD}%"

  CURRENT_VMS=$(cat $ACTIVE_VMS_LOG)

  if (( $(echo "$CPU_LOAD > $SCALE_TRIGGER" | bc -l) )); then
    if [ "$CURRENT_VMS" -eq 0 ]; then
      echo "[!] High load detected - initializing cloud resources..."
      
      # Set up cloud storage
      gsutil mb -p $MY_CLOUD_PROJECT -l us-central1 gs://$ASSETS_BUCKET || true
      gsutil -m cp -r /var/www/html/* gs://$ASSETS_BUCKET/
      gsutil iam ch allUsers:objectViewer gs://$ASSETS_BUCKET

      # Create instance template
      gcloud compute instance-templates create $VM_TEMPLATE \
        --machine-type=e2-medium \
        --image-project=ubuntu-os-cloud \
        --image-family=ubuntu-2204-lts \
        --tags=http-server \
        --service-account="$AUTOSCALER_ACCOUNT@$MY_CLOUD_PROJECT.iam.gserviceaccount.com" \
        --scopes=cloud-platform,storage-ro \
        --metadata-from-file startup-script=<(cat <<EOF
#!/bin/bash
sudo apt update -y
sudo apt install -y lighttpd
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
  | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg \
  | sudo apt-key --keyring /usr/share/keyrings/cloud.google.gpg add -
sudo apt-get update -qq && sudo apt-get install -y -qq google-cloud-cli
sudo mkdir -p /var/www/html
sudo gsutil -m cp -r gs://$ASSETS_BUCKET/* /var/www/html/ 2>&1
sudo chown -R www-data:www-data /var/www/html
sudo chmod -R 755 /var/www/html
sudo rm -f /var/www/html/index.lighttpd.html
sudo systemctl enable lighttpd
sudo systemctl restart lighttpd
EOF
)

      # Create managed instance group
      gcloud compute instance-groups managed create $VM_CLUSTER \
        --base-instance-name=web-node \
        --template=$VM_TEMPLATE \
        --size=0 \
        --zone=$REGION_ZONE

      # Configure auto-scaling
      gcloud compute instance-groups managed set-autoscaling $VM_CLUSTER \
        --zone=$REGION_ZONE \
        --min-num-replicas=0 \
        --max-num-replicas=5 \
        --target-cpu-utilization=0.75 \
        --cool-down-period=300

      # Set up load balancing
      gcloud compute firewall-rules create allow-web-traffic \
        --allow=tcp:80 \
        --source-ranges=0.0.0.0/0 \
        --target-tags=http-server

      gcloud compute health-checks create http web-health-check \
        --port=80 \
        --check-interval=10s \
        --timeout=5s

      gcloud compute backend-services create web-backend \
        --protocol=HTTP \
        --port-name=http \
        --health-checks=web-health-check \
        --global

      gcloud compute backend-services add-backend web-backend \
        --instance-group=$VM_CLUSTER \
        --instance-group-zone=$REGION_ZONE \
        --global

      gcloud compute url-maps create web-map \
        --default-service=web-backend

      gcloud compute target-http-proxies create web-proxy \
        --url-map=web-map

      gcloud compute forwarding-rules create http-rule \
        --global \
        --target-http-proxy=web-proxy \
        --ports=80

      LOAD_BALANCER_IP=$(gcloud compute forwarding-rules describe http-rule --global --format="value(IPAddress)")
      echo "Load Balancer IP: $LOAD_BALANCER_IP"

      # Create VM monitoring script
      sudo tee /usr/local/bin/vm-monitor.sh > /dev/null <<'EOL'
#!/bin/bash
ACTIVE_VMS_LOG="/tmp/active_gcp_vms.txt"
COUNT=$(gcloud compute instances list --filter="status=RUNNING" --format="value(name)" | wc -l)
echo $COUNT > $ACTIVE_VMS_LOG
EOL
      sudo chmod +x /usr/local/bin/vm-monitor.sh
      (crontab -l 2>/dev/null; echo "*/1 * * * * /usr/local/bin/vm-monitor.sh") | crontab -

    else
      echo "[!] Scaling cloud cluster..."
      CURRENT_SIZE=$(gcloud compute instance-groups managed describe $VM_CLUSTER \
        --zone=$REGION_ZONE \
        --format="value(targetSize)")
      NEW_SIZE=$((CURRENT_SIZE + 1))
      gcloud compute instance-groups managed resize $VM_CLUSTER \
        --zone=$REGION_ZONE \
        --size=$NEW_SIZE
    fi
  fi
  sleep 90
done
