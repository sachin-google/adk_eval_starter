#!/bin/bash
# Deploys customer_service_agent to Cloud Run and registers with Gemini Enterprise App
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

SERVICE_NAME="${SERVICE_NAME:-customer-service-agent-${PROJECT_NUMBER}}"
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
A2A_APP_NAME="customer_service_agent"

# --- Generate agent.json for A2A support ---
# Writes the A2A agent card that enables /.well-known/agent-card.json in the ADK server
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
  echo "Generated customer_service_agent/agent.json (A2A url: ${base_url}/a2a/${A2A_APP_NAME})"
}

_deploy_cloud_run() {
  uv run adk deploy cloud_run \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --service_name="$SERVICE_NAME" \
    --a2a \
    customer_service_agent
  # Verify the new revision is actually serving (deploy can report success but leave old revision active)
  local latest
  latest=$(gcloud run services describe "$SERVICE_NAME" \
    --region="$REGION" --project="$PROJECT_ID" \
    --format="value(status.latestReadyRevisionName)" 2>/dev/null || true)
  local created
  created=$(gcloud run services describe "$SERVICE_NAME" \
    --region="$REGION" --project="$PROJECT_ID" \
    --format="value(status.latestCreatedRevisionName)" 2>/dev/null || true)
  if [ "$latest" != "$created" ]; then
    echo "ERROR: Deployment failed — latest ready revision ($latest) != latest created ($created)"
    echo "Check logs: https://console.cloud.google.com/logs/viewer?project=$PROJECT_ID"
    exit 1
  fi
}

_get_service_url() {
  gcloud run services describe "$SERVICE_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --format="value(status.url)" 2>/dev/null || true
}

echo "--- Enabling required GCP APIs ---"
gcloud services enable \
  aiplatform.googleapis.com \
  cloudresourcemanager.googleapis.com \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  secretmanager.googleapis.com \
  --project="$PROJECT_ID" --quiet
echo "APIs enabled."

echo "--- Granting Cloud Build IAM permissions ---"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$COMPUTE_SA" \
  --role="roles/cloudbuild.builds.builder" \
  --quiet
echo "Permissions granted to $COMPUTE_SA."

# --- Check if service already exists ---
echo "--- Checking for existing Cloud Run service ---"
EXISTING_URL=$(_get_service_url)

if [ -n "$EXISTING_URL" ]; then
  # Service already deployed: generate agent.json with known URL, then redeploy once
  echo "Service already exists at: $EXISTING_URL"
  generate_agent_json "$EXISTING_URL"
  echo "--- Redeploying with A2A agent card ---"
  _deploy_cloud_run
  SERVICE_URL=$(_get_service_url)
else
  # First deployment: deploy to get URL, then add agent.json and redeploy
  echo "--- First deployment (to obtain service URL) ---"
  echo "  Project      : $PROJECT_ID"
  echo "  Region       : $REGION"
  echo "  Service name : $SERVICE_NAME"
  _deploy_cloud_run
  SERVICE_URL=$(_get_service_url)
  echo "Service URL: $SERVICE_URL"

  generate_agent_json "$SERVICE_URL"
  echo "--- Redeploying with A2A agent card ---"
  _deploy_cloud_run
fi

echo "Service URL: $SERVICE_URL"

# --- Register with Gemini Enterprise App ---
AGENT_CARD_URL="$SERVICE_URL/a2a/${A2A_APP_NAME}/.well-known/agent-card.json"

echo "--- Registering with Gemini Enterprise App ---"
echo "  Agent card URL : $AGENT_CARD_URL"
uvx agent-starter-pack@0.41.1 register-gemini-enterprise \
  --agent-card-url="$AGENT_CARD_URL" \
  --deployment-target="cloud_run" \
  --project-number="$PROJECT_NUMBER"

echo ""
echo "--- Deployment and registration complete ---"
echo "  Service URL    : $SERVICE_URL"
echo "  Agent card URL : $AGENT_CARD_URL"
