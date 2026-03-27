# Step 5 — Kyverno policies

## What Kyverno is

Kyverno is a policy engine that sits between you and the Kubernetes API server.
Every time you (or ArgoCD, or anyone) tries to create or update a resource,
Kyverno intercepts the request and checks it against your policies.

```
kubectl apply / ArgoCD sync
         │
         ▼
  Kubernetes API server
         │
         ▼ (admission webhook)
      Kyverno
         │
    ┌────┴────┐
    │         │
  PASS       FAIL
    │         │
    ▼         ▼
 resource   request rejected
 created    error returned to caller
```

This is called an "admission webhook" — Kyverno registers itself as a
webhook with the API server, so it gets called on every create/update.

## Policies in this project

| File | What it blocks | Why |
|---|---|---|
| `no-root-containers.yaml` | Containers running as root (uid 0) | Container escape → node compromise |
| `require-resource-limits.yaml` | Containers without CPU/memory limits | Noisy neighbour, OOM kills |
| `require-trusted-registry.yaml` | Images not from your ECR | Unscanned/untrusted images |

## Install Kyverno

```bash
# Make sure kubectl is pointed at your cluster first
kubectl config current-context

# Install Kyverno via Helm
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --version 3.2.0

# Wait for Kyverno pods to be ready (~1 minute)
kubectl wait pod \
  --for=condition=Ready \
  --namespace kyverno \
  --selector=app.kubernetes.io/component=admission-controller \
  --timeout=120s

# Verify it's running
kubectl get pods -n kyverno
```

## Apply the policies

```bash
# Update the registry URL in the trusted registry policy first
sed -i 's/ACCOUNT_ID/YOUR_ACTUAL_ACCOUNT_ID/g' \
  policy/kyverno/require-trusted-registry.yaml
sed -i 's/REGION/us-east-1/g' \
  policy/kyverno/require-trusted-registry.yaml

# Apply all policies
kubectl apply -f policy/kyverno/

# Verify they were created
kubectl get clusterpolicy
```

Expected output:
```
NAME                       ADMISSION   BACKGROUND   READY   AGE
no-root-containers         true        true         True    10s
require-resource-limits    true        true         True    10s
require-trusted-registry   true        true         True    10s
```

## Test the policies are working

### Test 1 — no-root-containers

```bash
# This should be BLOCKED
kubectl run root-test \
  --image=nginx \
  --restart=Never \
  -- sh

# Expected: Error from server: admission webhook denied the request.
# Containers must not run as root.

# This should PASS
kubectl run nonroot-test \
  --image=nginx \
  --restart=Never \
  --overrides='{"spec":{"securityContext":{"runAsUser":1000,"runAsNonRoot":true}}}'
```

### Test 2 — require-resource-limits

```bash
# This should be BLOCKED (no resource limits)
kubectl run no-limits-test \
  --image=nginx \
  --restart=Never

# Expected: Error — must specify resources.requests and resources.limits
```

### Test 3 — require-trusted-registry

```bash
# This should be BLOCKED (Docker Hub image)
kubectl run dockerhub-test \
  --image=nginx:latest \
  --restart=Never \
  --namespace=dev

# Expected: Error — image not from approved registry
```

## Audit mode (for gradual rollout)

If you're adding Kyverno to an existing cluster with existing workloads,
switch policies to Audit mode first so you don't immediately break things:

```yaml
spec:
  validationFailureAction: Audit   # change from Enforce
```

Then check what would have been blocked:
```bash
kubectl get policyreport -A
kubectl describe policyreport -n dev
```

Fix violations, then switch back to Enforce.

## Interview question this answers

"How do you prevent developers from deploying insecure workloads to Kubernetes?"

Answer:
- Kyverno as an admission controller — intercepts every API request
- no-root-containers: prevents privilege escalation via container escape
- require-resource-limits: prevents resource exhaustion / noisy neighbour
- require-trusted-registry: enforces supply chain security — only CI-scanned images
- All policies as code in git — auditable, version-controlled, applied via ArgoCD
- Start with Audit mode on existing clusters, Enforce on greenfield
