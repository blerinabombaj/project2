# CONCEPTS.md — What everything does and why

This document explains every piece of this project from scratch.
No Kubernetes experience assumed. Read this alongside the code.

---

## The big picture

Before diving into individual pieces, here is what the entire system does:

```
YOU WRITE CODE
      │
      │  git push
      ▼
┌─────────────────────────────────────────────────────┐
│  GITHUB ACTIONS (CI Pipeline)                       │
│                                                     │
│  1. lint      — is the code valid Python?           │
│  2. trivy     — does the image have known CVEs?     │
│  3. build     — package the code into a container   │
│  4. push      — upload container to ECR             │
│  5. deploy    — update a YAML file in git           │
└─────────────────────────────────────────────────────┘
                            │
                            │  git commit (new image tag)
                            ▼
┌─────────────────────────────────────────────────────┐
│  ARGOCD (GitOps engine — running in your cluster)   │
│                                                     │
│  Watches git every 3 minutes.                       │
│  Detects the changed YAML file.                     │
│  Renders Helm charts → Kubernetes manifests.        │
│  Applies the manifests to the cluster.              │
└─────────────────────────────────────────────────────┘
                            │
                            │  kubectl apply (automated)
                            ▼
┌─────────────────────────────────────────────────────┐
│  EKS CLUSTER (your Kubernetes cluster on AWS)       │
│                                                     │
│  Runs your 3 services as containers (pods).         │
│  Kyverno enforces security rules on every pod.      │
│  Istio encrypts all traffic between services.       │
└─────────────────────────────────────────────────────┘
```

Code you write → running in production, automatically, securely, with full audit trail.
That is what this entire project builds.

---

## Step 1 — The three microservices

### What they are

Three Python FastAPI applications that talk to each other:

```
Internet
   │
   ▼
api-gateway (port 8000)
   │          │
   │          │  The only service the outside world can reach.
   │          │  It does not have a database.
   │          │  It just forwards requests to the right service.
   │
   ├──────────────────────────────────┐
   │                                  │
   ▼                                  ▼
user-service (port 8001)        order-service (port 8002)
      │                                │
      │                                │  Before saving an order,
      ▼                                │  order-service calls user-service
  users-db                             │  to check the user exists.
  (Postgres)                           │
                                       ▼
                                   orders-db
                                   (Postgres)
```

### Why three services instead of one?

Each service owns its domain completely:
- Only user-service can write to users-db
- Only order-service can write to orders-db
- They communicate exclusively through HTTP APIs

This means you can deploy, scale, and update each service independently.
If user-service has a memory leak, only user-service is restarted — orders keep flowing.
In a monolith, you restart everything.

### What docker-compose does locally

Docker Compose runs all 5 containers (3 services + 2 databases) on your laptop
with a single command. It creates a private network so the services can find
each other by name (user-service, orders-db) just like they will in Kubernetes.

The key detail: user-service and order-service have no port mapping to your laptop.
You cannot curl them directly. You must go through api-gateway.
This mirrors exactly how Kubernetes Network Policies work in production.

---

## Step 2 — Terraform

### What problem it solves

Without Terraform, you'd manually click through the AWS console to create an
EKS cluster, VPC, subnets, IAM roles, ECR repos — 50+ steps, impossible to repeat
reliably, impossible to version-control, impossible to destroy cleanly.

Terraform lets you describe your infrastructure as code:
```hcl
module "eks" {
  source             = "./modules/eks"
  node_instance_type = "t3.medium"
  node_desired_count = 2
}
```
Run `terraform apply` and it creates everything. Run `terraform destroy` and it
removes everything cleanly. Run it again and you get the exact same cluster.

### What it creates

```
AWS Account
└── VPC (your private network)
    ├── Public subnets (2 AZs)  ← load balancers live here
    ├── Private subnets (2 AZs) ← your EC2 nodes live here
    │       │
    │       └── EKS Node Group
    │           ├── Node 1 (t3.medium) ← runs your pods
    │           └── Node 2 (t3.medium) ← runs your pods
    │
    └── NAT Gateway ← lets private nodes reach the internet
                       (to pull images from ECR)

ECR (Elastic Container Registry)
├── platform/api-gateway   ← stores your built Docker images
├── platform/user-service
└── platform/order-service

S3 Bucket ← stores terraform.tfstate (Terraform's memory)
DynamoDB  ← prevents two people running terraform apply at once
```

