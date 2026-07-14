# StackExchange Data Platform — Databricks + Airflow 3.0 + Kubernetes

An end-to-end data platform that ingests the StackExchange data dump, orchestrates ingestion with Apache Airflow 3.0 running on Kubernetes, and processes the data through a medallion (bronze → silver → gold) architecture on Databricks.

## Architecture

<img width="559" height="536" alt="Screenshot 2026-07-14 at 3 41 20 PM" src="https://github.com/user-attachments/assets/d5cda3f4-013f-4db7-9a0d-177aebdba76a" />

```

Airflow and Databricks are decoupled via **Airflow Assets**: the ingestion DAG only defines *what* data it produces (`posts_asset`, `user_asset`), and the Databricks trigger DAG is scheduled to run automatically once both assets are updated, rather than on a fixed cron.

## Tech Stack

| Layer | Tool |
|---|---|
| Orchestration | Apache Airflow 3.0 (`KubernetesExecutor`) |
| Compute / transformation | Databricks (PySpark, Delta Lake) |
| Data quality | [DQX](https://github.com/databrickslabs/dqx) (Databricks Labs) |
| Storage | AWS S3 (raw), Delta tables (bronze/silver/gold) |
| Container orchestration | Kubernetes — [Kind](https://kind.sigs.k8s.io/) for local dev |
| Deployment | Helm (official `apache-airflow/airflow` chart) |
| DAG sync | git-sync (pulls DAGs from this repo into the cluster) |
| CI/CD | GitHub Actions → AWS ECR |
| Local automation | PowerShell scripts |

## Pipeline Details

### 1. Ingestion — `dags/product_data_assets.py`
A daily Airflow asset task (`@asset.multi`) that:
- Downloads the StackExchange AI Meta `.7z` archive from archive.org
- Extracts `Posts.xml` and `Users.xml`
- Uploads both files to `s3://ai-stackexchange/raw/` via the `S3Hook`
- Emits two Airflow Assets (`posts_asset`, `user_asset`) on completion

### 2. Trigger — `dags/databricks_workflows.py`
A DAG scheduled on `posts_asset & user_asset` (runs once both are refreshed) that calls `DatabricksRunNowOperator` to kick off the Databricks job.

### 3. Bronze — `notebooks/bronze_post.ipynb`, `bronze_user.ipynb`, `bronze_post_DQX.ipynb`
- Reads the raw XML from S3 with an explicit schema, strips the leading `_` from column names, and writes to the `raw_posts` / `raw_users` Delta tables
- `bronze_post_DQX.ipynb` runs data-quality rules (null checks, future-date checks, allowed-value checks) and quarantines failing rows

### 4. Silver — `notebooks/Silver_post.ipynb`
- Splits the pipe-delimited `Tags` column into an array
- Maps numeric `PostTypeId` codes to readable labels
- Performs an incremental Delta merge/upsert into `stg_posts`, keyed on `PostId` and watermarked on `CreationDate`

### 5. Gold — `notebooks/gold_most_popular_tags.ipynb`, `gold_posts_users.ipynb`
- `marts_top_tags`: explodes tags and ranks them by post count
- `marts_post_user`: a one-big-table join of posts and users

## Infrastructure & Deployment

- **Local cluster**: [Kind](https://kind.sigs.k8s.io/) (`k8s/clusters/kind-cluster.yaml`), with a host-mounted volume for Airflow logs
- **Airflow**: deployed via the official Helm chart with `KubernetesExecutor` (`chart/values-override.yaml`, `chart/values-override-with-persistence.yaml`)
- **DAG delivery**: git-sync pulls the `dags/` folder from this repo into the cluster on each sync
- **Image**: `cicd/dockerfile` builds on `apache/airflow:3.0.2-python3.11` and installs `requirements.txt`
- **CI/CD**: `.github/workflows/my_cicd.yaml` builds the image and pushes it to AWS ECR on every push to `main`
- **Persistence**: a `PersistentVolume`/`PersistentVolumeClaim` pair backs Airflow log storage (`k8s/volumes/`)

## Prerequisites

- Docker, [Kind](https://kind.sigs.k8s.io/), `kubectl`, [Helm](https://helm.sh/)
- AWS CLI configured with ECR + S3 access
- A Databricks workspace with the target job created, and a `databricks_conn` Airflow connection
- An `aws_conn` Airflow connection for S3 access
- Python 3.11

## Getting Started

1. **Clone the repo**
   ```bash
   git clone https://github.com/yapkarhui2000/Databricks-airflow3.0-kubernetes.git
   cd Databricks-airflow3.0-kubernetes
   ```

2. **Set up credentials** — create your own `k8s/secrets/git-secrets.yaml` (git-sync credentials) and the ECR pull secret; see the [Security](#security) note below before doing this.

3. **First-time install**
   ```powershell
   ./installation_airflow.ps1
   ```
   This creates the Kind cluster, logs in to ECR, applies the k8s secrets and log volume, and installs Airflow via Helm.

4. **Access the Airflow UI**
   ```bash
   kubectl port-forward svc/airflow-api-server 8080:8080 -n airflow
   ```
   Then open `http://localhost:8080`.

5. **Enable the DAGs**: turn on `product_data_assets` and `databricks_workflows` in the UI.

### Redeploying after a DAG/code change

```powershell
./upgrade_airflow.ps1
```
Rebuilds the Docker image, loads it into Kind, and runs `helm upgrade`.

## Security

`k8s/secrets/git-secrets.yaml` is a plain Kubernetes `Secret` manifest for git-sync credentials. **Do not commit real credentials to this file.** Kubernetes `Secret` data is base64-*encoded*, not encrypted — anyone with repo access can trivially decode it. Prefer one of:
- Creating the secret imperatively: `kubectl create secret generic git-credentials --from-literal=...`
- A secrets manager (AWS Secrets Manager, External Secrets Operator, Sealed Secrets)

and add the rendered manifest to `.gitignore`.

## Project Structure

```
.
├── cicd/dockerfile              # Airflow image (3.0.2, python3.11)
├── chart/                       # Helm values for the Airflow chart
├── dags/
│   ├── product_data_assets.py   # Ingestion: archive.org → S3
│   └── databricks_workflows.py  # Triggers the Databricks job
├── notebooks/                   # Bronze / Silver / Gold Databricks notebooks
├── k8s/
│   ├── clusters/                # Kind cluster config
│   ├── secrets/                 # git-sync credentials manifest
│   └── volumes/                 # PV/PVC for Airflow logs
├── installation_airflow.ps1     # First-time cluster + Airflow setup
├── upgrade_airflow.ps1          # Rebuild image & redeploy
└── requirements.txt
```

## Data Model

| Layer | Tables |
|---|---|
| Bronze | `raw_posts`, `raw_users` |
| Silver | `stg_posts` |
| Gold | `marts_top_tags`, `marts_post_user` |
