#!/bin/bash

# Enhanced Worker Setup Script for Allora Testnet

# Exit immediately if a command exits with a non-zero status
set -e

# Function to display error messages
error_exit() {
    echo "[ERROR] $1" >&2
    exit 1
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check for required commands
for cmd in docker docker-compose jq; do
    command_exists "$cmd" || error_exit "$cmd is not installed. Please install it and retry."
done

# Define variables
DEFAULT_RPC="https://rpc.ankr.com/allora_testnet"
DOCKER_NETWORK="allora_network"

# Prompt user for inputs with validation
read -p "Enter your worker index (numeric): " index
if ! [[ "$index" =~ ^[0-9]+$ ]]; then
    error_exit "Worker index must be a numeric value."
fi

read -s -p "Enter your mnemonic phrase: " mnemonic_phrase
echo
if [[ -z "$mnemonic_phrase" ]]; then
    error_exit "Mnemonic phrase cannot be empty."
fi

read -p "Enter your Upshot API key: " upshot_apikey
if [[ -z "$upshot_apikey" ]]; then
    error_exit "Upshot API key cannot be empty."
fi

# Create worker data directory with restricted permissions
WORKER_DIR="worker-data-$index"
if [ -d "$WORKER_DIR" ]; then
    error_exit "Directory $WORKER_DIR already exists. Please choose a different index or remove the existing directory."
fi

mkdir "$WORKER_DIR" 
chmod 700 "$WORKER_DIR"

# Create a Docker network if not exists
if ! docker network ls --format '{{.Name}}' | grep -w "$DOCKER_NETWORK" > /dev/null; then
    docker network create "$DOCKER_NETWORK" || error_exit "Failed to create Docker network."
fi

# Create .env file with restricted permissions
ENV_FILE=".env"
cat << EOF > "$ENV_FILE"
RPC=$DEFAULT_RPC
UPSHOT_APIKEY=$upshot_apikey
EOF
chmod 600 "$ENV_FILE"

# Create docker-compose.yaml with enhanced configurations
DOCKER_COMPOSE_FILE="docker-compose.yaml"
cat << EOF > "$DOCKER_COMPOSE_FILE"
version: '3.8'

services:
  custom-inference:
    build: ./inference
    image: custom-inference
    container_name: custom-inference
    env_file: .env
    ports:
      - "8001:8000"
    networks:
      - $DOCKER_NETWORK
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  custom-worker-$index:
    image: alloranetwork/allora-offchain-node:latest
    container_name: custom-worker-$index
    volumes:
      - ./$WORKER_DIR:/data
      - ./scripts:/scripts:ro
    networks:
      - $DOCKER_NETWORK
    depends_on:
      custom-inference:
        condition: service_healthy
    environment:
      - NAME=worker-$index
      - MNEMONIC_PHRASE=$mnemonic_phrase
      - UPSHOT_APIKEY=$upshot_apikey
      - RPC=$DEFAULT_RPC
    secrets:
      - mnemonic_secret
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    restart: unless-stopped

secrets:
  mnemonic_secret:
    external: false
EOF

# Create Dockerfile for custom-inference if not exists
if [ ! -d "./inference" ]; then
    mkdir ./inference
    cat << 'EOF' > ./inference/Dockerfile
# Example Dockerfile for custom-inference
FROM python:3.9-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

CMD ["python", "inference_service.py"]
EOF

    # Create a sample requirements.txt
    cat << 'EOF' > ./inference/requirements.txt
flask
# Add other dependencies here
EOF

    # Create a sample inference_service.py
    cat << 'EOF' > ./inference/inference_service.py
from flask import Flask, request, jsonify

app = Flask(__name__)

@app.route('/health', methods=['GET'])
def health():
    return jsonify({"status": "healthy"}), 200

@app.route('/inference/<token>', methods=['POST'])
def inference(token):
    data = request.json
    # Implement your inference logic here
    return jsonify({"token": token, "result": "success"}), 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8000)
EOF
fi

# Create init.config with enhanced logic
INIT_SCRIPT="init.config"
cat << 'EOF' > "$INIT_SCRIPT"
#!/bin/bash

set -e

WORKER_DIR="$1"

if [ -z "$WORKER_DIR" ]; then
    echo "[ERROR] Worker directory not specified."
    exit 1
fi

CONFIG_FILE="./config.json"
ENV_FILE="$WORKER_DIR/env_file"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] config.json file not found. Please provide one."
    exit 1
fi

nodeName=$(jq -r '.wallet.addressKeyName' "$CONFIG_FILE")
if [ -z "$nodeName" ] || [ "$nodeName" == "null" ]; then
    read -p "Enter your preferred wallet name: " nodeName
    if [ -z "$nodeName" ]; then
        echo "[ERROR] Wallet name cannot be empty."
        exit 1
    fi
    jq --arg nodeName "$nodeName" '.wallet.addressKeyName = $nodeName' "$CONFIG_FILE" > tmp.$$.json && mv tmp.$$.json "$CONFIG_FILE"
fi

