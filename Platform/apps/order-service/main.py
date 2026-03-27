"""
Order Service — owns everything about orders.

Key behaviour that makes this project interesting from an infrastructure
perspective: before saving a new order, this service calls user-service
to verify the user exists. This is real service-to-service communication.

In Kubernetes with Istio, that call will travel over an mTLS-encrypted
connection that neither service has to think about — Istio's sidecars
handle it transparently.

Endpoints:
  GET    /health
  GET    /orders
  GET    /orders/{id}
  POST   /orders      — requires { user_id, item, quantity }
  DELETE /orders/{id}

Environment variables:
  DATABASE_URL      — Postgres connection string for orders DB
  USER_SERVICE_URL  — base URL of the user-service
                      (used to validate that a user exists before creating an order)
"""

import os
import httpx
from fastapi import FastAPI, HTTPException, Depends
from pydantic import BaseModel
from sqlalchemy import create_engine, Column, Integer, String, DateTime
from sqlalchemy.orm import declarative_base, sessionmaker, Session
from datetime import datetime, timezone

# ── Database setup ─────────────────────────────────────────────────────────────

DATABASE_URL    = os.getenv("DATABASE_URL",     "postgresql://user:password@localhost:5433/ordersdb")
USER_SERVICE_URL = os.getenv("USER_SERVICE_URL", "http://user-service:8001")

engine       = create_engine(DATABASE_URL, pool_pre_ping=True)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base         = declarative_base()


# ── ORM model ──────────────────────────────────────────────────────────────────

class Order(Base):
    __tablename__ = "orders"

    id         = Column(Integer, primary_key=True, index=True)
    user_id    = Column(Integer, nullable=False, index=True)  # FK in spirit, not enforced at DB level
    item       = Column(String,  nullable=False)
    quantity   = Column(Integer, nullable=False, default=1)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))


# ── Pydantic schemas ───────────────────────────────────────────────────────────

class OrderCreate(BaseModel):
    user_id:  int
    item:     str
    quantity: int = 1


class OrderResponse(BaseModel):
    id:         int
    user_id:    int
    item:       str
    quantity:   int
    created_at: datetime

    class Config:
        from_attributes = True


# ── App setup ──────────────────────────────────────────────────────────────────

app = FastAPI(title="Order Service", version="1.0.0")


@app.on_event("startup")
def create_tables():
    Base.metadata.create_all(bind=engine)


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


# ── Helper: validate user exists ───────────────────────────────────────────────

def assert_user_exists(user_id: int):
    """
    Call user-service synchronously to check the user is real.

    Why this matters for the platform project:
      - In Docker Compose: this is a plain HTTP call between containers.
      - In Kubernetes with Istio: this exact same call gets intercepted by
        the Envoy sidecar proxies on both ends, wrapped in mTLS, and
        recorded in distributed traces — all without changing this code.
    """
    try:
        response = httpx.get(f"{USER_SERVICE_URL}/users/{user_id}", timeout=5.0)
    except httpx.ConnectError:
        raise HTTPException(status_code=503, detail="User service unreachable")
    except httpx.TimeoutException:
        raise HTTPException(status_code=504, detail="User service timed out")

    if response.status_code == 404:
        raise HTTPException(status_code=422, detail=f"User {user_id} does not exist")

    if response.status_code != 200:
        raise HTTPException(status_code=502, detail="User service returned an unexpected error")


# ── Routes ─────────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok", "service": "order-service"}


@app.get("/orders", response_model=list[OrderResponse])
def list_orders(db: Session = Depends(get_db)):
    return db.query(Order).all()


@app.get("/orders/{order_id}", response_model=OrderResponse)
def get_order(order_id: int, db: Session = Depends(get_db)):
    order = db.query(Order).filter(Order.id == order_id).first()
    if not order:
        raise HTTPException(status_code=404, detail=f"Order {order_id} not found")
    return order


@app.post("/orders", response_model=OrderResponse, status_code=201)
def create_order(payload: OrderCreate, db: Session = Depends(get_db)):
    # Validate user exists BEFORE writing to our own database.
    # This is the cross-service call. If user-service is down or the
    # user doesn't exist, we reject the request early and cleanly.
    assert_user_exists(payload.user_id)

    order = Order(
        user_id  = payload.user_id,
        item     = payload.item,
        quantity = payload.quantity,
    )
    db.add(order)
    db.commit()
    db.refresh(order)
    return order


@app.delete("/orders/{order_id}", status_code=204)
def delete_order(order_id: int, db: Session = Depends(get_db)):
    order = db.query(Order).filter(Order.id == order_id).first()
    if not order:
        raise HTTPException(status_code=404, detail=f"Order {order_id} not found")
    db.delete(order)
    db.commit()
