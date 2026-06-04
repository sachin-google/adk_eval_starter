#!/bin/bash
# Deploys customer_service_agent to Vertex AI Agent Engine and registers with Gemini Enterprise App
set -e

# --- Ensure uv is installed ---
if ! command -v uv &>/dev/null; then
  echo "uv not found — installing..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

# --- Load environment variables from .env ---
if [ ! -f .env ]; then
  echo "Error: .env not found. Run 'source set_env.sh' first to generate it."
  exit 1
fi
set -a; source .env; set +a

for var in PROJECT_ID PROJECT_NUMBER REGION; do
  if [ -z "${!var}" ]; then
    echo "Error: $var is not set. Run 'source set_env.sh' first."
    exit 1
  fi
done

DISPLAY_NAME="${DISPLAY_NAME:-Customer Service Agent}"
DESCRIPTION="${DESCRIPTION:-Retail customer service agent for purchase history, refunds, and product inquiries.}"
AGENT_ENGINE_ID_FILE=".agent_engine_id"

# --- Enable required GCP APIs ---
echo "--- Enabling required GCP APIs ---"
gcloud services enable \
  aiplatform.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project="$PROJECT_ID" --quiet
echo "APIs enabled."

# --- Check for existing Agent Engine ID (for updates) ---
AGENT_ENGINE_ID_FLAG=""
if [ -f "$AGENT_ENGINE_ID_FILE" ]; then
  EXISTING_ID=$(cat "$AGENT_ENGINE_ID_FILE")
  echo "Found existing Agent Engine ID: $EXISTING_ID — will update in place."
  AGENT_ENGINE_ID_FLAG="--agent_engine_id=$EXISTING_ID"
fi

# --- Deploy to Vertex AI Agent Engine ---
echo "--- Deploying to Vertex AI Agent Engine ---"
echo "  Project      : $PROJECT_ID"
echo "  Region       : $REGION"
echo "  Display name : $DISPLAY_NAME"

DEPLOY_LOG=$(mktemp)
uv run adk deploy agent_engine \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --display_name="$DISPLAY_NAME" \
  --description="$DESCRIPTION" \
  $AGENT_ENGINE_ID_FLAG \
  customer_service_agent 2>&1 | tee "$DEPLOY_LOG"

# --- Extract resource name from streamed output ---
RESOURCE_NAME=$(grep -oE 'projects/[^/]+/locations/[^/]+/reasoningEngines/[0-9]+' "$DEPLOY_LOG" | tail -1)
rm -f "$DEPLOY_LOG"

if [ -z "$RESOURCE_NAME" ]; then
  echo "ERROR: Could not determine Agent Engine resource name. Check the Vertex AI console:"
  echo "  https://console.cloud.google.com/vertex-ai/agents?project=$PROJECT_ID"
  exit 1
fi

# Save numeric ID for future update runs
RESOURCE_ID=$(echo "$RESOURCE_NAME" | grep -oE '[0-9]+$')
echo "$RESOURCE_ID" > "$AGENT_ENGINE_ID_FILE"
echo "Agent Engine resource : $RESOURCE_NAME"
echo "Saved ID to $AGENT_ENGINE_ID_FILE for future updates."

# --- Register with Gemini Enterprise App ---
echo "--- Registering with Gemini Enterprise App ---"
uvx agent-starter-pack@0.41.1 register-gemini-enterprise \
  --agent-engine-id="$RESOURCE_NAME" \
  --deployment-target="agent_engine" \
  --registration-type="adk" \
  --display-name="$DISPLAY_NAME" \
  --description="$DESCRIPTION" \
  --project-number="$PROJECT_NUMBER"

echo ""
echo "--- Deployment and registration complete ---"
echo "  Agent Engine : $RESOURCE_NAME"
echo "  Console      : https://console.cloud.google.com/vertex-ai/agents?project=$PROJECT_ID"
