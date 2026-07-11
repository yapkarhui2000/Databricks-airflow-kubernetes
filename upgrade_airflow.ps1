# Export values for Airflow docker image
$IMAGE_NAME = "my-dags"
$IMAGE_TAG = Get-Date -Format "yyyyMMddHHmmss"
$NAMESPACE = "airflow"
$RELEASE_NAME = "airflow"

# Build the image and load it into kind
docker build --pull --tag "$IMAGE_NAME`:$IMAGE_TAG" -f cicd/Dockerfile .

kind load docker-image "$IMAGE_NAME`:$IMAGE_TAG"

# Upgrade Airflow using Helm
helm upgrade $RELEASE_NAME apache-airflow/airflow `
    --namespace $NAMESPACE `
    -f chart/values-override-with-persistence.yaml `
    --set-string "images.airflow.tag=$IMAGE_TAG" `
    --debug

# Port forward the API server
kubectl port-forward `
    "svc/$RELEASE_NAME-api-server" `
    8080:8080 `
    --namespace $NAMESPACE