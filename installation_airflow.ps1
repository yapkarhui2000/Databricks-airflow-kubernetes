# Install airflow
kind delete cluster --name kind
kind create cluster --image kindest/node:v1.29.4 --config k8s/clusters/kind-cluster.yaml

# Add airflow to Helm repo
helm repo add apache-airflow https://airflow.apache.org
helm repo update

helm show values apache-airflow/airflow > chart/values-example.yaml

#type powershell if using cmd
# Export values for Airflow docker image
$IMAGE_NAME = "my-dags"
$IMAGE_TAG = Get-Date -Format "yyyyMMddHHmmss"
$NAMESPACE = "airflow"
$RELEASE_NAME = "airflow"

# Build image and load into kind
docker build --pull --tag "${IMAGE_NAME}:${IMAGE_TAG}" -f cicd/Dockerfile .

kind load docker-image "${IMAGE_NAME}:${IMAGE_TAG}"

# Create namespace
kubectl create namespace $NAMESPACE

# Apply Kubernetes secrets
kubectl apply -f k8s/secrets/git-secrets.yaml

kubectl apply -f k8s/volumes/airflow-logs-pv.yaml
kubectl apply -f k8s/volumes/airflow-logs-pvc.yaml

# Install Airflow using Helm
helm install $RELEASE_NAME apache-airflow/airflow `
    --namespace $NAMESPACE `
    -f chart/values-override-with-persistence.yaml `
    --set-string "images.airflow.tag=$IMAGE_TAG" `
    --debug

# Port forward API server
kubectl port-forward svc/$RELEASE_NAME-api-server 8080:8080 --namespace $NAMESPACE