### Remote state — why it matters

Terraform tracks what it has created in a file called `terraform.tfstate`.
If this file is stored only on your laptop and your laptop dies, Terraform
loses track of everything it created. It can never manage those resources again.

Remote state stores this file in S3 instead. It also uses DynamoDB as a lock —
if you and a colleague both run `terraform apply` simultaneously, the second one
gets an error instead of silently corrupting the state file.

### Modules

A module is a reusable chunk of Terraform. Instead of writing the EKS cluster
configuration twice (once for dev, once for prod), you write it once as a module
and call it with different variables:

```
modules/eks/   ← written once, the blueprint
    │
    ├── called by dev   with node_count=1
    ├── called by staging with node_count=2
    └── called by prod  with node_count=3
```

---

## Step 3 — Terragrunt

### What problem it solves

With plain Terraform and 3 environments, you'd have:
```
terraform/
├── dev/      ← full copy of all .tf files
├── staging/  ← full copy again
└── prod/     ← full copy again
```
Every copy has the S3 backend bucket name hardcoded differently.
Change the EKS version → update 3 files. Rename the bucket → update 3 files.

With Terragrunt:
```
terragrunt/
├── terragrunt.hcl  ← S3 backend defined ONCE
├── dev/
│   └── terragrunt.hcl  ← 15 lines: just what's different in dev
├── staging/
│   └── terragrunt.hcl  ← 15 lines
└── prod/
    └── terragrunt.hcl  ← 15 lines
```

### How state isolation works

The root `terragrunt.hcl` sets the S3 key like this:
```
key = "${path_relative_to_include()}/terraform.tfstate"
```

`path_relative_to_include()` resolves to the folder name automatically:
- dev folder     → `dev/terraform.tfstate`
- staging folder → `staging/terraform.tfstate`
- prod folder    → `prod/terraform.tfstate`

Each environment gets its own state file in the same S3 bucket, with zero
overlap. Destroying dev never touches staging state.

### The one command that matters

```bash
cd infra/terragrunt
terragrunt run-all plan
```

This plans all 3 environments in parallel. In an interview, being able to
explain this — and why it's better than Terraform workspaces — is exactly
what mid-level questions are testing.

---

## Step 4 — GitHub Actions CI pipeline

### What it does on every push

```
git push to main
      │
      ▼
[Job 1: Lint] — ruff checks Python syntax (5 seconds)
      │ FAIL = pipeline stops, no build, no deploy
      │
      ▼
[Job 2: Trivy scan] — scans Docker image for CVEs (2 minutes)
      │ CRITICAL or HIGH vulnerability found = pipeline stops
      │ Runs in parallel for all 3 services
      │
      ▼
[Job 3: Build + Push] — builds image, tags with git SHA, pushes to ECR
      │ Only runs on pushes to main, not on PRs
      │
      ▼
[Job 4: Deploy] — commits new image tag to helm/SERVICE/values-dev.yaml
                  ArgoCD picks this up and deploys to the cluster
```

### Why Trivy runs before push

If you scan after pushing to ECR, the vulnerable image is already in your
registry. A developer might pull it before you act on the results.

Scanning in CI — before the push — means vulnerable images never reach
ECR at all. Clean images only.

### Why images are tagged with git SHA not "latest"

```
# BAD — "latest" is mutable, could be anything
image: platform/api-gateway:latest

# GOOD — this tag points to one exact commit forever
image: platform/api-gateway:3a4b5c6
```

With SHA tags, when a bad deployment happens you know exactly which commit
caused it. You can also roll back with certainty:
- Change the tag in values-dev.yaml back to the previous SHA
- Commit it
- ArgoCD deploys the previous version automatically

### What branch protection rules do

Without branch protection, any developer can push directly to main and bypass
all CI checks entirely. Branch protection rules make the lint and scan jobs
mandatory gates — nothing merges to main until they pass.

---

## Step 5 — Kyverno policies

### What Kyverno is

Kyverno is a security guard that sits between the Kubernetes API and your cluster.
Every time anything tries to create or update a resource (a pod, a deployment),
Kyverno intercepts it and checks your rules.

