param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('dev', 'test', 'prod')]
    [string]$Environment
)

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Deploying Digital Twin to: $Environment" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Verify environment variables
if (-not $env:AWS_ACCOUNT_ID) {
    throw "AWS_ACCOUNT_ID environment variable is not set"
}

if (-not $env:DEFAULT_AWS_REGION) {
    throw "DEFAULT_AWS_REGION environment variable is not set"
}

Write-Host "AWS Account ID: $env:AWS_ACCOUNT_ID" -ForegroundColor Yellow
Write-Host "AWS Region: $env:DEFAULT_AWS_REGION" -ForegroundColor Yellow
Write-Host ""

# ============================================
# STEP 1: Build Backend Lambda Package
# ============================================
Write-Host "Step 1: Building Lambda deployment package..." -ForegroundColor Green
Write-Host ""

Set-Location -Path "backend"

try {
    # Create deployment package directory
    if (Test-Path "package") {
        Remove-Item -Recurse -Force "package"
    }
    New-Item -ItemType Directory -Path "package" | Out-Null
    
    # Install Python dependencies
    if (Test-Path "requirements.txt") {
        Write-Host "Installing Python dependencies..." -ForegroundColor Cyan
        pip install -r requirements.txt -t ./package --quiet
    }
    
    # Copy Lambda function code
    Write-Host "Copying Lambda function code..." -ForegroundColor Cyan
    Copy-Item -Path "*.py" -Destination "package/" -Force -ErrorAction SilentlyContinue
    
    # Create deployment zip
    Write-Host "Creating deployment package..." -ForegroundColor Cyan
    Set-Location -Path "package"
    
    if (Test-Path "../lambda-deployment.zip") {
        Remove-Item "../lambda-deployment.zip" -Force
    }
    
    Compress-Archive -Path "*" -DestinationPath "../lambda-deployment.zip" -CompressionLevel Optimal
    
    Set-Location -Path ".."
    
    $zipSize = (Get-Item "lambda-deployment.zip").Length / 1MB
    Write-Host "✓ Created lambda-deployment.zip ($([math]::Round($zipSize, 2)) MB)" -ForegroundColor Green
    Write-Host ""
    
}
catch {
    Write-Host "❌ Failed to build Lambda package: $_" -ForegroundColor Red
    Set-Location -Path ".."
    exit 1
}

Set-Location -Path ".."

# ============================================
# STEP 2: Deploy Infrastructure with Terraform
# ============================================
Write-Host "Step 2: Deploying infrastructure with Terraform..." -ForegroundColor Green
Write-Host ""

Set-Location -Path "terraform"

