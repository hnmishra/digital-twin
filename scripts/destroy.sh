#!/bin/bash
set -e

ENVIRONMENT=${1:-}
PROJECT_NAME=${2:-twin}

if [ -z "$ENVIRONMENT" ]; then
  echo "❌ Environment is required"
  echo "Usage: $0 <dev|test|prod> [project_name]"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TERRAFORM_DIR="$ROOT_DIR/terraform"
BACKEND_DIR="$ROOT_DIR/backend"

echo "🗑️ Destroying ${PROJECT_NAME} (${ENVIRONMENT})"
echo "📍 Project root: $ROOT_DIR"

# Validate terraform directory
if [ ! -d "$TERRAFORM_DIR" ]; then
  echo "❌ Terraform directory not found: $TERRAFORM_DIR"
  exit 1
fi

cd "$TERRAFORM_DIR"

# Required env vars (same as deploy.sh)
: "${TF_STATE_BUCKET:?TF_STATE_BUCKET not set}"
: "${TF_STATE_TABLE:?TF_STATE_TABLE not set}"
: "${DEFAULT_AWS_REGION:?DEFAULT_AWS_REGION not set}"

echo "🔧 Initializing Terraform backend..."

terraform init \
  -input=false \
  -reconfigure \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=terraform.tfstate" \
  -backend-config="workspace_key_prefix=${PROJECT_NAME}" \
  -backend-config="region=${DEFAULT_AWS_REGION}" \
  -backend-config="dynamodb_table=${TF_STATE_TABLE}"

# Workspace handling
if terraform workspace list | grep -q " ${ENVIRONMENT}$"; then
  terraform workspace select "$ENVIRONMENT"
else
  echo "❌ Workspace '${ENVIRONMENT}' does not exist"
  terraform workspace list
  exit 1
fi

# Capture outputs BEFORE destroy (needed for cleanup)
echo "📦 Reading Terraform outputs..."

FRONTEND_BUCKET=$(terraform output -raw s3_frontend_bucket 2>/dev/null || true)
MEMORY_BUCKET=$(terraform output -raw memory_bucket 2>/dev/null || true)

# Ensure lambda zip exists (Terraform needs it during destroy)
LAMBDA_ZIP="$BACKEND_DIR/lambda-deployment.zip"
if [ ! -f "$LAMBDA_ZIP" ]; then
  echo "📦 Creating dummy lambda package for destroy..."
  mkdir -p "$BACKEND_DIR"
  echo "dummy" | zip -q "$LAMBDA_ZIP" -
fi

# Empty S3 buckets safely (only if Terraform created them)
echo "🧹 Emptying S3 buckets (if any)..."

for BUCKET in "$FRONTEND_BUCKET" "$MEMORY_BUCKET"; do
  if [ -n "$BUCKET" ] && aws s3 ls "s3://$BUCKET" >/dev/null 2>&1; then
    echo "  🔥 Emptying s3://$BUCKET"
    aws s3 rm "s3://$BUCKET" --recursive
  fi
done

echo "🔥 Running terraform destroy..."

if [ "$ENVIRONMENT" = "prod" ] && [ -f "prod.tfvars" ]; then
  terraform destroy \
    -var-file=prod.tfvars \
    -var="project_name=$PROJECT_NAME" \
    -var="environment=$ENVIRONMENT" \
    -auto-approve
else
  terraform destroy \
    -var="project_name=$PROJECT_NAME" \
    -var="environment=$ENVIRONMENT" \
    -auto-approve
fi

echo ""
echo "✅ Destroy complete for ${PROJECT_NAME} (${ENVIRONMENT})"
echo ""
echo "💡 Optional cleanup:"
echo "   terraform workspace select default"
echo "   terraform workspace delete $ENVIRONMENT"