```
kubectl apply / ArgoCD sync
         │
         ▼
   Kubernetes API
         │
         ▼  ← Kyverno intercepts here (admission webhook)
      Kyverno
     /       \
  PASS        FAIL
    │            │
    ▼            ▼
resource      REQUEST REJECTED
created       error returned to caller
              nothing is created
```

This is called an admission webhook — Kyverno registers itself with Kubernetes
so it gets called before any resource is actually created.

### Policy 1 — no-root-containers

Blocks any container that runs as the root user (uid 0).

Why it matters:
```
Without this policy:
  Attacker exploits your app → gets root shell in container
  → uses container escape vulnerability → gets root on the HOST NODE
  → can access all pods on that node → full cluster compromise

With this policy:
  Attacker exploits your app → gets low-privilege shell (uid 1000)
  → container escape still possible but much harder
  → even if escaped, not root on the host
```

### Policy 2 — require-resource-limits

Blocks any container that doesn't declare CPU and memory limits.

Why it matters:
```
Without limits:
  Service A has a memory leak
  → consumes all memory on Node 1
  → Kubernetes OOMKills other pods on Node 1
  → user-service and order-service go down too
  → one broken service takes down the whole node

With limits:
  Service A hits its memory limit (256Mi)
  → only Service A's pod is OOMKilled and restarted
  → user-service and order-service keep running
  → problem is contained to the broken service
```

### Policy 3 — require-trusted-registry

Blocks any container image that doesn't come from your ECR registry.

Why it matters:
```
Without this:
  Developer runs: kubectl run test --image=random/image:latest
  → untrusted, unscanned image runs in your cluster
  → could be malware, cryptominer, backdoor

With this:
  kubectl run test --image=random/image:latest
  → BLOCKED by Kyverno before the pod is created
  → only images from YOUR_ACCOUNT.dkr.ecr.../platform/* are allowed
  → every allowed image went through Trivy scan in CI
```

---

## Step 6 — Istio service mesh

### The problem Istio solves

Without Istio, traffic between your services is plain HTTP.
Anyone who can reach the network can read the traffic.
Your services have no way to verify they're talking to who they think they are.

### How Istio works — sidecar injection

Istio injects a tiny proxy (called Envoy) as a second container into every pod.
Your app never changes. Istio intercepts all traffic transparently.

```
WITHOUT ISTIO:

  order-service                    user-service
  ┌──────────┐                     ┌──────────┐
  │  FastAPI │ ──── plain HTTP ───▶│  FastAPI │
  └──────────┘                     └──────────┘


WITH ISTIO:

  order-service pod                user-service pod
  ┌─────────────────┐              ┌─────────────────┐
  │ FastAPI │ Envoy │──── mTLS ───▶│ Envoy │ FastAPI │
  └─────────────────┘              └─────────────────┘
              ↑                          ↑
         intercepts                 intercepts
         all outbound               all inbound
         traffic                    traffic

Your FastAPI code is unchanged. Istio handles encryption automatically.
```

This is why pods show `2/2` containers in kubectl — your app + the Envoy sidecar.

### mTLS — mutual TLS

Regular HTTPS (the padlock in your browser) is one-way authentication:
the server proves its identity to the client.

mTLS is two-way: both sides prove their identity.

```
Regular TLS:
  Browser: "Who are you?"
  Server:  "I'm example.com, here's my certificate." ✓
  (browser trusts the server, connection proceeds)

mTLS between services:
  order-service: "Who are you?"
  user-service:  "I'm user-service, here's my certificate." ✓
  user-service:  "Who are YOU?"
  order-service: "I'm order-service, here's MY certificate." ✓
  (both sides verified, connection proceeds)
```

An attacker inside the network cannot impersonate user-service because
they don't have its certificate. Istio's internal CA issues and rotates
these certificates automatically — you never manage TLS certificates
for service-to-service traffic.

### PeerAuthentication — enforcing mTLS

```yaml
spec:
  mtls:
    mode: STRICT
```

STRICT means: plain HTTP between services is rejected.
Every connection must be mTLS.
If a service tries to connect without a certificate, the connection is dropped.

### DestinationRule — circuit breaker

