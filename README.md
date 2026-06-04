# Customer Service Agent

A retail customer service agent built with Google ADK that handles purchase history lookups, refunds, and product inquiries.

## Prerequisites

- Python 3.10+
- [uv](https://docs.astral.sh/uv/) package manager
- Google Cloud project with billing enabled
- `gcloud` CLI authenticated (`gcloud auth login && gcloud auth application-default login`)

## Setup

```bash
# Install uv if not present
curl -LsSf https://astral.sh/uv/install.sh | sh

# Set environment variables and generate .env
source set_env.sh

# Install dependencies
uv sync
```

## Running Locally

```bash
uv run adk web customer_service_agent
```

---

## Deployment

### Option A — Vertex AI Agent Engine + Gemini Enterprise App

This deploys the agent to Vertex AI Agent Engine (managed, serverless) and registers it with the Gemini Enterprise Agent Platform.

**Deploy and register in one step:**

```bash
./deploy.sh
```

The script:
1. Enables required GCP APIs (`aiplatform`, `cloudresourcemanager`)
2. Deploys the agent to Vertex AI Agent Engine (~5–10 min first run)
3. Saves the Agent Engine resource ID to `.agent_engine_id` for future updates
4. Registers the agent with Gemini Enterprise App

**Subsequent updates** (redeploys in place, ~1–2 min):

```bash
./deploy.sh
```

The saved `.agent_engine_id` is picked up automatically to update the existing engine instead of creating a new one.

**Make the agent available to users:**

1. Go to the [Gemini Enterprise console](https://console.cloud.google.com/gemini/enterprise/apps)
2. Navigate to **Your App → Agents**
3. Click **Share custom agents** and add users or Google Groups

---

### Option B — Cloud Run + Gemini Enterprise App (A2A)

This deploys the agent as an A2A-compatible Cloud Run service and registers it via the agent card protocol.

**Deploy and register:**

```bash
./deploy.sh
```

> To switch between Agent Engine and Cloud Run, edit `deploy.sh` and swap the deployment section. The current default is Agent Engine.

---

## Evaluations

### 1. Programmatic Evaluation (Pytest) — Recommended

```bash
# From project root
PYTHONPATH=. uv run pytest customer_service_agent/test_agent_eval.py
```

### 2. ADK CLI Evaluation

```bash
uv run adk eval customer_service_agent \
  customer_service_agent/eval.test.json \
  --config_file_path customer_service_agent/test_config.json
```

### 3. Golden Dataset Evaluation

```bash
# CLI
uv run adk eval customer_service_agent \
  customer_service_agent/evalset780045.evalset.json \
  --config_file_path customer_service_agent/test_config.json

# Pytest
PYTHONPATH=. uv run pytest customer_service_agent/test_golden_eval.py
```

---

## Project Structure

```
.
├── customer_service_agent/
│   ├── agent.py              # Agent definition and tools
│   ├── requirements.txt      # Agent-specific dependencies
│   ├── eval.test.json        # Evaluation test cases
│   └── test_agent_eval.py    # Pytest evaluation runner
├── deploy.sh                 # Deploy to Agent Engine + register with Gemini Enterprise
├── set_env.sh                # Set GCP environment variables and generate .env
├── pyproject.toml            # Project dependencies
└── .agent_engine_id          # Saved Agent Engine ID (auto-generated, gitignored)
```
