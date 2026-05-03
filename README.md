# rag-gcp-deployment

> **Iteration 5 of 6** — Cloud deployment on GCP with GKE Autopilot, Cloud SQL (pgvector), Artifact Registry, Workload Identity, and Kubernetes autoscaling.

![Python](https://img.shields.io/badge/Python-3.11+-blue?logo=python&logoColor=white)
![GCP](https://img.shields.io/badge/GCP-Google_Cloud-4285F4?logo=googlecloud&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-GKE_Autopilot-326CE5?logo=kubernetes&logoColor=white)
![Docker](https://img.shields.io/badge/Artifact_Registry-Docker-2496ED?logo=docker&logoColor=white)
![GitHub Actions](https://img.shields.io/badge/GitHub_Actions-CI%2FCD-2088FF?logo=githubactions&logoColor=white)
![FastAPI](https://img.shields.io/badge/FastAPI-0.115-009688?logo=fastapi)

---

## What this does

Takes the full RAG API from Iteration 4 (Docker Compose) and deploys it to **Google Cloud Platform** with a production-grade setup:

- **GKE Autopilot** — fully managed Kubernetes, no node pool configuration needed
- **Cloud SQL (Postgres 15)** — managed database with pgvector extension enabled
- **Cloud SQL Auth Proxy sidecar** — pods authenticate to the DB via IAM, no passwords in env vars
- **Artifact Registry** — GCP's managed Docker image repository
- **Workload Identity** — keyless auth between Kubernetes pods and GCP services
- **HPA** — scales pods 2–10 based on CPU and memory usage
- **GitHub Actions** — CI/CD with keyless GCP auth, Artifact Registry push, GKE rollout, and auto-rollback

---

## Architecture

```
GitHub (push to main)
        │
        ▼
  GitHub Actions
  lint → test → build
        │
        ▼
  Artifact Registry
  us-central1-docker.pkg.dev/PROJECT/rag-repo/rag-api:sha-abc
        │
        ▼
  GKE Autopilot Cluster  (us-central1)
  ┌──────────────────────────────────────────────────┐
  │  Namespace: rag                                  │
  │                                                  │
  │  Pod ×2–10  (HPA scales on CPU 70% / Mem 80%)   │
  │  ┌────────────────────────────────────────────┐  │
  │  │  cloud-sql-proxy  (sidecar)                │  │
  │  │  Listens on localhost:5432                 │  │
  │  │  Authenticates to Cloud SQL via IAM        │  │
  │  │                                            │  │
  │  │  rag-api  (main container)  :8000          │  │
  │  │  Connects to localhost:5432                │  │
  │  └────────────────────────────────────────────┘  │
  │                                                  │
  │  Internal LoadBalancer Service  (VPC only)       │
  │  ConfigMap — non-secret config                   │
  │  ServiceAccount — Workload Identity annotation   │
  └──────────────────────────────────────────────────┘
        │                       │
        ▼                       ▼
   Cloud SQL               Secret Manager
   Postgres 15 + pgvector  GROQ_API_KEY
   HNSW + FTS indexes
```

---

## Project structure

```
rag-gcp-deployment/
├── Dockerfile                   Multi-stage build, HuggingFace models pre-downloaded
├── docker-compose.yml           Local dev only (app + db)
├── requirements.txt
├── pyproject.toml               Ruff + pytest config
├── .env.example
├── init.sql                     HNSW index + GIN FTS index + tsvector column
├── scripts/
│   └── gcp_setup.sh             One-time GCP infrastructure provisioning (Linux/Mac/WSL)
├── k8s/
│   ├── deployment.yaml          GKE Deployment + Cloud SQL Auth Proxy sidecar
│   └── service.yaml             Namespace, LoadBalancer Service, HPA, ConfigMap, ServiceAccount
├── tests/
│   └── test_api.py              pytest unit tests (pipeline mocked)
├── .github/
│   └── workflows/ci.yml         lint → test → build → Artifact Registry → GKE deploy
└── src/                         All source files from Iteration 4 (unchanged)
```

---

## Prerequisites

- Google Cloud account with billing enabled
- `gcloud` CLI installed — [install guide](https://cloud.google.com/sdk/docs/install)
- `kubectl` — install via `gcloud components install kubectl`
- Docker Desktop running
- Python 3.11+
- Groq API key — free at [console.groq.com](https://console.groq.com)

---

## One-time GCP setup

### Linux / Mac / WSL
```bash
# Edit PROJECT_ID and REGION at the top of the script first
chmod +x scripts/gcp_setup.sh
./scripts/gcp_setup.sh
```

### Windows (PowerShell as Administrator)

Run each block in order. Replace `your-project-id` with your actual GCP project ID from [console.cloud.google.com](https://console.cloud.google.com).

```powershell
$PROJECT_ID = "your-project-id"
$REGION     = "us-central1"

# Authenticate
gcloud auth login
gcloud config set project $PROJECT_ID

# Enable required APIs
gcloud services enable container.googleapis.com sqladmin.googleapis.com `
  artifactregistry.googleapis.com secretmanager.googleapis.com iam.googleapis.com

# Create Artifact Registry repository
gcloud artifacts repositories create rag-repo `
  --repository-format=docker --location=$REGION

# Create GKE Autopilot cluster (~3 min)
gcloud container clusters create-auto rag-cluster `
  --region=$REGION --project=$PROJECT_ID

# Enable Workload Identity
gcloud container clusters update rag-cluster `
  --region=$REGION --workload-pool=$PROJECT_ID.svc.id.goog

# Create Cloud SQL instance (~5 min)
gcloud sql instances create rag-postgres `
  --database-version=POSTGRES_15 --region=$REGION --tier=db-g1-small

# Create database and user
gcloud sql databases create rag_db --instance=rag-postgres
gcloud sql users create rag --instance=rag-postgres --password=rag_secret

# Create GCP Service Account
gcloud iam service-accounts create rag-api --display-name="RAG API"

# Grant permissions
gcloud projects add-iam-policy-binding $PROJECT_ID `
  --member="serviceAccount:rag-api@$PROJECT_ID.iam.gserviceaccount.com" `
  --role="roles/cloudsql.client"

gcloud projects add-iam-policy-binding $PROJECT_ID `
  --member="serviceAccount:rag-api@$PROJECT_ID.iam.gserviceaccount.com" `
  --role="roles/secretmanager.secretAccessor"

# Bind Workload Identity
gcloud iam service-accounts add-iam-policy-binding `
  rag-api@$PROJECT_ID.iam.gserviceaccount.com `
  --role="roles/iam.workloadIdentityUser" `
  --member="serviceAccount:$PROJECT_ID.svc.id.goog[rag/rag-api-sa]"

# Store Groq key in Secret Manager
$GROQ_KEY = "your_groq_api_key_here"
$GROQ_KEY | Out-File -FilePath "$env:TEMP\groq_key.txt" -Encoding ascii -NoNewline
gcloud secrets create rag-groq-key --data-file="$env:TEMP\groq_key.txt" --project=$PROJECT_ID
Remove-Item "$env:TEMP\groq_key.txt"
```

Then enable the pgvector extension via **GCP Console → Cloud SQL → Cloud SQL Studio**:
```sql
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
```

---

## Build and deploy

```powershell
# Get cluster credentials
gcloud container clusters get-credentials rag-cluster --region=us-central1

# Authenticate Docker
gcloud auth configure-docker us-central1-docker.pkg.dev

# Build and push image
$IMAGE = "us-central1-docker.pkg.dev/$PROJECT_ID/rag-repo/rag-api:latest"
docker build -t $IMAGE .
docker push $IMAGE

# Replace placeholders in manifests
(Get-Content k8s\deployment.yaml) `
  -replace 'REGION', 'us-central1' `
  -replace 'PROJECT_ID', $PROJECT_ID `
  -replace 'IMAGE_TAG', 'latest' | Set-Content k8s\deployment.yaml

(Get-Content k8s\service.yaml) `
  -replace 'PROJECT_ID', $PROJECT_ID `
  -replace 'REGION', 'us-central1' | Set-Content k8s\service.yaml

# Apply manifests (run twice — first creates namespace, second deploys into it)
kubectl apply -f k8s/
kubectl apply -f k8s/

# Create the Groq secret in Kubernetes
kubectl create secret generic rag-secrets `
  --from-literal=GROQ_API_KEY="your_groq_api_key_here" `
  --namespace=rag

# Annotate the ServiceAccount for Workload Identity
kubectl annotate serviceaccount rag-api-sa `
  --namespace=rag `
  iam.gke.io/gcp-service-account=rag-api@$PROJECT_ID.iam.gserviceaccount.com

# Restart to pick up all changes
kubectl rollout restart deployment/rag-api -n rag
kubectl get pods -n rag -w
```

Wait for `2/2 Running` on both pods.

---

## Testing the deployment

The LoadBalancer is internal (VPC only). Use port-forwarding to test from your machine:

```powershell
# In one terminal — forward port
kubectl port-forward service/rag-api-service 8080:80 -n rag

# In a second terminal — test
Invoke-RestMethod -Uri "http://localhost:8080/health"

Invoke-RestMethod -Method Post -Uri "http://localhost:8080/ingest/sync" `
  -ContentType "application/json" `
  -Body '{"source": "https://en.wikipedia.org/wiki/Retrieval-augmented_generation"}'

Invoke-RestMethod -Method Post -Uri "http://localhost:8080/query" `
  -ContentType "application/json" `
  -Body '{"question": "What is retrieval-augmented generation?"}'
```

Expected health response:
```json
{
  "status": "ok",
  "pipeline": "ready",
  "model": "llama-3.3-70b-versatile",
  "embed": "BAAI/bge-small-en-v1.5"
}
```

---

## GitHub Actions CI/CD setup

### Required secrets (Settings → Secrets → Actions)

| Secret | Description |
|---|---|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | From `gcloud iam workload-identity-pools describe` |
| `GCP_SERVICE_ACCOUNT` | `rag-api@PROJECT_ID.iam.gserviceaccount.com` |
| `GROQ_API_KEY` | Your Groq key (for running tests in CI) |

### Required variables (Settings → Variables → Actions)

| Variable | Value |
|---|---|
| `GCP_PROJECT_ID` | Your GCP project ID |
| `GCP_REGION` | `us-central1` |
| `GKE_CLUSTER` | `rag-cluster` |
| `AR_REPO` | `rag-repo` |

### Pipeline flow

```
push to main
      │
      ▼
  [lint]     ruff check + format
      │
      ▼
  [test]     pytest with live Postgres service container
      │
      ▼
  [build]    docker buildx → Artifact Registry (sha-{commit} + latest)
      │
      ▼
  [deploy]   kubectl apply -f k8s/
             kubectl set image → sha-{commit}
             kubectl rollout status --timeout=300s
             auto-rollback on failure
```

---

## Useful kubectl commands

```powershell
# Check pod status
kubectl get pods -n rag

# View app logs
kubectl logs -l app=rag-api -c rag-api -n rag --tail=50

# View Cloud SQL proxy logs
kubectl logs -l app=rag-api -c cloud-sql-proxy -n rag --tail=20

# Check HPA scaling status
kubectl get hpa -n rag

# Check service and IP
kubectl get service -n rag

# Restart deployment
kubectl rollout restart deployment/rag-api -n rag

# Roll back to previous version
kubectl rollout undo deployment/rag-api -n rag
```

---

## Autoscaling behaviour

| Load | Pods | Trigger |
|---|---|---|
| Idle | 2 | `minReplicas` |
| Moderate | 2–5 | CPU > 70% |
| High | 5–10 | CPU > 70% sustained |
| Peak | 10 | `maxReplicas` |

Scale-up: max +2 pods per minute. Scale-down: 5-minute stabilisation window to avoid thrashing.

---

## Cost management

Stop billing when not in use:

```powershell
# Scale down to zero (stops pod billing)
kubectl scale deployment rag-api --replicas=0 -n rag

# Delete cluster entirely (stops all GKE billing)
gcloud container clusters delete rag-cluster --region=us-central1

# Stop Cloud SQL instance
gcloud sql instances patch rag-postgres --activation-policy=NEVER
```

---

## Local development (unchanged from Iteration 4)

```powershell
docker compose up db -d
python main.py serve
# API at http://localhost:8000/docs
```

---

## What changed from Iteration 4

| | Iteration 4 | Iteration 5 |
|---|---|---|
| Image registry | GitHub Container Registry | **GCP Artifact Registry** |
| Deployment target | Docker Compose | **GKE Autopilot** |
| Database | Local Docker Postgres | **Cloud SQL Postgres 15 (managed)** |
| DB authentication | Password in `.env` | **Workload Identity + Cloud SQL Auth Proxy** |
| Scaling | Fixed 1 replica | **HPA: 2–10 pods** |
| Secrets management | `.env` file | **GCP Secret Manager** |
| CI/CD deploy step | Placeholder echo | **Full GKE rollout with auto-rollback** |
| GCP auth in CI | Service account key | **Keyless Workload Identity Federation** |

---

## Part of the RAG Pipeline series

| Iteration | Repo | Focus |
|---|---|---|
| 1 | `rag-core-pipeline` | LangChain, Groq, PGVector, HuggingFace |
| 2 | `rag-agentic-pipeline` | LangGraph agents, query rewriting, grading |
| 3 | `rag-hybrid-retrieval` | BGE embeddings, BM25, RRF, re-ranking |
| 4 | `rag-api-service` | FastAPI, Docker, GitHub Actions CI/CD |
| **5** | **`rag-gcp-deployment`** | **GKE, Cloud SQL, Artifact Registry, Kubernetes** |
| 6 | `rag-production-monitoring` | LangSmith, Prometheus, Grafana, RAGAS |