```
Normal operation:
  requests → user-service pod 1 ✓
  requests → user-service pod 2 ✓
  requests → user-service pod 3 ✓

Pod 3 starts failing (5xx errors):

Without circuit breaker:
  requests → user-service pod 1 ✓
  requests → user-service pod 2 ✓
  requests → user-service pod 3 ✗ ERROR (keeps getting traffic)
  The bad pod keeps getting 1/3 of traffic, 1/3 of requests fail

With circuit breaker (after 5 consecutive errors):
  requests → user-service pod 1 ✓
  requests → user-service pod 2 ✓
  pod 3 is ejected for 30 seconds
  All traffic goes to healthy pods, error rate drops to 0
```

### VirtualService — canary deployments

A canary deployment lets you test a new version on a small percentage of
real traffic before rolling it out to everyone.

```
                        ┌── 90% ──▶ api-gateway (stable, version v1)
All incoming traffic ───┤
                        └── 10% ──▶ api-gateway (canary, version v2)

Istio splits traffic based on the weights in VirtualService.
You watch the error rates and latency in Grafana for the canary.

If v2 looks healthy:
  → change weights to 50/50
  → then 100% canary
  → then remove the stable deployment

If v2 looks bad:
  → change canary weight to 0%
  → all traffic instantly back to stable
  → zero downtime, no kubectl rollout undo needed
```

The rollback is a one-line change in a YAML file committed to git.
ArgoCD applies it within minutes. This is what "zero downtime rollback" means
in practice — it's not magic, it's just traffic weight = 0.

---

## Step 7 — Helm charts

### What Helm is

Helm is a package manager for Kubernetes — like apt or brew, but for K8s manifests.

Without Helm, you'd have separate Kubernetes YAML files for dev, staging, and prod
that are almost identical but have different image tags, replica counts, and resource limits.

With Helm, you write the YAML once with placeholders:
```yaml
replicas: {{ .Values.replicaCount }}   # placeholder
image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
```

And supply different values per environment:
```
values.yaml         → replicaCount: 1, tag: latest  (defaults)
values-dev.yaml     → replicaCount: 1, tag: 3a4b5c6 (CI updates this)
values-staging.yaml → replicaCount: 2, tag: 3a4b5c6
values-prod.yaml    → replicaCount: 3, tag: 3a4b5c6
```

Helm merges them: values.yaml defaults + environment overrides = final config.

### How CI and Helm connect

```
CI pipeline runs after a push to main
  └── builds image
  └── pushes to ECR tagged with git SHA "3a4b5c6"
  └── runs: sed -i "s|tag:.*|tag: 3a4b5c6|" helm/api-gateway/values-dev.yaml
  └── git commit: "deploy api-gateway 3a4b5c6 to dev [skip ci]"
  └── git push

ArgoCD sees the diff in values-dev.yaml
  └── renders: helm template api-gateway ./helm/api-gateway -f values-dev.yaml
  └── result contains: image: YOUR_ECR/platform/api-gateway:3a4b5c6
  └── applies the rendered manifests
  └── rolling update begins
  └── new pods pull image tagged 3a4b5c6 from ECR
  └── old pods terminate after new pods are healthy
```

The git commit IS the deployment record. To see every deploy, look at git log.
To roll back, revert the commit. ArgoCD applies the revert automatically.

---

## Step 8 — ArgoCD (GitOps)

### What GitOps means

GitOps = git is the single source of truth for what runs in your cluster.

```
Traditional deployment:
  Developer → runs kubectl apply → cluster changes → (no record)

GitOps deployment:
  Developer → commits to git → ArgoCD applies → cluster changes
                 ↑                                      ↓
           full audit trail                  always matches git
```

If someone manually changes something in the cluster (bad practice),
ArgoCD detects the drift and reverts it back to match git.
Git always wins.

### App of Apps pattern

Instead of applying each ArgoCD Application manifest manually, you create
one "parent" Application that points to the folder containing all the others.

```
You apply once:
  kubectl apply -f gitops/argocd/app-of-apps.yaml

ArgoCD reads gitops/argocd/ and creates:
  └── api-gateway-dev   Application (which manages helm/api-gateway in dev namespace)
  └── user-service-dev  Application (which manages helm/user-service in dev namespace)
  └── order-service-dev Application (which manages helm/order-service in dev namespace)

Adding a new service later:
  1. Add a new Application YAML to gitops/argocd/
  2. Commit and push
  3. ArgoCD detects it and creates the new Application automatically
  No manual kubectl needed ever again.
```