try {
    # Get AWS Account ID and Region for backend configuration
    Write-Host "Configuring Terraform backend..." -ForegroundColor Cyan
    $awsAccountId = aws sts get-caller-identity --query Account --output text
    $awsRegion = $env:DEFAULT_AWS_REGION
    
    Write-Host "  Backend bucket: twin-terraform-state-$awsAccountId" -ForegroundColor Gray
    Write-Host "  State key: $Environment/terraform.tfstate" -ForegroundColor Gray
    Write-Host "  Region: $awsRegion" -ForegroundColor Gray
    Write-Host ""
    
    # Initialize Terraform with S3 backend
    Write-Host "Initializing Terraform with S3 backend..." -ForegroundColor Cyan
    
    terraform init -input=false `
        -backend-config="bucket=twin-terraform-state-$awsAccountId" `
        -backend-config="key=$Environment/terraform.tfstate" `
        -backend-config="region=$awsRegion" `
        -backend-config="dynamodb_table=twin-terraform-locks" `
        -backend-config="encrypt=true"
    
    if ($LASTEXITCODE -ne 0) {
        throw "Terraform init failed"
    }
    Write-Host "✓ Terraform initialized" -ForegroundColor Green
    Write-Host ""
    
    # Select or create workspace
    Write-Host "Setting up workspace: $Environment" -ForegroundColor Cyan
    terraform workspace select $Environment 2>&1 | Out-Null
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Workspace doesn't exist. Creating..." -ForegroundColor Yellow
        terraform workspace new $Environment
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create workspace"
        }
    }
    
    Write-Host "✓ Workspace '$Environment' selected" -ForegroundColor Green
    Write-Host ""
    
    # Plan infrastructure changes
    Write-Host "Planning infrastructure changes..." -ForegroundColor Cyan
    terraform plan -out=tfplan -input=false
    
    if ($LASTEXITCODE -ne 0) {
        throw "Terraform plan failed"
    }
    Write-Host "✓ Plan created" -ForegroundColor Green
    Write-Host ""
    
    # Apply infrastructure changes
    Write-Host "Applying infrastructure changes..." -ForegroundColor Cyan
    Write-Host "  This may take several minutes..." -ForegroundColor Yellow
    Write-Host ""
    
    terraform apply -auto-approve -input=false tfplan
    
    if ($LASTEXITCODE -ne 0) {
        throw "Terraform apply failed"
    }
    
    Write-Host ""
    Write-Host "✓ Infrastructure deployment complete!" -ForegroundColor Green
    Write-Host ""
    
    # Get outputs
    Write-Host "Getting deployment outputs..." -ForegroundColor Cyan
    $frontendBucket = terraform output -raw s3_frontend_bucket 2>$null
    $apiUrl = terraform output -raw api_gateway_url 2>$null
    $cloudfrontUrl = terraform output -raw cloudfront_url 2>$null
    
    Write-Host "✓ Outputs retrieved" -ForegroundColor Green
    Write-Host ""
    
}
catch {
    Write-Host "❌ Infrastructure deployment failed: $_" -ForegroundColor Red
    Set-Location -Path ".."
    exit 1
}

Set-Location -Path ".."

# ============================================
# STEP 3: Build and Deploy Frontend
# ============================================
Write-Host "Step 3: Building and deploying frontend..." -ForegroundColor Green
Write-Host ""

if ($frontendBucket -and $frontendBucket -ne "" -and $frontendBucket -ne "null") {
    Set-Location -Path "frontend"
    
    try {
        # Install dependencies
        Write-Host "Installing npm dependencies..." -ForegroundColor Cyan
        npm ci --quiet
        
        if ($LASTEXITCODE -ne 0) {
            throw "npm install failed"
        }
        Write-Host "✓ Dependencies installed" -ForegroundColor Green
        Write-Host ""
        
        # Build React application
        Write-Host "Building React application..." -ForegroundColor Cyan
        
        # Set environment variables for build
        $env:REACT_APP_API_URL = $apiUrl
        $env:REACT_APP_ENVIRONMENT = $Environment
        
        npm run build
        
        if ($LASTEXITCODE -ne 0) {
            throw "npm build failed"
        }
        Write-Host "✓ Build complete" -ForegroundColor Green
        Write-Host ""
        
        # Deploy to S3
        Write-Host "Deploying to S3: $frontendBucket" -ForegroundColor Cyan
        aws s3 sync build/ "s3://$frontendBucket" --delete
        
        if ($LASTEXITCODE -ne 0) {
            throw "S3 sync failed"
        }
        Write-Host "✓ Frontend deployed to S3" -ForegroundColor Green
        Write-Host ""
        
        # Invalidate CloudFront cache (if CloudFront exists)
        if ($cloudfrontUrl -and $cloudfrontUrl -ne "" -and $cloudfrontUrl -ne "null") {
            Write-Host "Invalidating CloudFront cache..." -ForegroundColor Cyan
            
            $distributionId = aws cloudfront list-distributions `
                --query "DistributionList.Items[?Origins.Items[?DomainName=='$frontendBucket.s3-website-$($env:DEFAULT_AWS_REGION).amazonaws.com']].Id | [0]" `
                --output text
            
            if ($distributionId -and $distributionId -ne "None" -and $distributionId -ne "") {
                aws cloudfront create-invalidation `
                    --distribution-id $distributionId `
                    --paths "/*" | Out-Null
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "✓ CloudFront cache invalidated" -ForegroundColor Green
                }
                else {
                    Write-Host "⚠ Warning: CloudFront invalidation failed" -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "⚠ No CloudFront distribution found" -ForegroundColor Yellow
            }
        }
        Write-Host ""
        
    }
    catch {
        Write-Host "❌ Frontend deployment failed: $_" -ForegroundColor Red
        Set-Location -Path ".."
        exit 1
    }
    
    Set-Location -Path ".."
}
else {
    Write-Host "⚠ Skipping frontend deployment (no S3 bucket found)" -ForegroundColor Yellow
    Write-Host ""
}

# ============================================
# DEPLOYMENT SUMMARY
# ============================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "🎉 Deployment Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Environment: $Environment" -ForegroundColor Cyan

if ($cloudfrontUrl -and $cloudfrontUrl -ne "" -and $cloudfrontUrl -ne "null") {
    Write-Host "🌐 CloudFront URL: $cloudfrontUrl" -ForegroundColor Cyan
}

if ($apiUrl -and $apiUrl -ne "" -and $apiUrl -ne "null") {
    Write-Host "📡 API Gateway URL: $apiUrl" -ForegroundColor Cyan
}

if ($frontendBucket -and $frontendBucket -ne "" -and $frontendBucket -ne "null") {
    Write-Host "🪣 S3 Bucket: $frontendBucket" -ForegroundColor Cyan
}

Write-Host ""