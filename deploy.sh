#!/bin/bash
# Deploys customer_service_agent to:
#   Phase 1 — Vertex AI Agent Engine  (agent computation + session management)
#   Phase 2 — Cloud Run with --a2a    (A2A-compliant endpoint, sessions via Agent Engine)
#   Phase 3 — Gemini Enterprise App   (A2A registration)
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
SERVICE_NAME="${SERVICE_NAME:-customer-service-agent-${PROJECT_NUMBER}}"
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
A2A_APP_NAME="customer_service_agent"

# Generates the A2A agent card required by the ADK server
generate_agent_json() {
  local base_url="$1"
  cat > customer_service_agent/agent.json << EOF
{
  "name": "Customer Service Agent",
  "description": "Retail customer service agent for purchase history, refunds, and product inquiries.",
  "url": "${base_url}/a2a/${A2A_APP_NAME}",
  "version": "1.0.0",
  "defaultInputModes": ["text/plain"],
  "defaultOutputModes": ["text/plain"],
  "capabilities": {
    "streaming": false,
    "pushNotifications": false
  },
  "skills": [
    {
      "id": "purchase-history",
      "name": "Purchase History",
      "description": "Retrieve order history and status for a customer",
      "tags": ["orders", "history"]
    },
    {
      "id": "issue-refund",
      "name": "Issue Refund",
      "description": "Process a refund for an order",
      "tags": ["refund", "orders"]
    },
    {
      "id": "product-info",
      "name": "Product Information",
      "description": "Look up product details and availability",
      "tags": ["products", "catalog"]
    }
  ]
}
EOF
  echo "Generated customer_service_agent/agent.json"
}

_get_cloud_run_url() {
  gcloud run services describe "$SERVICE_NAME" \
    --region="$REGION" --project="$PROJECT_ID" \
    --format="value(status.url)" 2>/dev/null || true
}

_deploy_cloud_run() {
  local session_uri="$1"
  uv run adk deploy cloud_run \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --service_name="$SERVICE_NAME" \
    --a2a \
    --session_service_uri="$session_uri" \
    customer_service_agent
  # Verify new revision is serving
  local latest created
  latest=$(gcloud run services describe "$SERVICE_NAME" \
    --region="$REGION" --project="$PROJECT_ID" \
    --format="value(status.latestReadyRevisionName)" 2>/dev/null || true)
  created=$(gcloud run services describe "$SERVICE_NAME" \
    --region="$REGION" --project="$PROJECT_ID" \
    --format="value(status.latestCreatedRevisionName)" 2>/dev/null || true)
  if [ "$latest" != "$created" ]; then
    echo "ERROR: Cloud Run deployment failed — new revision ($created) is not serving."
    echo "Logs: https://console.cloud.google.com/logs/viewer?project=$PROJECT_ID"
    exit 1
  fi
}

# ─────────────────────────────────────────────
# Enable APIs
# ─────────────────────────────────────────────
echo "--- Enabling required GCP APIs ---"
gcloud services enable \
  aiplatform.googleapis.com \
  cloudresourcemanager.googleapis.com \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  --project="$PROJECT_ID" --quiet
echo "APIs enabled."

echo "--- Granting Cloud Build IAM permissions ---"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$COMPUTE_SA" \
  --role="roles/cloudbuild.builds.builder" \
  --quiet
echo "Permissions granted to $COMPUTE_SA."

# ─────────────────────────────────────────────
# Phase 1: Vertex AI Agent Engine
# ─────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo " Phase 1: Vertex AI Agent Engine"
echo "════════════════════════════════════════"

AGENT_ENGINE_ID_FLAG=""
EXISTING_ID=""
if [ -f "$AGENT_ENGINE_ID_FILE" ]; then
  EXISTING_ID=$(cat "$AGENT_ENGINE_ID_FILE")
  echo "Found existing Agent Engine ID: $EXISTING_ID — updating in place."
  AGENT_ENGINE_ID_FLAG="--agent_engine_id=$EXISTING_ID"
fi

DEPLOY_LOG=$(mktemp)
uv run adk deploy agent_engine \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --display_name="$DISPLAY_NAME" \
  --description="$DESCRIPTION" \
  --env_file=.env \
  $AGENT_ENGINE_ID_FLAG \
  customer_service_agent 2>&1 | tee "$DEPLOY_LOG"

RESOURCE_NAME=$(grep -oE 'projects/[^/]+/locations/[^/]+/reasoningEngines/[0-9]+' "$DEPLOY_LOG" | tail -1)
rm -f "$DEPLOY_LOG"

if [ -z "$RESOURCE_NAME" ] && [ -n "$EXISTING_ID" ]; then
  RESOURCE_NAME="projects/$PROJECT_NUMBER/locations/$REGION/reasoningEngines/$EXISTING_ID"
fi
if [ -z "$RESOURCE_NAME" ]; then
  echo "ERROR: Could not determine Agent Engine resource name."
  exit 1
fi

RESOURCE_ID=$(echo "$RESOURCE_NAME" | grep -oE '[0-9]+$')
echo "$RESOURCE_ID" > "$AGENT_ENGINE_ID_FILE"
echo "Agent Engine: $RESOURCE_NAME"

# ─────────────────────────────────────────────
# Phase 2: Cloud Run (A2A) with Agent Engine sessions
# ─────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo " Phase 2: Cloud Run (A2A)"
echo "════════════════════════════════════════"

SESSION_URI="agentengine://$RESOURCE_NAME"
EXISTING_URL=$(_get_cloud_run_url)

if [ -n "$EXISTING_URL" ]; then
  # Service exists — generate agent.json with known URL and redeploy
  echo "Existing Cloud Run service: $EXISTING_URL"
  generate_agent_json "$EXISTING_URL"
  _deploy_cloud_run "$SESSION_URI"
  SERVICE_URL=$(_get_cloud_run_url)
else
  # First deployment — deploy once to get URL, then redeploy with agent.json
  echo "First Cloud Run deployment..."
  generate_agent_json "https://placeholder.run.app"
  _deploy_cloud_run "$SESSION_URI"
  SERVICE_URL=$(_get_cloud_run_url)
  echo "Service URL: $SERVICE_URL"
  generate_agent_json "$SERVICE_URL"
  echo "Redeploying with correct agent card URL..."
  _deploy_cloud_run "$SESSION_URI"
fi

echo "Cloud Run service: $SERVICE_URL"

# ─────────────────────────────────────────────
# Phase 3: Gemini Enterprise Registration (A2A)
# ─────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo " Phase 3: Gemini Enterprise Registration"
echo "════════════════════════════════════════"

AGENT_CARD_URL="$SERVICE_URL/a2a/${A2A_APP_NAME}/.well-known/agent-card.json"
echo "Agent card URL: $AGENT_CARD_URL"

uvx agent-starter-pack@0.41.1 register-gemini-enterprise \
  --agent-card-url="$AGENT_CARD_URL" \
  --deployment-target="cloud_run" \
  --project-number="$PROJECT_NUMBER"

echo ""
echo "════════════════════════════════════════"
echo " Deployment complete"
echo "════════════════════════════════════════"
echo "  Agent Engine : $RESOURCE_NAME"
echo "  Cloud Run    : $SERVICE_URL"
echo "  Agent card   : $AGENT_CARD_URL"
echo "  Console      : https://console.cloud.google.com/vertex-ai/agents?project=$PROJECT_ID"