### selfHeal — drift detection

```yaml
syncPolicy:
  automated:
    selfHeal: true
```

What this does:

```
Developer accidentally runs:
  kubectl delete deployment api-gateway -n dev

ArgoCD detects within 3 minutes:
  "api-gateway deployment exists in git but not in cluster — drift detected"

ArgoCD automatically re-creates it:
  helm template rendered → kubectl apply → api-gateway running again

Result: manual cluster changes are automatically reverted to match git
```

This is why "git is the source of truth" isn't just a phrase — ArgoCD
actively enforces it. The cluster is always what git says it should be.

---

## How all the pieces connect — the full journey of a code change

```
1. You fix a bug in user-service/main.py
   └── git push origin main

2. GitHub Actions detects the push
   ├── ruff lints main.py (5 seconds)
   ├── docker build -t user-service:scan .
   ├── trivy image user-service:scan (checks for CVEs)
   ├── docker push YOUR_ECR/platform/user-service:a1b2c3d
   └── sed -i "s|tag:.*|tag: a1b2c3d|" helm/user-service/values-dev.yaml
       git commit "deploy user-service a1b2c3d to dev [skip ci]"
       git push

3. ArgoCD polls git, detects values-dev.yaml changed
   └── helm template user-service ./helm/user-service -f values-dev.yaml
       → renders Deployment with image: .../user-service:a1b2c3d

4. ArgoCD applies the rendered Deployment to the dev namespace
   └── Kubernetes schedules a new pod

5. Kyverno intercepts the pod creation request
   ├── checks: runAsNonRoot: true ✓
   ├── checks: resource limits set ✓
   └── checks: image from ECR ✓
   → pod is allowed

6. New pod starts in the dev namespace
   └── Istio injects Envoy sidecar (pod shows 2/2 containers)
   └── Istio issues mTLS certificate to the pod

7. Readiness probe passes (/health returns 200)
   └── Kubernetes removes the old pod
   └── New pod is now receiving traffic

8. All traffic to/from user-service is mTLS encrypted via Istio
   └── order-service → user-service call is authenticated + encrypted
   └── Circuit breaker monitors for errors

Total time from git push to new version running: ~8 minutes
Downtime: 0 seconds
```

---

## Glossary — terms you will hear in interviews

| Term | What it means in plain English |
|---|---|
| **Pod** | The smallest deployable unit in Kubernetes. Usually one container. |
| **Deployment** | A Kubernetes resource that manages pods — handles scaling, rolling updates. |
| **Service** | Gives pods a stable DNS name and IP. Pods get new IPs on restart; Services don't. |
| **Namespace** | A virtual partition inside a cluster. Dev/staging/prod are separate namespaces. |
| **Helm chart** | A template for Kubernetes manifests, with variables filled from values files. |
| **ArgoCD** | Watches a git repo and keeps the cluster in sync with it. |
| **GitOps** | Git is the source of truth for cluster state. All changes go through git. |
| **mTLS** | Both sides of a connection authenticate with certificates. Used by Istio. |
| **Sidecar** | A second container injected into your pod. Istio's Envoy proxy is a sidecar. |
| **Admission webhook** | A Kubernetes extension point that intercepts API calls. Kyverno uses this. |
| **CVE** | A known security vulnerability in a library or OS package. Trivy scans for these. |
| **ECR** | AWS's Docker image registry. Like Docker Hub but private and inside your AWS account. |
| **IRSA** | IAM Roles for Service Accounts. Lets pods assume AWS IAM roles without static credentials. |
| **Terragrunt** | A wrapper around Terraform that eliminates copy-pasting across environments. |
| **Remote state** | Storing Terraform's state file in S3 instead of locally. Survives laptop death. |
| **Canary deployment** | Sending a small % of real traffic to a new version before full rollout. |
| **Circuit breaker** | Automatically stops sending traffic to a failing pod. Prevents cascade failures. |
| **Drift** | When the cluster's actual state no longer matches what's in git. ArgoCD fixes this. |
