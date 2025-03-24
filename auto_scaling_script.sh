#!/bin/bash

# Configuration
MY_CLOUD_PROJECT="vcc-assignment-3-454716"      # Your GCP project ID
REGION_ZONE="us-central1-a"                # GCP zone
CPU_SCALE_UP_THRESHOLD=75                  # CPU threshold to scale up (%)
CPU_SCALE_DOWN_THRESHOLD=30                # CPU threshold to scale down (%)
MEM_SCALE_UP_THRESHOLD=75                  # Memory threshold to scale up (%)
MEM_SCALE_DOWN_THRESHOLD=30                # Memory threshold to scale down (%)
LOAD_BALANCER_IP=""
AUTOSCALER_ACCOUNT="auto-scale-sa"         # Service account name
ACCOUNT_KEYFILE="/tmp/service-account-key.json" # Service account key path
VM_CLUSTER="auto-scale-group"              # Instance group name
VM_TEMPLATE="auto-scale-template"          # Instance template name
ACTIVE_VMS_LOG="/tmp/active_gcp_vms.txt"   # Active VMs tracking file
ASSETS_BUCKET="bucket-$MY_CLOUD_PROJECT"   # Storage bucket name
LOG_FILE="/var/log/autoscaler.log"         # Log file for tracking operations
PROXY_PORT=8080                            # Local proxy port to use

# Function for logging
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

# Initialize log file
sudo touch $LOG_FILE
sudo chmod 666 $LOG_FILE
log "Autoscaler script initialized"

# Error handling function
handle_error() {
  log "ERROR: $1"
  if [ -n "$2" ]; then
    log "Exiting with status $2"
    exit $2
  fi
}

# Install Google Cloud SDK
log "Installing Google Cloud SDK..."
if ! command -v gcloud &> /dev/null; then
  sudo apt update -y || handle_error "Failed to update package lists" 1
  sudo apt install -y apt-transport-https ca-certificates curl gnupg || handle_error "Failed to install prerequisites" 1
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list
  curl https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | sudo apt-key --keyring /usr/share/keyrings/cloud.google.gpg add -
  sudo apt update -y || handle_error "Failed to update package lists after adding GCP repo" 1
  sudo apt install -y google-cloud-sdk || handle_error "Failed to install Google Cloud SDK" 1
fi

# Install other required tools
log "Installing required tools..."
sudo apt update -y
sudo apt install -y lighttpd bc jq nginx || handle_error "Failed to install required packages" 1


# Check and authenticate
# Authentication and Project Setup
log "Checking authentication..."

# Check current active account
ACTIVE_USER=$(gcloud auth list --filter="status:ACTIVE" --format="value(account)")

# If no active user or service account is active
if [ -z "$ACTIVE_USER" ] || [[ "$ACTIVE_USER" == *"@"*"iam.gserviceaccount.com" ]]; then
  log "No user session or service account active. Attempting to authenticate..."
  
  # Try to authenticate with a user account
  echo "Please run the following command and follow the prompts:"
  echo "gcloud auth login"
  
  # Prompt for manual intervention
  read -p "Have you logged in? (yes/no): " LOGIN_CONFIRM
  
  if [[ "$LOGIN_CONFIRM" != "yes" ]]; then
    handle_error "Manual authentication required" 1
  fi
  
  # Refresh active user after login
  ACTIVE_USER=$(gcloud auth list --filter="status:ACTIVE" --format="value(account)")
fi

# Verify we have an active account
if [ -z "$ACTIVE_USER" ]; then
  handle_error "Authentication failed. No active account found." 1
fi

log "Active account: $ACTIVE_USER"

# Set the project
log "Setting project to $MY_CLOUD_PROJECT..."
gcloud config set project $MY_CLOUD_PROJECT || handle_error "Failed to set project" 1

# Additional verification
CURRENT_PROJECT=$(gcloud config get-value project)
if [ "$CURRENT_PROJECT" != "$MY_CLOUD_PROJECT" ]; then
  handle_error "Failed to set project correctly. Current project: $CURRENT_PROJECT" 1
