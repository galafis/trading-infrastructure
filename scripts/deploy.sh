#!/bin/bash
# Trading Platform Deployment Script
# Author: Gabriel Demetrios Lafis

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
ENVIRONMENT=${1:-"staging"}
AWS_REGION=${AWS_REGION:-"us-east-1"}
CLUSTER_NAME="trading-platform-${ENVIRONMENT}"

echo -e "${GREEN}=== Trading Platform Deployment ===${NC}"
echo -e "Environment: ${YELLOW}${ENVIRONMENT}${NC}"
echo -e "AWS Region: ${YELLOW}${AWS_REGION}${NC}"
echo ""

# Check prerequisites
echo -e "${GREEN}Checking prerequisites...${NC}"
command -v terraform >/dev/null 2>&1 || { echo -e "${RED}terraform is required but not installed${NC}" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}kubectl is required but not installed${NC}" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo -e "${RED}aws cli is required but not installed${NC}" >&2; exit 1; }

# Deploy infrastructure with Terraform
echo -e "${GREEN}Deploying infrastructure with Terraform...${NC}"
cd terraform
terraform init
terraform plan -var="environment=${ENVIRONMENT}" -out=tfplan
terraform apply tfplan

# Get outputs
VPC_ID=$(terraform output -raw vpc_id)
RDS_ENDPOINT=$(terraform output -raw rds_endpoint)
REDIS_ENDPOINT=$(terraform output -raw redis_endpoint)

echo -e "${GREEN}Infrastructure deployed successfully!${NC}"
echo -e "VPC ID: ${YELLOW}${VPC_ID}${NC}"
echo -e "RDS Endpoint: ${YELLOW}${RDS_ENDPOINT}${NC}"
echo -e "Redis Endpoint: ${YELLOW}${REDIS_ENDPOINT}${NC}"

# Configure kubectl
echo -e "${GREEN}Configuring kubectl...${NC}"
aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}

# Create namespace
echo -e "${GREEN}Creating Kubernetes namespace...${NC}"
kubectl create namespace trading --dry-run=client -o yaml | kubectl apply -f -

# Deploy secrets
echo -e "${GREEN}Deploying secrets...${NC}"
kubectl create secret generic trading-secrets \
  --from-literal=database-url="postgresql://user:pass@${RDS_ENDPOINT}/trading" \
  --from-literal=redis-url="redis://${REDIS_ENDPOINT}:6379" \
  --namespace=trading \
  --dry-run=client -o yaml | kubectl apply -f -

# Deploy application
echo -e "${GREEN}Deploying application...${NC}"
cd ../kubernetes
kubectl apply -f deployment.yaml

# Wait for rollout
echo -e "${GREEN}Waiting for deployment rollout...${NC}"
kubectl rollout status deployment/trading-api -n trading --timeout=5m

# Deploy monitoring
echo -e "${GREEN}Deploying monitoring stack...${NC}"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --values ../monitoring/prometheus-values.yaml \
  --wait

# Import Grafana dashboards
echo -e "${GREEN}Importing Grafana dashboards...${NC}"
kubectl create configmap grafana-dashboard-trading \
  --from-file=../monitoring/grafana-dashboard.json \
  --namespace=monitoring \
  --dry-run=client -o yaml | kubectl apply -f -

# Get service endpoint
echo -e "${GREEN}Getting service endpoint...${NC}"
LOAD_BALANCER=$(kubectl get svc trading-api -n trading -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo -e "API Endpoint: ${YELLOW}http://${LOAD_BALANCER}${NC}"
echo -e "Grafana: ${YELLOW}http://${LOAD_BALANCER}:3000${NC}"
echo -e "Prometheus: ${YELLOW}http://${LOAD_BALANCER}:9090${NC}"
echo ""
echo -e "${GREEN}Health check:${NC}"
curl -s http://${LOAD_BALANCER}/health | jq .

echo -e "${GREEN}Deployment successful!${NC}"
