#!/bin/bash

#############################################
# HNG13 Stage 1 - Automated Deployment Script
# Author: Daniel Okoroafor
# Description: Deploys Dockerized application with Nginx reverse proxy
#############################################

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Log file with timestamp
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

# Error handler
trap 'log_error "Script failed at line $LINENO. Exit code: $?"' ERR

#############################################
# 1. COLLECT PARAMETERS FROM USER
#############################################
log "Starting deployment script..."

echo -e "\n${GREEN}=== Git Repository Configuration ===${NC}"
read -p "Enter Git Repository URL: " GIT_REPO_URL
read -sp "Enter Personal Access Token (PAT): " GIT_PAT
echo
read -p "Enter Branch name (default: main): " GIT_BRANCH
GIT_BRANCH=${GIT_BRANCH:-main}

echo -e "\n${GREEN}=== Remote Server Configuration ===${NC}"
read -p "Enter SSH Username: " SSH_USER
read -p "Enter Server IP Address: " SERVER_IP
read -p "Enter SSH Key Path: " SSH_KEY_PATH
read -p "Enter Application Port (default: 8080): " APP_PORT
APP_PORT=${APP_PORT:-8080}

# Validate inputs
if [[ -z "$GIT_REPO_URL" || -z "$GIT_PAT" || -z "$SSH_USER" || -z "$SERVER_IP" || -z "$SSH_KEY_PATH" ]]; then
    log_error "All required parameters must be provided!"
    exit 1
fi

if [[ ! -f "$SSH_KEY_PATH" ]]; then
    log_error "SSH key file not found at: $SSH_KEY_PATH"
    exit 1
fi

log "Configuration validated successfully"

#############################################
# 2. CLONE THE REPOSITORY
#############################################
log "Cloning repository..."

# Extract repo name from URL
REPO_NAME=$(basename "$GIT_REPO_URL" .git)
PROJECT_DIR="$HOME/$REPO_NAME"

# Add PAT to URL for authentication
AUTH_URL=$(echo "$GIT_REPO_URL" | sed "s|https://|https://${GIT_PAT}@|")

if [[ -d "$PROJECT_DIR" ]]; then
    log_warning "Repository already exists. Pulling latest changes..."
    cd "$PROJECT_DIR"
    git pull origin "$GIT_BRANCH" || log_error "Failed to pull latest changes"
else
    git clone "$AUTH_URL" "$PROJECT_DIR" || {
        log_error "Failed to clone repository"
        exit 1
    }
    cd "$PROJECT_DIR"
fi

git checkout "$GIT_BRANCH" || log_error "Failed to checkout branch: $GIT_BRANCH"
log "Repository cloned/updated successfully"

#############################################
# 3. VERIFY PROJECT STRUCTURE
#############################################
log "Verifying project structure..."

if [[ ! -f "Dockerfile" ]] && [[ ! -f "docker-compose.yml" ]]; then
    log_error "No Dockerfile or docker-compose.yml found in repository!"
    exit 1
fi

log "Project structure verified"

#############################################
# 4. TEST SSH CONNECTION
#############################################
log "Testing SSH connection to $SERVER_IP..."

ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@$SERVER_IP" "echo 'SSH connection successful'" || {
    log_error "Failed to connect to remote server"
    exit 1
}

log "SSH connection successful"

#############################################
# 5. PREPARE REMOTE ENVIRONMENT
#############################################
log "Preparing remote environment..."

ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash << 'ENDSSH'
set -e

echo "Updating system packages..."
sudo apt update -y

echo "Installing Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo usermod -aG docker $USER
    rm get-docker.sh
else
    echo "Docker already installed"
fi

echo "Installing Docker Compose..."
if ! command -v docker-compose &> /dev/null; then
    sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
else
    echo "Docker Compose already installed"
fi

echo "Installing Nginx..."
if ! command -v nginx &> /dev/null; then
    sudo apt install nginx -y
else
    echo "Nginx already installed"
fi

echo "Starting services..."
sudo systemctl enable docker
sudo systemctl start docker
sudo systemctl enable nginx
sudo systemctl start nginx