fi

log "Project successfully set to $MY_CLOUD_PROJECT"


# Create service account if it doesn't exist
log "Setting up service account..."
if ! gcloud iam service-accounts describe "$AUTOSCALER_ACCOUNT@$MY_CLOUD_PROJECT.iam.gserviceaccount.com" &>/dev/null; then
  log "Creating service account..."
  gcloud iam service-accounts create $AUTOSCALER_ACCOUNT \
    --description="Auto-scaling service account" \
    --display-name="Cloud Autoscaler" \
    --project=$MY_CLOUD_PROJECT || handle_error "Failed to create service account" 2
fi

log "Configuring permissions..."
gcloud projects add-iam-policy-binding $MY_CLOUD_PROJECT \
  --member="serviceAccount:$AUTOSCALER_ACCOUNT@$MY_CLOUD_PROJECT.iam.gserviceaccount.com" \
  --role="roles/compute.admin" > /dev/null 2>&1 || handle_error "Failed to add compute.admin role" 2

gcloud projects add-iam-policy-binding $MY_CLOUD_PROJECT \
  --member="serviceAccount:$AUTOSCALER_ACCOUNT@$MY_CLOUD_PROJECT.iam.gserviceaccount.com" \
  --role="roles/storage.admin" > /dev/null 2>&1 || handle_error "Failed to add storage.admin role" 2

gcloud projects add-iam-policy-binding $MY_CLOUD_PROJECT \
  --member="serviceAccount:$AUTOSCALER_ACCOUNT@$MY_CLOUD_PROJECT.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser" > /dev/null 2>&1 || handle_error "Failed to add serviceAccountUser role" 2

log "Generating access key..."
gcloud iam service-accounts keys create $ACCOUNT_KEYFILE \
  --iam-account="$AUTOSCALER_ACCOUNT@$MY_CLOUD_PROJECT.iam.gserviceaccount.com" || handle_error "Failed to create service account key" 2

log "Activating service account..."
gcloud auth activate-service-account --key-file=$ACCOUNT_KEYFILE || handle_error "Failed to activate service account" 2

# Configure local web server
log "Setting up local web server..."
sudo mkdir -p /var/www/html
sudo cp /home/Himani/Documents/index.html /var/www/html/index.html
sudo chown -R www-data:www-data /var/www/html
sudo chmod -R 755 /var/www/html
sudo systemctl enable lighttpd --now || handle_error "Failed to enable lighttpd" 3

# Add server information to index.html
sudo sed -i '/<div class="info">/a \      <p>Server: Local VM</p>' /var/www/html/index.html

# Initialize the active GCP VMs file with a default value of 0
echo "0" > "$ACTIVE_VMS_LOG"

# Function to check if GCP resources exist
check_gcp_resources() {
  if gcloud compute instance-groups managed describe $VM_CLUSTER --zone=$REGION_ZONE &>/dev/null; then
    return 0
  else
    return 1
  fi
}

# Function to check GCP backend health
check_backend_health() {
  local status=$(gcloud compute backend-services get-health web-backend \
    --global 2>/dev/null | grep status | head -1 | awk '{print $2}')
  
  if [[ "$status" == "HEALTHY" ]]; then
    return 0
  else
    return 1
  fi
}

