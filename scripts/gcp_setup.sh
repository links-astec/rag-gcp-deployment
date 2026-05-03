#!/usr/bin/env bash
# scripts/gcp_setup.sh
# ─────────────────────────────────────────────────────────────────────────────
# Provisions all GCP infrastructure for Iteration 5.
# Run once before the first deployment.
#
# Prerequisites:
#   - gcloud CLI installed and authenticated (gcloud auth login)
#   - Billing enabled on the project
#   - Edit the VARIABLES section below before running
#
# Usage:
#   chmod +x scripts/gcp_setup.sh
#   ./scripts/gcp_setup.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── VARIABLES — edit these ────────────────────────────────────────────────────
PROJECT_ID="ragproject-495216"
REGION="us-central1"
ZONE="${REGION}-a"
CLUSTER_NAME="rag-cluster"
DB_INSTANCE_NAME="rag-postgres"
DB_NAME="rag_db"
DB_USER="rag"
REPO_NAME="rag-repo"
GSA_NAME="rag-api"                          # GCP Service Account name
KSA_NAMESPACE="rag"                          # Kubernetes namespace
KSA_NAME="rag-api-sa"                        # Kubernetes Service Account name
# ─────────────────────────────────────────────────────────────────────────────

echo "==> Setting project to ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}"

# ── Enable APIs ───────────────────────────────────────────────────────────────
echo "==> Enabling required APIs..."
gcloud services enable \
    container.googleapis.com \
    sqladmin.googleapis.com \
    artifactregistry.googleapis.com \
    secretmanager.googleapis.com \
    iam.googleapis.com \
    cloudresourcemanager.googleapis.com

# ── Artifact Registry ─────────────────────────────────────────────────────────
echo "==> Creating Artifact Registry repository..."
gcloud artifacts repositories create "${REPO_NAME}" \
    --repository-format=docker \
    --location="${REGION}" \
    --description="RAG API Docker images" \
    || echo "Repository already exists, skipping."

# ── GKE Cluster ───────────────────────────────────────────────────────────────
echo "==> Creating GKE Autopilot cluster (${CLUSTER_NAME})..."
# Autopilot manages node provisioning automatically — no node pool config needed
gcloud container clusters create-auto "${CLUSTER_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    || echo "Cluster already exists, skipping."

echo "==> Fetching cluster credentials..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}"

# ── Cloud SQL (Postgres 15 + pgvector) ────────────────────────────────────────
echo "==> Creating Cloud SQL instance (${DB_INSTANCE_NAME})..."
gcloud sql instances create "${DB_INSTANCE_NAME}" \
    --database-version=POSTGRES_15 \
    --region="${REGION}" \
    --tier=db-g1-small \
    --storage-type=SSD \
    --storage-size=20GB \
    --storage-auto-increase \
    --backup-start-time=03:00 \
    --enable-point-in-time-recovery \
    --database-flags=cloudsql.enable_pgvector=on \
    || echo "Instance already exists, skipping."

echo "==> Creating database and user..."
gcloud sql databases create "${DB_NAME}" --instance="${DB_INSTANCE_NAME}" \
    || echo "Database already exists."

# Generate a random password and store in Secret Manager
DB_PASSWORD=$(openssl rand -base64 32)
echo "${DB_PASSWORD}" | gcloud secrets create rag-db-password \
    --data-file=- \
    --replication-policy=automatic \
    || echo "Secret already exists, updating..."
    echo "${DB_PASSWORD}" | gcloud secrets versions add rag-db-password --data-file=-

gcloud sql users create "${DB_USER}" \
    --instance="${DB_INSTANCE_NAME}" \
    --password="${DB_PASSWORD}" \
    || echo "User already exists."

echo "==> Applying DB schema (pgvector + HNSW)..."
gcloud sql connect "${DB_INSTANCE_NAME}" --user="${DB_USER}" --database="${DB_NAME}" \
    < init.sql || echo "Schema already applied or connect failed — run manually if needed."

# ── GCP Service Account + Workload Identity ───────────────────────────────────
echo "==> Creating GCP Service Account for Workload Identity..."
gcloud iam service-accounts create "${GSA_NAME}" \
    --display-name="RAG API Service Account" \
    || echo "Service account already exists."

GSA_EMAIL="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Grant Cloud SQL Client role
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${GSA_EMAIL}" \
    --role="roles/cloudsql.client"

# Grant Secret Manager access
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${GSA_EMAIL}" \
    --role="roles/secretmanager.secretAccessor"

# Bind GCP SA to Kubernetes SA via Workload Identity
gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
    --role="roles/iam.workloadIdentityUser" \
    --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${KSA_NAMESPACE}/${KSA_NAME}]"

# ── Store GROQ_API_KEY in Secret Manager ──────────────────────────────────────
echo ""
echo "==> Storing Groq API key in Secret Manager..."
echo "    Enter your GROQ_API_KEY (input hidden):"
read -rs GROQ_API_KEY
echo "${GROQ_API_KEY}" | gcloud secrets create rag-groq-key \
    --data-file=- \
    --replication-policy=automatic \
    || echo "${GROQ_API_KEY}" | gcloud secrets versions add rag-groq-key --data-file=-

# ── Print summary ─────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  GCP setup complete!"
echo "════════════════════════════════════════════════════════"
echo "  Project:         ${PROJECT_ID}"
echo "  Region:          ${REGION}"
echo "  GKE cluster:     ${CLUSTER_NAME}"
echo "  Cloud SQL:       ${DB_INSTANCE_NAME} (${DB_NAME})"
echo "  Artifact Reg:    ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}"
echo "  GCP SA:          ${GSA_EMAIL}"
echo ""
echo "  Next: push your image and deploy:"
echo "  IMAGE=${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/rag-api:latest"
echo "  docker build -t \$IMAGE . && docker push \$IMAGE"
echo "  kubectl apply -f k8s/"
echo "════════════════════════════════════════════════════════"