# Check if mnemonic is already set
mnemonic=$(jq -r '.wallet.addressRestoreMnemonic' "$CONFIG_FILE")
if [ -n "$mnemonic" ] && [ "$mnemonic" != "null" ]; then
    echo "Wallet mnemonic already provided."
    echo "NAME=$nodeName" > "$ENV_FILE"
    echo "MNEMONIC_PHRASE=$mnemonic" >> "$ENV_FILE"
    echo "ENV_LOADED=true" >> "$ENV_FILE"
    exit 0
fi

# If mnemonic is not set, prompt the user
read -s -p "Enter your mnemonic phrase: " mnemonic_phrase
echo
if [ -z "$mnemonic_phrase" ]; then
    echo "[ERROR] Mnemonic phrase cannot be empty."
    exit 1
fi

# Update config.json with mnemonic
jq --arg mnemonic "$mnemonic_phrase" '.wallet.addressRestoreMnemonic = $mnemonic' "$CONFIG_FILE" > tmp.$$.json && mv tmp.$$.json "$CONFIG_FILE"

# Save environment variables
echo "NAME=$nodeName" > "$ENV_FILE"
echo "MNEMONIC_PHRASE=$mnemonic_phrase" >> "$ENV_FILE"
echo "ENV_LOADED=true" >> "$ENV_FILE"

echo "Configuration initialized successfully."
EOF

chmod +x "$INIT_SCRIPT"

# Create or update config.json with worker configurations
CONFIG_JSON_FILE="config.json"
if [ ! -f "$CONFIG_JSON_FILE" ]; then
    cat << EOF > "$CONFIG_JSON_FILE"
{
    "wallet": {
        "addressKeyName": "worker-$index",
        "addressRestoreMnemonic": "",
        "alloraHomeDir": "",
        "gas": "1000000",
        "gasAdjustment": 1.0,
        "nodeRpc": "$DEFAULT_RPC",
        "maxRetries": 1,
        "delay": 1,
        "submitTx": true
    },
    "worker": [
        {
            "topicId": 1,
            "inferenceEntrypointName": "api-worker-reputer",
            "loopSeconds": 1,
            "parameters": {
                "InferenceEndpoint": "http://custom-inference:8000/inference/{Token}",
                "Token": "ETH"
            }
        },
        {
            "topicId": 2,
            "inferenceEntrypointName": "api-worker-reputer",
            "loopSeconds": 3,
            "parameters": {
                "InferenceEndpoint": "http://custom-inference:8000/inference/{Token}",
                "Token": "ETH"
            }
        },
        {
            "topicId": 3,
            "inferenceEntrypointName": "api-worker-reputer",
            "loopSeconds": 5,
            "parameters": {
                "InferenceEndpoint": "http://custom-inference:8000/inference/{Token}",
                "Token": "BTC"
            }
        },
        {
            "topicId": 4,
            "inferenceEntrypointName": "api-worker-reputer",
            "loopSeconds": 2,
            "parameters": {
                "InferenceEndpoint": "http://custom-inference:8000/inference/{Token}",
                "Token": "BTC"
            }
        },
        {
            "topicId": 5,
            "inferenceEntrypointName": "api-worker-reputer",
            "loopSeconds": 4,
            "parameters": {
                "InferenceEndpoint": "http://custom-inference:8000/inference/{Token}",
                "Token": "SOL"
            }
        },
        {
            "topicId": 6,
            "inferenceEntrypointName": "api-worker-reputer",
            "loopSeconds": 5,
            "parameters": {
                "InferenceEndpoint": "http://custom-inference:8000/inference/{Token}",
                "Token": "SOL"
            }
        },
        {
            "topicId": 7,
            "inferenceEntrypointName": "api-worker-reputer",
            "loopSeconds": 2,
            "parameters": {
                "InferenceEndpoint": "http://custom-inference:8000/inference/{Token}",
                "Token": "ETH"
            }
        },
        {
            "topicId": 8,
            "inferenceEntrypointName": "api-worker-reputer",
            "loopSeconds": 3,
            "parameters": {
                "InferenceEndpoint": "http://custom-inference:8000/inference/{Token}",
                "Token": "BNB"
            }
        },
        {
            "topicId": 9,
            "inferenceEntrypointName": "api-worker-reputer",
            "loopSeconds": 5,
            "parameters": {
                "InferenceEndpoint": "http://custom-inference:8000/inference/{Token}",
                "Token": "ARB"
            }
        },
        {
            "topicId": 10,
            "inferenceEntrypointName": "api-worker-reputer",
            "loopSeconds": 5,
            "parameters": {
                "InferenceEndpoint": "http://custom-inference:8000/inference/{Token}",
                "Token": "MEME"
            }
        }
    ]
}
EOF
else
    echo "[INFO] config.json already exists. Skipping creation."
fi

# Initialize configuration
./"$INIT_SCRIPT" "$WORKER_DIR"

# Start Docker containers
echo "[INFO] Starting Docker containers..."
docker-compose up -d

echo "[SUCCESS] Worker setup complete. Your worker is running with index $index."