# Function to set up reverse proxy for hybrid architecture
setup_reverse_proxy() {
  log "Setting up reverse proxy with Nginx..."
  
  # Configure Nginx as reverse proxy
  sudo tee /etc/nginx/sites-available/reverse-proxy.conf > /dev/null <<EOL
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOL

  sudo ln -sf /etc/nginx/sites-available/reverse-proxy.conf /etc/nginx/sites-enabled/
  sudo rm -f /etc/nginx/sites-enabled/default
  
  # Configure Nginx upstream
  sudo tee /etc/nginx/conf.d/load-balancer.conf > /dev/null <<EOL
upstream backend {
    server 127.0.0.1:$PROXY_PORT weight=10;
    # Cloud instances will be added dynamically
}

server {
    listen 8000;
    
    location / {
        proxy_pass http://backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOL

  # Start local proxy to serve content
  sudo systemctl restart lighttpd
  sudo sed -i 's/server.port.*=.*/server.port = '"$PROXY_PORT"'/' /etc/lighttpd/lighttpd.conf
  sudo systemctl restart lighttpd
  sudo systemctl reload nginx
  
  log "Reverse proxy setup complete. Local content available on port 80."
}

# Function to update Nginx configuration with GCP backends
update_nginx_backends() {
  local lb_ip=$1
  if [ -n "$lb_ip" ]; then
    # Update the upstream configuration
    sudo tee /etc/nginx/conf.d/load-balancer.conf > /dev/null <<EOL
upstream backend {
    server 127.0.0.1:$PROXY_PORT weight=10;
    server $lb_ip weight=20;
}

server {
    listen 8000;
    
    location / {
        proxy_pass http://backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOL
    sudo systemctl reload nginx
    log "Updated load balancer configuration with cloud backend: $lb_ip"
  fi
}

# Function to initialize cloud resources
initialize_cloud_resources() {
  log "Initializing cloud resources..."
  
  # Set up cloud storage
  if ! gsutil ls -b gs://$ASSETS_BUCKET &>/dev/null; then
    gsutil mb -p $MY_CLOUD_PROJECT -l us-central1 gs://$ASSETS_BUCKET || handle_error "Failed to create bucket" 4
  fi
  
  # Modify index.html for cloud instances
  sudo cp /var/www/html/index.html /tmp/cloud-index.html
  sudo sed -i '/<div class="info">/a \      <p>Server: GCP Cloud Instance</p>' /tmp/cloud-index.html
  
  # Upload to bucket
  gsutil -m cp -r /var/www/html/* gs://$ASSETS_BUCKET/ || handle_error "Failed to upload to bucket" 4
  gsutil cp /tmp/cloud-index.html gs://$ASSETS_BUCKET/index.html || handle_error "Failed to upload cloud index" 4
  gsutil iam ch allUsers:objectViewer gs://$ASSETS_BUCKET || handle_error "Failed to set bucket permissions" 4

  # Create instance template
  log "Creating instance template..."
  gcloud compute instance-templates create $VM_TEMPLATE \
    --machine-type=e2-medium \
    --image-project=ubuntu-os-cloud \
    --image-family=ubuntu-2204-lts \
    --tags=http-server \
    --service-account="$AUTOSCALER_ACCOUNT@$MY_CLOUD_PROJECT.iam.gserviceaccount.com" \
    --scopes=cloud-platform,storage-ro \
    --metadata-from-file startup-script=<(cat <<EOF
#!/bin/bash
# Log startup
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Instance startup initiated" > /var/log/startup.log

# Install required packages
apt update -y
apt install -y lighttpd

# Install gcloud CLI
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
  | tee /etc/apt/sources.list.d/google-cloud-sdk.list
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg \
  | apt-key --keyring /usr/share/keyrings/cloud.google.gpg add -
apt-get update -qq && apt-get install -y -qq google-cloud-cli

# Set up web directory
mkdir -p /var/www/html
gsutil -m cp -r gs://$ASSETS_BUCKET/* /var/www/html/ 2>&1 >> /var/log/startup.log
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html
rm -f /var/www/html/index.lighttpd.html

# Configure and start web server
systemctl enable lighttpd
systemctl restart lighttpd

# Send startup success signal
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Instance ready and serving content" >> /var/log/startup.log
curl -s -X POST "https://www.google.com/ping?sitemap=https://$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip -H "Metadata-Flavor: Google")/ready"
EOF
) || handle_error "Failed to create instance template" 5

  # Create managed instance group
  log "Creating managed instance group..."
  gcloud compute instance-groups managed create $VM_CLUSTER \
    --base-instance-name=web-node \
    --template=$VM_TEMPLATE \
    --size=0 \
    --zone=$REGION_ZONE || handle_error "Failed to create instance group" 5

  # Configure auto-scaling
  log "Setting up auto-scaling policies..."
  gcloud compute instance-groups managed set-autoscaling $VM_CLUSTER \
    --zone=$REGION_ZONE \
    --min-num-replicas=0 \
    --max-num-replicas=5 \
    --target-cpu-utilization=0.7 \
    --cool-down-period=120 || handle_error "Failed to set up auto-scaling" 5

  # Set up load balancing
  log "Setting up load balancing..."
  gcloud compute firewall-rules create allow-web-traffic \
    --allow=tcp:80 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=http-server || log "Firewall rule already exists or failed to create"

  gcloud compute health-checks create http web-health-check \
    --port=80 \
    --check-interval=10s \
    --timeout=5s || log "Health check already exists or failed to create"

  gcloud compute backend-services create web-backend \
    --protocol=HTTP \
    --port-name=http \
    --health-checks=web-health-check \
    --global || log "Backend service already exists or failed to create"

  gcloud compute backend-services add-backend web-backend \
    --instance-group=$VM_CLUSTER \
    --instance-group-zone=$REGION_ZONE \
    --global || log "Failed to add backend"

  gcloud compute url-maps create web-map \
    --default-service=web-backend || log "URL map already exists or failed to create"

  gcloud compute target-http-proxies create web-proxy \
    --url-map=web-map || log "HTTP proxy already exists or failed to create"

  gcloud compute forwarding-rules create http-rule \
    --global \
    --target-http-proxy=web-proxy \
    --ports=80 || log "Forwarding rule already exists or failed to create"

  LOAD_BALANCER_IP=$(gcloud compute forwarding-rules describe http-rule --global --format="value(IPAddress)")
  if [ -n "$LOAD_BALANCER_IP" ]; then
    log "Load Balancer IP: $LOAD_BALANCER_IP"
    update_nginx_backends $LOAD_BALANCER_IP
  else
    log "Failed to get Load Balancer IP"
  fi

  log "Cloud resources initialized successfully"
}

# Function to clean up cloud resources
cleanup_cloud_resources() {
  log "Cleaning up cloud resources due to sustained low load..."
  
  # Scale down to 0
  gcloud compute instance-groups managed resize $VM_CLUSTER \
    --zone=$REGION_ZONE \
    --size=0 || log "Failed to resize instance group to 0"
  
  # Wait for instances to terminate
  log "Waiting for instances to terminate..."
  sleep 30
  
  log "Resources scaled down to minimum. Infrastructure remains for fast scaling."
}

# Function to scale up cloud resources
scale_up_cloud_resources() {
  log "Scaling up cloud resources..."
  CURRENT_SIZE=$(gcloud compute instance-groups managed describe $VM_CLUSTER \
    --zone=$REGION_ZONE \
    --format="value(targetSize)" 2>/dev/null || echo "0")
  
  if [ -z "$CURRENT_SIZE" ] || [ "$CURRENT_SIZE" == "0" ]; then
    CURRENT_SIZE=0
  fi
  
  NEW_SIZE=$((CURRENT_SIZE + 1))
  if [ $NEW_SIZE -le 5 ]; then
    log "Increasing instance count to $NEW_SIZE"
    gcloud compute instance-groups managed resize $VM_CLUSTER \
      --zone=$REGION_ZONE \
      --size=$NEW_SIZE || log "Failed to resize instance group"
  else
    log "Already at maximum capacity ($CURRENT_SIZE instances)"
  fi
}

# Function to scale down cloud resources
scale_down_cloud_resources() {
  log "Scaling down cloud resources..."
  CURRENT_SIZE=$(gcloud compute instance-groups managed describe $VM_CLUSTER \
    --zone=$REGION_ZONE \
    --format="value(targetSize)" 2>/dev/null || echo "0")
  
  if [ -z "$CURRENT_SIZE" ] || [ "$CURRENT_SIZE" == "0" ]; then
    log "Already at minimum capacity (0 instances)"
    return
  fi
  
  NEW_SIZE=$((CURRENT_SIZE - 1))
  log "Decreasing instance count to $NEW_SIZE"
  gcloud compute instance-groups managed resize $VM_CLUSTER \
    --zone=$REGION_ZONE \
    --size=$NEW_SIZE || log "Failed to resize instance group"
}

# Create VM monitoring script
log "Setting up VM monitoring script..."
sudo tee /usr/local/bin/vm-monitor.sh > /dev/null <<'EOL'
#!/bin/bash
ACTIVE_VMS_LOG="/tmp/active_gcp_vms.txt"
MY_CLOUD_PROJECT="assignment3-452416"
VM_CLUSTER="auto-scale-group"
REGION_ZONE="us-central1-a"

COUNT=$(gcloud compute instance-groups managed list-instances $VM_CLUSTER \
  --zone=$REGION_ZONE \
  --format="value(name)" | wc -l)

echo $COUNT > $ACTIVE_VMS_LOG
EOL
sudo chmod +x /usr/local/bin/vm-monitor.sh
(crontab -l 2>/dev/null; echo "*/1 * * * * /usr/local/bin/vm-monitor.sh") | crontab -

# Set up reverse proxy
setup_reverse_proxy

# Main monitoring loop
log "Starting resource monitoring loop..."
LOW_LOAD_COUNT=0
CLOUD_INITIALIZED=false

if check_gcp_resources; then
  log "Existing GCP resources detected"
  CLOUD_INITIALIZED=true
  LOAD_BALANCER_IP=$(gcloud compute forwarding-rules describe http-rule --global --format="value(IPAddress)" 2>/dev/null)
  if [ -n "$LOAD_BALANCER_IP" ]; then
    log "Retrieved Load Balancer IP: $LOAD_BALANCER_IP"
    update_nginx_backends $LOAD_BALANCER_IP
  fi
else
  log "No existing GCP resources detected"
fi

while true; do
  # Get system metrics
  CPU_LOAD=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
  MEM_LOAD=$(free | grep Mem | awk '{print $3/$2 * 100}')
  CURRENT_VMS=$(cat $ACTIVE_VMS_LOG)
  
  # Log current state
  log "System Load - CPU: ${CPU_LOAD}%, Memory: ${MEM_LOAD}%, Active VMs: ${CURRENT_VMS}"
  
  # Decision logic for scaling
  if (( $(echo "$CPU_LOAD > $CPU_SCALE_UP_THRESHOLD" | bc -l) )) || \
     (( $(echo "$MEM_LOAD > $MEM_SCALE_UP_THRESHOLD" | bc -l) )); then
    
    log "High load detected!"
    LOW_LOAD_COUNT=0
    
    if [ "$CLOUD_INITIALIZED" = false ]; then
      log "Initializing cloud infrastructure..."
      initialize_cloud_resources
      CLOUD_INITIALIZED=true
    else
      log "Cloud infrastructure already initialized"
      scale_up_cloud_resources
    fi
    
  elif (( $(echo "$CPU_LOAD < $CPU_SCALE_DOWN_THRESHOLD" | bc -l) )) && \
       (( $(echo "$MEM_LOAD < $MEM_SCALE_DOWN_THRESHOLD" | bc -l) )); then
    
    log "Low load detected (${LOW_LOAD_COUNT}/5 consecutive checks)"
    LOW_LOAD_COUNT=$((LOW_LOAD_COUNT + 1))
    
    if [ $LOW_LOAD_COUNT -ge 5 ] && [ "$CURRENT_VMS" -gt 0 ]; then
      log "Sustained low load detected"
      LOW_LOAD_COUNT=0
      scale_down_cloud_resources
    fi
    
  else
    log "Load within normal range"
    LOW_LOAD_COUNT=0
  fi
  
  # Update backend health status if cloud is initialized
  if [ "$CLOUD_INITIALIZED" = true ] && [ $((RANDOM % 5)) -eq 0 ]; then
    if check_backend_health; then
      log "GCP backend is healthy"
    else
      log "GCP backend is not healthy"
    fi
  fi
  
  sleep 60
done