echo "Verifying installations..."
docker --version
docker-compose --version
nginx -v

echo "Remote environment prepared successfully"
ENDSSH

log "Remote environment prepared"

#############################################
# 6. DEPLOY DOCKERIZED APPLICATION
#############################################
log "Deploying application to remote server..."

REMOTE_PROJECT_DIR="/home/$SSH_USER/$REPO_NAME"

# Transfer project files
log "Transferring project files..."
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "mkdir -p $REMOTE_PROJECT_DIR"
rsync -avz -e "ssh -i $SSH_KEY_PATH" --exclude='.git' "$PROJECT_DIR/" "$SSH_USER@$SERVER_IP:$REMOTE_PROJECT_DIR/" || {
    log_error "Failed to transfer files"
    exit 1
}

# Build and run Docker container
log "Building and running Docker container..."
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash << ENDSSH
set -e
cd $REMOTE_PROJECT_DIR

# Stop and remove old container if exists
if docker ps -a | grep -q $REPO_NAME; then
    echo "Stopping existing container..."
    docker stop $REPO_NAME || true
    docker rm $REPO_NAME || true
fi

# Build and run new container
if [[ -f "docker-compose.yml" ]]; then
    echo "Using docker-compose..."
    docker-compose down || true
    docker-compose up -d
else
    echo "Using Dockerfile..."
    docker build -t $REPO_NAME .
    docker run -d -p $APP_PORT:80 --name $REPO_NAME --restart unless-stopped $REPO_NAME
fi

# Wait for container to be healthy
sleep 5

# Verify container is running
if docker ps | grep -q $REPO_NAME; then
    echo "Container is running successfully"
    docker ps | grep $REPO_NAME
else
    echo "Container failed to start"
    docker logs $REPO_NAME
    exit 1
fi
ENDSSH

log "Application deployed successfully"

#############################################
# 7. CONFIGURE NGINX REVERSE PROXY
#############################################
log "Configuring Nginx reverse proxy..."

ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash << ENDSSH
set -e

# Create Nginx config
sudo tee /etc/nginx/sites-available/$REPO_NAME > /dev/null << 'EOF'
server {
    listen 80;
    server_name $SERVER_IP;

    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# Enable site
sudo ln -sf /etc/nginx/sites-available/$REPO_NAME /etc/nginx/sites-enabled/$REPO_NAME

# Remove default site if exists
sudo rm -f /etc/nginx/sites-enabled/default

# Test configuration
sudo nginx -t

# Reload Nginx
sudo systemctl reload nginx

echo "Nginx configured successfully"
ENDSSH

log "Nginx reverse proxy configured"

#############################################
# 8. VALIDATE DEPLOYMENT
#############################################
log "Validating deployment..."

# Test from remote server
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash << ENDSSH
set -e

echo "Testing Docker service..."
sudo systemctl is-active docker

echo "Testing container health..."
docker ps | grep $REPO_NAME

echo "Testing Nginx service..."
sudo systemctl is-active nginx

echo "Testing application endpoint..."
curl -f http://localhost:$APP_PORT || exit 1

echo "Testing Nginx proxy..."
curl -f http://localhost || exit 1

echo "All validation checks passed!"
ENDSSH

# Test from local machine
log "Testing application from external network..."
if curl -f "http://$SERVER_IP" > /dev/null 2>&1; then
    log "External access test: SUCCESS"
else
    log_warning "External access test failed. Check firewall settings."
fi

log "Deployment validation completed"

#############################################
# 9. SUMMARY
#############################################
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}   DEPLOYMENT COMPLETED SUCCESSFULLY!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Repository: $GIT_REPO_URL"
echo -e "Branch: $GIT_BRANCH"
echo -e "Server: $SERVER_IP"
echo -e "Application URL: ${GREEN}http://$SERVER_IP${NC}"
echo -e "Log file: $LOG_FILE"
echo -e "${GREEN}========================================${NC}\n"

log "Deployment completed successfully!"
exit 0
