"""
API Gateway — the only public-facing service.

Responsibilities:
  - Accept all incoming HTTP traffic
  - Route requests to the correct downstream service
  - Return whatever the downstream service replies with

It does NOT have a database. It knows nothing about users or orders
beyond how to forward requests about them. This is intentional —
each service owns its own domain.

Environment variables:
  USER_SERVICE_URL   — base URL of the user-service  (e.g. http://user-service:8001)
  ORDER_SERVICE_URL  — base URL of the order-service (e.g. http://order-service:8002)
"""

import os
import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse

app = FastAPI(title="API Gateway", version="1.0.0")

# Read URLs from environment so we can swap them in Kubernetes without
# changing code — dev/staging/prod just set different values.
USER_SERVICE_URL  = os.getenv("USER_SERVICE_URL",  "http://user-service:8001")
ORDER_SERVICE_URL = os.getenv("ORDER_SERVICE_URL", "http://order-service:8002")


# ── Helpers ────────────────────────────────────────────────────────────────────

async def forward(method: str, url: str, **kwargs) -> JSONResponse:
    """
    Send an HTTP request to a downstream service and relay the response.
    Using httpx here because the standard `requests` library is sync-only
    and would block FastAPI's event loop.
    """
    async with httpx.AsyncClient(timeout=10.0) as client:
        try:
            response = await client.request(method, url, **kwargs)
            return JSONResponse(
                content=response.json(),
                status_code=response.status_code,
            )
        except httpx.ConnectError:
            raise HTTPException(status_code=503, detail=f"Downstream service unreachable: {url}")
        except httpx.TimeoutException:
            raise HTTPException(status_code=504, detail="Downstream service timed out")


# ── Health ─────────────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    """
    Kubernetes liveness/readiness probes will hit this endpoint.
    A 200 response means 'I am alive and ready to accept traffic'.
    """
    return {"status": "ok", "service": "api-gateway"}


# ── User routes — proxied to user-service ──────────────────────────────────────

@app.get("/users")
async def list_users():
    return await forward("GET", f"{USER_SERVICE_URL}/users")


@app.get("/users/{user_id}")
async def get_user(user_id: int):
    return await forward("GET", f"{USER_SERVICE_URL}/users/{user_id}")


@app.post("/users")
async def create_user(request: Request):
    body = await request.json()
    return await forward("POST", f"{USER_SERVICE_URL}/users", json=body)


@app.delete("/users/{user_id}")
async def delete_user(user_id: int):
    return await forward("DELETE", f"{USER_SERVICE_URL}/users/{user_id}")


# ── Order routes — proxied to order-service ────────────────────────────────────

@app.get("/orders")
async def list_orders():
    return await forward("GET", f"{ORDER_SERVICE_URL}/orders")


@app.get("/orders/{order_id}")
async def get_order(order_id: int):
    return await forward("GET", f"{ORDER_SERVICE_URL}/orders/{order_id}")


@app.post("/orders")
async def create_order(request: Request):
    body = await request.json()
    return await forward("POST", f"{ORDER_SERVICE_URL}/orders", json=body)


@app.delete("/orders/{order_id}")
async def delete_order(order_id: int):
    return await forward("DELETE", f"{ORDER_SERVICE_URL}/orders/{order_id}")
