# Step 6 — Istio service mesh

## Install Istio

```bash
# Download istioctl — Istio's CLI tool
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.21.0 sh -
cd istio-1.21.0
export PATH=$PWD/bin:$PATH

# Verify your cluster is ready for Istio
istioctl x precheck

# Install Istio with the default profile.
# This installs: istiod (control plane) + ingress gateway
istioctl install --set profile=default -y

# Wait for Istio control plane to be ready
kubectl wait deployment istiod \
  --namespace istio-system \
  --for=condition=Available \
  --timeout=120s

kubectl get pods -n istio-system
# Expected: istiod-xxx Running, istio-ingressgateway-xxx Running
```

## Apply the Istio config

```bash
# 1. Label namespaces for sidecar injection (do this BEFORE deploying services)
kubectl apply -f gitops/istio/namespace-labels.yaml

# 2. Enforce mTLS across the mesh
kubectl apply -f gitops/istio/peer-authentication.yaml

# 3. Apply destination rules (circuit breakers, subsets)
kubectl apply -f gitops/istio/destination-rules.yaml

# 4. Apply virtual services (routing, retries, timeouts)
kubectl apply -f gitops/istio/virtual-services.yaml

# 5. Apply the ingress gateway
kubectl apply -f gitops/istio/gateway.yaml
```

## Verify mTLS is working

```bash
# Check mTLS status across the mesh
istioctl x describe service user-service -n dev
# Should show: mTLS is STRICT

# Check that sidecars were injected into your pods
kubectl get pods -n dev
# Each pod should show 2/2 containers (your app + the Envoy sidecar)
# If you see 1/1, the namespace label wasn't applied before pod creation
# Fix: kubectl rollout restart deployment/user-service -n dev

# View the Envoy proxy config for a pod
istioctl proxy-config cluster deployment/user-service -n dev
```

## Verify the circuit breaker

```bash
# Install fortio (load testing tool)
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.21/samples/httpbin/sample-client/fortio-deploy.yaml

# Send 20 requests — all should succeed
kubectl exec deployment/fortio -n dev -- \
  fortio load -c 1 -qps 0 -n 20 \
  http://user-service:8001/health

# Now send with 10 concurrent connections — circuit breaker may trip
kubectl exec deployment/fortio -n dev -- \
  fortio load -c 10 -qps 0 -n 50 \
  http://user-service:8001/users

# Check if any requests were rejected by the circuit breaker
kubectl exec deployment/fortio -n dev -- \
  fortio load -c 10 -qps 0 -n 50 \
  http://user-service:8001/users 2>&1 | grep "Code 503"
```

## Demo: canary deployment

This is the thing that gets senior engineers excited. Here's how to do it:

```bash
# 1. Deploy the current version with label version: stable
kubectl patch deployment user-service -n dev \
  --patch '{"spec":{"template":{"metadata":{"labels":{"version":"stable"}}}}}'

# 2. Simulate deploying a new version (in reality this would be a new Helm release)
kubectl create deployment user-service-canary \
  --image=YOUR_ECR/platform/user-service:NEW_SHA \
  --namespace=dev
kubectl patch deployment user-service-canary -n dev \
  --patch '{"spec":{"template":{"metadata":{"labels":{"app":"user-service","version":"canary"}}}}}'

# 3. Split traffic: 90% stable, 10% canary
# Edit virtual-services.yaml and change the weights:
#   stable: 90
#   canary: 10
kubectl apply -f gitops/istio/virtual-services.yaml

# 4. Watch traffic distribution in Kiali (Istio's dashboard)
istioctl dashboard kiali

# 5. If canary looks healthy, shift to 50/50, then 100% canary
# 6. If canary looks bad, set canary weight: 0 — instant rollback, zero downtime
```

## Visualise the mesh

```bash
# Kiali — service mesh topology and traffic graph
istioctl dashboard kiali

# Jaeger — distributed tracing (works with your existing Tempo setup)
istioctl dashboard jaeger

# Grafana — metrics (works with your existing Loki/Grafana setup)
istioctl dashboard grafana
```

---

## Interview question this answers

"Walk me through how you'd do a canary deployment with zero downtime rollback."

Answer:
1. Istio injects Envoy sidecars into every pod — all traffic flows through them
2. PeerAuthentication enforces mTLS — every service-to-service call is encrypted and authenticated
3. DestinationRules define subsets (stable/canary) by pod label
4. VirtualServices control traffic weights between subsets
5. Deploy new version pods labelled version: canary
6. Shift 10% of traffic to canary via weight change in VirtualService
7. Monitor error rates and latency in Grafana/Kiali
8. If healthy: increment weight to 50%, then 100%
9. If broken: set canary weight to 0 — all traffic back to stable instantly
10. No kubectl rollout undo needed — just a YAML change committed to git

The key differentiator: the rollback is a git commit, not a manual kubectl operation.
ArgoCD syncs it within 3 minutes, or you can trigger a manual sync for instant rollback.
