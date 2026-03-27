# Platform — Step 1: Local microservices

Three services talking to each other, running in Docker Compose.

## Architecture

```
Your curl / browser
       │
       ▼  :8000 (only public port)
  api-gateway
  /         \
user-service  order-service   ← not reachable from outside Docker
     │               │
  users-db       orders-db    ← separate Postgres per service
```

order-service calls user-service internally when creating an order,
to verify the user exists before writing to its own database.

## Start everything

```bash
docker compose up --build
```

First run takes ~2 minutes (downloading images + pip installs).
Subsequent runs use Docker's layer cache and start in seconds.

## Test the happy path

Open a second terminal and run these in order:

### 1. Check all three services are alive

```bash
curl http://localhost:8000/health
curl http://localhost:8000/users    # should return []
curl http://localhost:8000/orders   # should return []
```

### 2. Create a user

```bash
curl -X POST http://localhost:8000/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice", "email": "alice@example.com"}'
```

Response: `{"id": 1, "name": "Alice", "email": "alice@example.com", "created_at": "..."}`

### 3. Create an order for that user

```bash
curl -X POST http://localhost:8000/orders \
  -H "Content-Type: application/json" \
  -d '{"user_id": 1, "item": "Laptop", "quantity": 1}'
```

Response: `{"id": 1, "user_id": 1, "item": "Laptop", "quantity": 1, "created_at": "..."}`

### 4. Try creating an order for a user that doesn't exist

```bash
curl -X POST http://localhost:8000/orders \
  -H "Content-Type: application/json" \
  -d '{"user_id": 999, "item": "Ghost item", "quantity": 1}'
```

Response: `422 Unprocessable Entity — User 999 does not exist`

This is the cross-service validation working. order-service called
user-service, got a 404, and rejected the request before touching its DB.

### 5. List everything

```bash
curl http://localhost:8000/users
curl http://localhost:8000/orders
```

## Interactive API docs

FastAPI generates Swagger UI automatically:

- Gateway docs: http://localhost:8000/docs
- You can run all requests from the browser there.

## Stop everything

```bash
docker compose down        # stops containers, keeps DB data
docker compose down -v     # stops containers AND wipes DB volumes (clean reset)
```

## What to notice

- `user-service` and `order-service` have no port mapping in docker-compose.yaml.
  Try `curl http://localhost:8001/users` — it will fail. You can only reach them
  via the gateway. This is the same isolation model Kubernetes Network Policies enforce.

- The `USER_SERVICE_URL` environment variable in order-service is set to
  `http://user-service:8001`. In Kubernetes this becomes
  `http://user-service.user-service.svc.cluster.local` or just
  `http://user-service:8001` within the same namespace — same pattern.

- Both databases are completely separate. There is no shared schema.
  If you delete user-service's database, orders still exist.
