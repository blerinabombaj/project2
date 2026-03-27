Break and repair exercises
Level 1 — Getting comfortable (do these first)
1. Kill a pod and watch it recover
bashkubectl delete pod -n dev -l app=user-service
kubectl get pods -n dev -w   # watch it restart
Question to answer: why did it come back? What would happen if you deleted the Deployment instead?
2. Trigger a Kyverno block
Try deploying a pod as root:
bashkubectl run root-test --image=nginx -n dev
Read the error. Now fix it by adding the correct securityContext and making it pass.
3. Break the cross-service call
Scale order-service to 0:
bashkubectl scale deployment order-service --replicas=0 -n dev
Now try to create an order through the API. What error do you get? What HTTP status code? Is that the right behaviour? Scale it back and watch recovery.
4. Push a bad image tag
Manually edit helm/api-gateway/values-dev.yaml and set tag: doesnotexist. Commit and push. Watch ArgoCD try to sync. Watch the pod fail with ImagePullBackOff. Roll it back by reverting the commit.

Level 2 — Pipeline and deployment
5. Introduce a lint failure
Add intentionally broken Python to any service:
pythondef broken(
x = 1
```
Push to a feature branch. Watch the pipeline fail at lint. Fix it and watch it pass.

**6. Introduce a CVE and watch Trivy block it**
In any `requirements.txt`, pin an old vulnerable package:
```
flask==0.12.0   # has known CVEs
Push to main. Watch the Trivy job fail. Check the GitHub Security tab for the full report. Update to a safe version and re-push.
7. Simulate a bad deploy with rollback
Deploy a version that crashes on startup. Add this to user-service/main.py:
pythonraise RuntimeError("simulated crash")
Push it. Watch the pipeline deploy it. Watch the pods enter CrashLoopBackOff. Watch ArgoCD show degraded health. Roll back by reverting the commit — observe pods recover with zero intervention.
8. Break ArgoCD self-heal
Manually delete a Kubernetes Service:
bashkubectl delete svc user-service -n dev
Do nothing. Wait 3 minutes. Watch ArgoCD recreate it automatically. This is drift detection working.

Level 3 — Infrastructure
9. Corrupt Terraform state (safely)
Create a resource manually in AWS (e.g. an S3 bucket with the same name Terraform manages). Run terraform plan. See how Terraform reacts to drift. Then run terraform refresh and terraform apply to reconcile. Never do this in prod — but understanding what happens is critical.
10. Destroy and rebuild the cluster from scratch
bashterraform destroy
terraform apply
Then reinstall everything: Kyverno, Istio, ArgoCD, app-of-apps. Time yourself. First time will take 2 hours. Second time 30 minutes. Third time 15 minutes. The goal is to reach a point where you can rebuild the entire platform from a fresh AWS account using only your git repo and SETUP.md.
11. Lock the Terraform state
Run terraform apply in one terminal. While it's running, open a second terminal and run terraform apply again. Watch the lock error. Find the lock ID and practice force-unlocking it:
bashterraform force-unlock LOCK_ID
Understand why this is dangerous and when it's safe.

Level 4 — Istio and networking
12. Watch mTLS in action
Deploy a pod without the Istio sidecar (in a namespace without the label):
bashkubectl create namespace no-mesh
kubectl run test --image=curlimages/curl -n no-mesh -- sleep 3600
kubectl exec -it test -n no-mesh -- curl http://user-service.dev.svc.cluster.local:8001/health
Watch it fail with a connection error. This is STRICT mTLS rejecting the plain HTTP connection. Now understand why.
13. Run a canary deployment end to end

Deploy a new version of user-service with a visible change (change the health endpoint to return "version": "v2")
Label the new pods version: canary
Change VirtualService weights to 90/10
Write a loop that hits the endpoint 100 times and count v1 vs v2 responses
Gradually shift to 100% canary
Decommission the stable deployment

bashfor i in $(seq 1 100); do
  curl -s http://localhost:8000/health | grep version
done | sort | uniq -c
14. Trigger the circuit breaker
Make user-service return 500 errors intentionally. Watch Istio's outlier detection eject the pod from the load balancer. Check the Envoy stats:
bashkubectl exec deployment/order-service -n dev -c istio-proxy -- \
  curl localhost:15000/stats | grep outlier

Level 5 — Hard, realistic scenarios
15. Simulate a database migration gone wrong
Add a new required column to the User model in user-service. Deploy it without migrating the database first. Watch it crash. Understand why database migrations must happen before code deploys. Implement the fix: migrate first, deploy second (expand/contract pattern).
16. Resource exhaustion
Remove resource limits from a deployment (bypassing Kyverno by setting Audit mode temporarily). Deploy a memory leak:
python# add to any endpoint
leak = []
while True:
    leak.append(' ' * 1024 * 1024)  # allocate 1MB per loop
Watch the pod get OOMKilled. Watch Kubernetes restart it. Watch it get OOMKilled again. Re-enable limits. Understand why limits exist.
17. Secret rotation
Change the database password in AWS Secrets Manager. Watch the services fail to connect. Understand the External Secrets Operator refresh cycle. Force a refresh:
bashkubectl annotate externalsecret user-service-secret \
  force-sync=$(date +%s) -n dev
Watch pods restart with the new secret.
18. Node failure simulation
Cordon a node (mark it unschedulable) and then drain it:
bashkubectl cordon NODE_NAME
kubectl drain NODE_NAME --ignore-daemonsets --delete-emptydir-data
Watch pods evacuate to the other node. Watch the cluster continue serving traffic with one node. Uncordon it and watch pods redistribute.

Level 6 — The ones that will actually teach you the most
19. Write a postmortem
After any exercise where something broke, write a 1-page postmortem in this format:

What happened (timeline)
Root cause
How it was detected
How it was fixed
What would prevent it next time

This is the most underrated skill in DevOps. Every senior engineer has written dozens of these.
20. Onboard a fourth service
Add a completely new service — notification-service — that sends an email when an order is created. You have to:

Write the FastAPI app
Add it to docker-compose
Create the Helm chart
Add it to the CI matrix
Create an ArgoCD Application for it
Write a Kyverno policy that only this service can access the email provider's secret
Add an Istio AuthorizationPolicy so only order-service can call notification-service

If you can do this end to end without help, you have genuinely internalised the project. That's the real test.

The exercises in Level 5 and 6 are the ones that show up as interview stories. "Tell me about a time a deployment went wrong" — exercise 7. "How do you handle database migrations with zero downtime" — exercise 15. "Walk me through a canary deployment" — exercise 13. The project gives you the infrastructure. These exercises give you the experience.