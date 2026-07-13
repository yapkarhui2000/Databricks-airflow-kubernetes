# ==========================
# Install Kind Cluster
# ==========================

kind delete cluster --name kind

kind create cluster `
    --image kindest/node:v1.29.4 `
    --config k8s/clusters/kind-cluster.yaml


# ==========================
# Add Airflow Helm Repository
# ==========================

helm repo add apache-airflow https://airflow.apache.org

helm repo update

helm show values apache-airflow/airflow > chart/values-example.yaml


# ==========================
# AWS / ECR Variables
# ==========================

$REGION = "ap-southeast-2"
$ECR_REGISTRY = "139279686689.dkr.ecr.ap-southeast-2.amazonaws.com"
$ECR_REPO = "my-dags"
$NAMESPACE = "airflow"
$RELEASE_NAME = "airflow"


# ==========================
# Login to ECR
# ==========================

aws ecr get-login-password --region $REGION `
| docker login `
    --username AWS `
    --password-stdin $ECR_REGISTRY


# ==========================
# Get Latest ECR Image Tag
# ==========================

$IMAGE_TAG = aws ecr describe-images `
    --repository-name $ECR_REPO `
    --region $REGION `
    --query "sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]" `
    --output text


if (!$IMAGE_TAG -or $IMAGE_TAG -eq "None") {
    Write-Host "No image found in ECR repository: $ECR_REPO"
    exit 1
}


Write-Host "Latest image tag: $IMAGE_TAG"


# ==========================
# Create Namespace
# ==========================

kubectl create namespace $NAMESPACE `
    --dry-run=client `
    -o yaml | kubectl apply -f -


# ==========================
# Create ECR Pull Secret
# ==========================

kubectl create secret docker-registry ecr-secret `
    --docker-server=$ECR_REGISTRY `
    --docker-username=AWS `
    --docker-password=$(aws ecr get-login-password --region $REGION) `
    --namespace $NAMESPACE `
    --dry-run=client `
    -o yaml | kubectl apply -f -



# ==========================
# Apply Kubernetes Secrets
# ==========================

kubectl apply -f k8s/secrets/git-secrets.yaml


# ==========================
# Apply Persistent Volume
# ==========================

kubectl apply -f k8s/volumes/airflow-logs-pv.yaml

kubectl apply -f k8s/volumes/airflow-logs-pvc.yaml



# ==========================
# Deploy Airflow
# ==========================

helm upgrade --install $RELEASE_NAME apache-airflow/airflow `
    --namespace $NAMESPACE `
    -f chart/values-override-with-persistence.yaml `
    --set-string "images.airflow.repository=${ECR_REGISTRY}/${ECR_REPO}" `
    --set-string "images.airflow.tag=${IMAGE_TAG}" `
    --debug



# ==========================
# Check Deployment
# ==========================

kubectl get pods -n $NAMESPACE


# ==========================
# Port Forward Airflow API
# ==========================

kubectl port-forward `
    svc/$RELEASE_NAME-api-server `
    8080:8080 `
    --namespace $NAMESPACE