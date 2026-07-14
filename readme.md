# Databricks + Airflow 3.0 on Kubernetes

A little data platform I built to get hands-on with Airflow 3.0's new asset-based scheduling, running on Kubernetes, feeding into Databricks. The dataset is the StackExchange "AI Meta" dump — nothing fancy, just posts and users — but the point was the plumbing, not the data.

## What it does

Every day, an Airflow DAG grabs the latest StackExchange archive from archive.org, unzips it, and drops the raw XML into S3. Once both files (`Posts.xml` and `Users.xml`) land, a second DAG kicks off automatically and triggers a Databricks job. From there it's a pretty standard bronze → silver → gold setup in Databricks: land the raw data, clean it up, then build a couple of marts on top (top tags, and a posts+users table).

## Architecture
<img width="559" height="536" alt="Screenshot 2026-07-14 at 3 41 20 PM" src="https://github.com/user-attachments/assets/9af51f14-3911-4c12-ab61-603c88ce52bd" />


The Airflow → Databricks handoff uses **Airflow 3.0 Assets** instead of a cron schedule — the ingestion DAG just declares two things and the Databricks DAG is scheduled to fire once both show up. 

## Stack

- **Airflow 3.0** for orchestration, running with the `KubernetesExecutor`
- **Databricks** (PySpark + Delta Lake) for the actual transforms
- **DQX** (Databricks Labs) for some basic data quality checks on the bronze layer
- **Kubernetes** — I'm running this locally on **Kind**
- **Helm** to deploy Airflow (the official chart)
- **git-sync** so the cluster just pulls DAGs straight from this repo
- **GitHub Actions** builds the Airflow image and pushes it to **AWS ECR**
- A couple of **PowerShell scripts** to spin everything up / redeploy, since I'm on Windows

## How the pipeline actually works

**Ingestion (`dags/product_data_assets.py`)** — downloads the AI Meta `.7z` from archive.org, extracts `Posts.xml` and `Users.xml`, and uploads both to `s3://ai-stackexchange/raw/`. This is set up as an Airflow asset producer (`@asset.multi`), not a plain task.

**Trigger (`dags/databricks_workflows.py`)** — scheduled on `posts_asset & user_asset`, so it only runs once both files have actually been refreshed. Calls `DatabricksRunNowOperator` to fire the Databricks job.

**Bronze (`notebooks/bronze_post.ipynb`, `bronze_user.ipynb`)** — reads the raw XML with an explicit schema, strips off the leading underscores XML gives you, writes to `raw_posts` / `raw_users`. There's also `bronze_post_DQX.ipynb`, which runs a few DQX checks (nulls, no future dates, valid post types) and quarantines anything that fails.

**Silver (`Silver_post.ipynb`)** — splits the tags column into a proper array, maps the numeric post type codes to something readable, and does an incremental merge into `stg_posts` (keyed on `PostId`, watermarked on `CreationDate` so it's not reprocessing everything every run).

**Gold** — two marts: `marts_top_tags` (most-used tags, tag counts) and `marts_post_user` (posts joined to their owners, basically a one-big-table for analysis).

## Running it yourself

You'll need Docker, [Kind](https://kind.sigs.k8s.io/), `kubectl`, and Helm, plus AWS creds with ECR/S3 access and a Databricks workspace with the job already set up (you'll need a `databricks_conn` and `aws_conn` Airflow connection).

```bash
git clone https://github.com/yapkarhui2000/Databricks-airflow3.0-kubernetes.git
cd Databricks-airflow3.0-kubernetes
```

Set up your own secrets before doing anything else — see the note below, don't just reuse what's in `k8s/secrets/`.

First time setup:
```powershell
./installation_airflow.ps1
```
This spins up the Kind cluster, logs in to ECR, applies the k8s secrets and the log volume, and installs Airflow via Helm.

Then port-forward the API server to get to the UI:
```bash
kubectl port-forward svc/airflow-api-server 8080:8080 -n airflow
```
and open `localhost:8080`. Turn on `product_data_assets` and `databricks_workflows`.

When you change a DAG or notebook and want to redeploy:
```powershell
./upgrade_airflow.ps1
```
Rebuilds the image, loads it into Kind, and runs `helm upgrade`.

## A note on secrets

`k8s/secrets/git-secrets.yaml` is just a plain Kubernetes `Secret` manifest for git-sync's credentials — **don't put real tokens in it and commit it**. Kubernetes secrets are base64-encoded, not encrypted, so anything in there is effectively plaintext to anyone with repo access. I'd create it imperatively instead (`kubectl create secret generic git-credentials --from-literal=...`) or use an actual secrets manager, and keep the rendered file out of git.

## Layout

```
.
├── cicd/dockerfile              # Airflow image, 3.0.2 / python3.11
├── chart/                       # Helm values for Airflow
├── dags/
│   ├── product_data_assets.py   # archive.org → S3
│   └── databricks_workflows.py  # kicks off the Databricks job
├── notebooks/                   # bronze / silver / gold notebooks
├── k8s/
│   ├── clusters/                # Kind cluster config
│   ├── secrets/                 # git-sync creds (don't commit real values!)
│   └── volumes/                 # PV/PVC for Airflow logs
├── installation_airflow.ps1
├── upgrade_airflow.ps1
└── requirements.txt
```

## Tables

| Layer  | Tables |
|--------|--------|
| Bronze | `raw_posts`, `raw_users` |
| Silver | `stg_posts` |
| Gold   | `marts_top_tags`, `marts_post_user` |

## Notes to self / possible next steps

- Silver layer only covers posts right now — users could use the same incremental treatment
- No tests yet, would be good to add a couple of DQX checks on the silver/gold layer too
- Currently local-only via Kind — would need a real EKS cluster (or similar) to actually run this on a schedule long-term
