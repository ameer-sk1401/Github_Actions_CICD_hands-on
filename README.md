# CI/CD with **All GitHub Actions** → AWS (CodeDeploy → EC2)

This repo shows how to do **everything from GitHub Actions**:
- **CI**: build & package the app in Actions
- **CD**: Actions assumes an **AWS IAM role (OIDC)**, uploads the artifact to **S3**, and triggers **CodeDeploy** to deploy to **EC2**

No AWS CodePipeline is used in this method.


## Architecture

    ```mermaid
    flowchart LR
      A[Push to GitHub] --> B[GitHub Actions]
      B -->|OIDC token| O[GitHub OIDC Provider]
      O -->|AssumeRoleWithWebIdentity| STS[AWS STS\n(short‑lived creds)]
      STS --> CLI[AWS CLI in Actions]
      CLI -->|upload artifact.zip| S3[(S3 artifact bucket)]
      CLI -->|create-deployment| CD[CodeDeploy App + Deployment Group]
      CD --> EC2[EC2 instance(s)\nCodeDeploy agent]
      EC2 -->|download + run hooks| S3



Repository layout

    .
    ├── src/                      # your app (Flask in our example)
    │   ├── app.py
    │   └── requirements.txt
    ├── scripts/                  # CodeDeploy lifecycle hooks
    │   ├── before_install.sh
    │   ├── after_install.sh
    │   ├── start.sh
    │   └── health_check.sh
    ├── appspec.yml               # CodeDeploy config (must be at artifact root)
    └── .github/workflows/deploy.yml

Key rule: Your artifact ZIP must have appspec.yml at the root (not nested). We fixed a “double‑zip” issue earlier by packaging correctly (see workflow below).

⸻

Prerequisites (one‑time)

1) EC2 instance + CodeDeploy agent
	•	AMI: Amazon Linux 2
	•	Security group: allow SSH (22), HTTP (80) or app port (e.g., 8000)
	•	Attach IAM instance profile (so the agent can talk to CodeDeploy + S3)

Install/enable the agent:

    sudo yum update -y
    sudo yum install -y ruby wget
    cd /home/ec2-user
    wget https://aws-codedeploy-<region>.s3.<region>.amazonaws.com/latest/install
    chmod +x ./install
    sudo ./install auto
    sudo service codedeploy-agent start
    sudo systemctl enable codedeploy-agent

If you ever see Missing credentials in /var/log/aws/codedeploy-agent/codedeploy-agent.log, attach an IAM role to the instance and restart the agent.

2) CodeDeploy app + deployment group
	•	Compute platform: EC2/On‑prem
	•	Target your instance(s) via tags or an ASG
	•	Start with AllAtOnce deployment config for a single instance

3) S3 artifact bucket
	•	Create a bucket in your region and enable versioning (good hygiene)
	•	Naming rules: all lowercase, letters/numbers/dots/hyphens only.
Secret must be just the bucket name (e.g., my-artifacts-123) — not s3://my-artifacts-123.

⸻

GitHub → AWS OIDC (no long‑lived keys)

4) Add OIDC identity provider (one‑time per account)

        IAM → Identity providers → Add provider
        	•	Type: OpenID Connect
        	•	URL: https://token.actions.githubusercontent.com
        	•	Audience: sts.amazonaws.com

5) Create the role GitHub Actions will assume

        IAM → Roles → Create role → Web identity
        	•	Provider: token.actions.githubusercontent.com
        	•	Audience: sts.amazonaws.com
        	•	Name: GitHubActionsDeployRole (example)

Trust policy (replace <ACCOUNT_ID>; repo owner/name from your repo URL):

      {
        "Version": "2012-10-17",
        "Statement": [{
          "Effect": "Allow",
          "Principal": {
            "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
          },
          "Action": "sts:AssumeRoleWithWebIdentity",
          "Condition": {
            "StringEquals": {
              "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
            },
            "StringLike": {
              "token.actions.githubusercontent.com:sub": [
                "repo:ameer-sk1401/Github_Actions_CICD_hands-on:ref:refs/heads/*",
                "repo:ameer-sk1401/Github_Actions_CICD_hands-on:ref:refs/tags/*",
                "repo:ameer-sk1401/Github_Actions_CICD_hands-on:ref:refs/pull/*"
              ]
            }
          }
        }]
      }

Once it’s working, tighten to just refs/heads/main if you want.

Permissions policy (minimum):

      {
        "Version": "2012-10-17",
        "Statement": [
          { "Sid": "Artifacts",
            "Effect": "Allow",
            "Action": ["s3:PutObject","s3:GetObject","s3:ListBucket","s3:PutObjectAcl"],
            "Resource": [
              "arn:aws:s3:::<YOUR_BUCKET>",
              "arn:aws:s3:::<YOUR_BUCKET>/*"
            ]
          },
          { "Sid": "CodeDeploy",
            "Effect": "Allow",
            "Action": [
              "codedeploy:RegisterApplicationRevision",
              "codedeploy:CreateDeployment",
              "codedeploy:Get*",
              "codedeploy:List*"
            ],
            "Resource": "*"
          }
        ]
      }

If your bucket uses a KMS CMK, also grant kms:Encrypt, kms:Decrypt, kms:GenerateDataKey on that key.

⸻

GitHub configuration

6) Secrets / Variables

        Add Repository Secrets (or Environment Secrets—if you do, your job must declare environment: "<ExactName>"):
        	•	AWS_ROLE_TO_ASSUME → arn:aws:iam::<ACCOUNT_ID>:role/GitHubActionsDeployRole
        	•	AWS_REGION → e.g., us-west-2
        	•	ARTIFACTS_BUCKET → plain bucket name (e.g., my-artifacts-123)
        	•	CD_APP → your CodeDeploy application name
        	•	CD_GROUP → your CodeDeploy deployment group

We fixed two common mistakes here:
	•	Region missing: the job didn’t have access to environment secrets → set environment: or move to repo secrets.
	•	Empty group: secret key mismatch (CD_GROUP vs CD_DG) → use one consistent name.

⸻

Workflow (CI+CD in GitHub Actions)

Create .github/workflows/deploy.yml:

      name: CI-CD (All GitHub → CodeDeploy)
      
      on:
        push:
          branches: [ "main" ]
      
      permissions:
        id-token: write
        contents: read
      
      jobs:
        build-and-deploy:
          runs-on: ubuntu-latest
          # environment: "AWS-Secrets-for Github-Actions"  # <- only if you used Environment secrets
      
          steps:
            - name: Checkout
              uses: actions/checkout@v4
      
            - name: Configure AWS credentials (OIDC)
              uses: aws-actions/configure-aws-credentials@v4
              with:
                role-to-assume: ${{ secrets.AWS_ROLE_TO_ASSUME }}
                aws-region:     ${{ secrets.AWS_REGION }}
                audience: sts.amazonaws.com
      
            # (optional) run tests here
      
            - name: Package bundle (appspec at ROOT)
              run: |
                set -e
                rm -rf bundle artifact.zip
                mkdir -p bundle
                cp -r src bundle/src
                cp -r scripts bundle/scripts
                cp appspec.yml bundle/
                (cd bundle && zip -r ../artifact.zip .)
                # prove appspec.yml is at top-level (avoids "AppSpec not found"):
                unzip -l artifact.zip | sed -n '1,60p'
      
            - name: Sanity check deploy inputs
              run: |
                for v in AWS_REGION ARTIFACTS_BUCKET CD_APP CD_GROUP; do
                  test -n "${{ secrets[$v] }}" || { echo "::error ::$v is EMPTY"; exit 1; }
                done
      
            - name: Upload artifact to S3
              run: |
                # ARTIFACTS_BUCKET must be a plain bucket name (no s3://, no trailing slash, lowercase)
                aws s3 cp artifact.zip "s3://${{ secrets.ARTIFACTS_BUCKET }}/github-only/artifact-${{ github.sha }}.zip"
      
            - name: Create CodeDeploy deployment
              run: |
                aws deploy create-deployment \
                  --application-name "${{ secrets.CD_APP }}" \
                  --deployment-group-name "${{ secrets.CD_GROUP }}" \
                  --s3-location bucket=${{ secrets.ARTIFACTS_BUCKET }},bundleType=zip,key=github-only/artifact-${{ github.sha }}.zip
      
            - name: Who am I in AWS?
              run: aws sts get-caller-identity


⸻

appspec.yml (example)

      version: 0.0
      os: linux
      files:
        - source: src/
          destination: /opt/myapp/src
      permissions:
        - object: /opt/myapp/src
          pattern: '**'
          owner: ec2-user
          group: ec2-user
      hooks:
        BeforeInstall:
          - location: scripts/before_install.sh
            runas: root
        AfterInstall:
          - location: scripts/after_install.sh
            runas: root
        ApplicationStart:
          - location: scripts/start.sh
            runas: root
        ValidateService:
          - location: scripts/health_check.sh
            runas: root

We fixed “AppSpec not found” by ensuring appspec.yml is at the root of the zip and not nested (no double‑zip).

⸻

Validate the deployment
	•	Watch Actions run → all steps green
	•	Check CodeDeploy → Deployments → Events should show hooks running
	•	On the instance:

    sudo systemctl status codedeploy-agent
    sudo journalctl -u myapp -n 100 --no-pager
    curl -fsS http://localhost:8000/health





What to learn next
	•	Blue/Green deployments with CodeDeploy + ALB
	•	Containerized flow: build to ECR, deploy to ECS (still all GitHub)
	•	GitOps alternative for Kubernetes (Argo CD)

