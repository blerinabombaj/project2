# Helm charts + ArgoCD — how they connect

## The complete GitOps loop

```
1. Developer pushes code to main
        │
2. GitHub Actions runs: lint → Trivy scan → build → push to ECR
        │
3. CI commits new image tag to helm/api-gateway/values-dev.yaml
        │ (e.g. tag: 3a4b5c6)
        │
4. ArgoCD polls git every 3 minutes, detects the diff
        │
5. ArgoCD runs:
        helm template api-gateway ./helm/api-gateway \
          -f values.yaml \
          -f values-dev.yaml \
          --namespace dev
        │
6. ArgoCD compares rendered manifests to what's in the cluster
        │
7. ArgoCD applies the diff → rolling update begins
        │
8. Old pods terminate after new pods pass readiness probes
        │
9. Zero downtime deploy complete
```

---

## Install ArgoCD

```bash
# Create the argocd namespace and install
kubectl create namespace argocd

kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
kubectl wait deployment argocd-server \
  --namespace argocd \
  --for=condition=Available \
  --timeout=120s

# Get the initial admin password
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo

# Port-forward to access the UI
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Open https://localhost:8080
# Username: admin
# Password: (from the command above)
```

---

## Connect your GitHub repo to ArgoCD

ArgoCD needs to read your repository to detect changes.

**Option A — Public repo (simplest for learning):**
No setup needed. ArgoCD can read public repos without credentials.

**Option B — Private repo:**
```bash
# Add repo credentials via ArgoCD CLI
argocd repo add https://github.com/YOUR_USERNAME/platform \
  --username YOUR_USERNAME \
  --password YOUR_GITHUB_PAT   # GitHub: Settings → Developer settings → Personal access tokens
```

---

## Update the repo URL in Application manifests

Before applying, replace the placeholder in all ArgoCD Application files:

```bash
find gitops/argocd/ -name "*.yaml" -exec sed -i \
  's|YOUR_USERNAME|your-actual-github-username|g' {} \;
```

---

## Bootstrap: apply the App of Apps (one time only)

```bash
# This is the only thing you ever apply manually.
# After this, ArgoCD manages everything else from git.
kubectl apply -f gitops/argocd/app-of-apps.yaml

# Watch ArgoCD create the child applications
kubectl get applications -n argocd
# Expected after ~1 minute:
# NAME                  SYNC STATUS   HEALTH STATUS
# platform-dev          Synced        Healthy
# api-gateway-dev       Synced        Healthy
# user-service-dev      Synced        Healthy
# order-service-dev     Synced        Healthy
```

---

## Verify the deployment

```bash
# Check pods are running in dev namespace
kubectl get pods -n dev
# NAME                             READY   STATUS    RESTARTS
# api-gateway-xxx                  2/2     Running   0   ← 2/2 = app + Istio sidecar
# user-service-xxx                 2/2     Running   0
# order-service-xxx                2/2     Running   0

# Check services
kubectl get svc -n dev

# Test via port-forward (before Istio gateway is configured)
kubectl port-forward svc/api-gateway 8000:8000 -n dev
curl http://localhost:8000/health
```

---

## Test the GitOps loop end-to-end

```bash
# Make a trivial change to any service — add a comment to main.py
# Commit and push to main

git add apps/api-gateway/main.py
git commit -m "test: trigger CI pipeline"
git push origin main

# Watch GitHub Actions run
# https://github.com/YOUR_USERNAME/platform/actions

# After the pipeline completes (~5 minutes), watch ArgoCD sync
kubectl get applications -n argocd -w
# You should see api-gateway-dev go from Synced → OutOfSync → Synced

# Verify the new image tag was deployed
kubectl describe pod -n dev -l app=api-gateway | grep Image
# Image: YOUR_ECR/platform/api-gateway:3a4b5c6  ← the new git SHA
```

---

## Preview what Helm renders (without applying)

```bash
# See the exact Kubernetes manifests Helm would generate for dev
helm template api-gateway ./helm/api-gateway \
  -f helm/api-gateway/values.yaml \
  -f helm/api-gateway/values-dev.yaml \
  --namespace dev

# This is exactly what ArgoCD runs internally before applying.
# Run this any time you want to verify your templates are correct.
```

---

## Helm chart structure explained

```
helm/api-gateway/
├── Chart.yaml          ← chart metadata (name, version)
├── values.yaml         ← defaults for all environments
├── values-dev.yaml     ← dev overrides (CI updates image.tag here)
├── values-staging.yaml ← staging overrides
├── values-prod.yaml    ← prod overrides (+ IRSA annotations, autoscaling)
└── templates/
    ├── deployment.yaml ← the Deployment manifest with {{ }} placeholders
    └── service.yaml    ← the Service + ServiceAccount manifests
```

Helm merges values bottom-up:
  `values.yaml` → `values-dev.yaml` → final config

Any key in `values-dev.yaml` overrides the same key in `values.yaml`.
Keys not in `values-dev.yaml` fall back to `values.yaml` defaults.
