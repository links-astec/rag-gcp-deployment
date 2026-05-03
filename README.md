# RAG — Iteration 5: GCP + Kubernetes

GKE Autopilot · Cloud SQL (PGVector) · Artifact Registry · Workload Identity · HPA · Rolling deploys

## What's new vs Iteration 4

| | Iteration 4 | Iteration 5 |
|---|---|---|
| Image registry | GitHub Container Registry | **GCP Artifact Registry** |
| Deployment target | Docker Compose | **GKE Autopilot** |
| Database | Local Postgres (Docker) | **Cloud SQL (Postgres 15 + pgvector)** |
| DB auth | Password in env var | **Workload Identity + Cloud SQL Auth Proxy** |
| Scaling | Fixed replicas | **HPA** (2–10 pods, CPU + memory) |
| Secrets | `.env` file | **GCP Secret Manager** |
| CI deploy step | Placeholder | **`kubectl set image` + rollout watch** |
| Rollback | Manual | **Automatic on deploy failure** |

## Architecture on GCP

```
GitHub Actions (push to main)
        │
        ▼
   [lint → test → build]
        │
        ▼
  Artifact Registry         us-central1-docker.pkg.dev/PROJECT/rag-repo/rag-api:sha-abc
        │
        ▼
  GKE Autopilot Cluster
  ┌─────────────────────────────────────────────────────┐
  │  Namespace: rag                                     │
  │                                                     │
  │  Pod (×2–10 via HPA)                                │
  │  ┌──────────────────────────────────────────────┐   │
  │  │  [cloud-sql-proxy sidecar]  localhost:5432   │   │
  │  │  [rag-api container]        port 8000        │   │
  │  └──────────────────────────────────────────────┘   │
  │                                                     │
  │  LoadBalancer Service  (Internal, port 80)          │
  │  HPA: CPU 70% / Memory 80% → scale up/down         │
  │  ConfigMap: non-secret config                       │
  │  ServiceAccount → Workload Identity (no passwords)  │
  └─────────────────────────────────────────────────────┘
        │                       │
        ▼                       ▼
  Cloud SQL                Secret Manager
  Postgres 15               GROQ_API_KEY
  + pgvector                rag-db-password
  + HNSW index
```

## One-time GCP setup

```bash
# Edit PROJECT_ID, REGION etc. at the top of the script first
chmod +x scripts/gcp_setup.sh
./scripts/gcp_setup.sh
```

This creates:
- Artifact Registry repository
- GKE Autopilot cluster
- Cloud SQL instance (Postgres 15, pgvector enabled)
- GCP Service Account with Cloud SQL Client + Secret Manager roles
- Workload Identity binding between GCP SA and Kubernetes SA
- GROQ_API_KEY stored in Secret Manager

## GitHub repository setup

Set these in **Settings → Secrets and variables**:

| Type | Name | Value |
|---|---|---|
| Secret | `GROQ_API_KEY` | Your Groq API key (for tests) |
| Secret | `GCP_WORKLOAD_IDENTITY_PROVIDER` | From `gcloud iam workload-identity-pools describe ...` |
| Secret | `GCP_SERVICE_ACCOUNT` | `rag-api@PROJECT_ID.iam.gserviceaccount.com` |
| Variable | `GCP_PROJECT_ID` | Your GCP project ID |
| Variable | `GCP_REGION` | `us-central1` |
| Variable | `GKE_CLUSTER` | `rag-cluster` |
| Variable | `AR_REPO` | `rag-repo` |

## CI/CD pipeline

```
push to main
     │
     ▼
  [lint]   ruff check + format
     │
     ▼
  [test]   pytest + live postgres service container
     │
     ▼
  [build]  docker buildx → Artifact Registry
     │         sha-{commit} + latest tags
     ▼
  [deploy] kubectl apply -f k8s/
           kubectl set image → new sha tag
           kubectl rollout status --timeout=300s
           auto-rollback on failure
```

## Kubernetes manifests

| File | Contents |
|---|---|
| `k8s/deployment.yaml` | Deployment with Cloud SQL proxy sidecar, resource limits, probes |
| `k8s/service.yaml` | Namespace, LoadBalancer Service, HPA, ConfigMap, ServiceAccount |

### Replace placeholders before first deploy

```bash
# In k8s/*.yaml, replace:
PROJECT_ID  →  your GCP project ID
REGION      →  us-central1 (or your region)
IMAGE_TAG   →  sha-{commit} (CI does this automatically)
```

## Manual deploy (without CI)

```bash
# Auth
gcloud container clusters get-credentials rag-cluster --region=us-central1

# Build + push
IMAGE="us-central1-docker.pkg.dev/PROJECT_ID/rag-repo/rag-api:latest"
docker build -t $IMAGE .
docker push $IMAGE

# Deploy
kubectl apply -f k8s/
kubectl set image deployment/rag-api rag-api=$IMAGE -n rag
kubectl rollout status deployment/rag-api -n rag
```

## Scaling behaviour

| Load | Pods | Trigger |
|---|---|---|
| Idle | 2 | minReplicas |
| Moderate | 2–5 | CPU > 70% |
| High | 5–10 | CPU > 70% sustained |
| Spike | 10 | maxReplicas |

Scale-up: max +2 pods per minute. Scale-down: 5-minute stabilisation window to prevent thrash.

## Local development (unchanged)

```bash
docker compose up --build          # full stack locally
python main.py serve               # dev server with hot-reload
```

## Files changed from Iteration 4

```
rag_iter5/
├── scripts/
│   └── gcp_setup.sh              NEW — one-shot GCP infrastructure provisioning
├── k8s/
│   ├── deployment.yaml           NEW — GKE Deployment + Cloud SQL proxy sidecar
│   └── service.yaml              NEW — Namespace, Service, HPA, ConfigMap, SA
├── .github/
│   └── workflows/ci.yml          UPDATED — GCP auth, Artifact Registry, GKE deploy
├── .env.example                  UPDATED — GCP vars added
└── (all src/, Dockerfile, docker-compose.yml unchanged)
```

## What's next — Iteration 6

- LangSmith tracing for every LangGraph run
- Prometheus metrics endpoint (`/metrics`)
- Grafana dashboard (latency, retrieval quality, error rate)
- Retrieval quality eval loop (RAGAS)
- GCP Cloud Logging structured log export
