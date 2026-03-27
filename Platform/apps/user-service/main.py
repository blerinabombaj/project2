"""
User Service — owns everything about users.

This is a standalone service. It knows nothing about orders.
It has its own Postgres database (users-db), and no other service
is allowed to write directly to that database — they must go through
this service's API. This boundary is what makes it a 'microservice'.

Endpoints:
  GET    /health
  GET    /users
  GET    /users/{id}
  POST   /users
  DELETE /users/{id}

Environment variables:
  DATABASE_URL — full Postgres connection string
                 e.g. postgresql://user:pass@users-db:5432/usersdb
"""

import os
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, EmailStr
from sqlalchemy import create_engine, Column, Integer, String, DateTime
from sqlalchemy.orm import declarative_base, sessionmaker
from datetime import datetime, timezone

# ── Database setup ─────────────────────────────────────────────────────────────

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://user:password@localhost:5432/usersdb")

# create_engine sets up the connection pool. The pool_pre_ping option sends a
# cheap "SELECT 1" before handing out a connection, so stale connections get
# dropped instead of causing cryptic errors mid-request.
engine = create_engine(DATABASE_URL, pool_pre_ping=True)

# Session factory — each request gets its own short-lived session (see routes below).
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

# Base class that all ORM models inherit from.
Base = declarative_base()


# ── ORM model ──────────────────────────────────────────────────────────────────

class User(Base):
    """
    Maps to the 'users' table in Postgres.
    SQLAlchemy reads this class and creates the table automatically
    on startup via Base.metadata.create_all().
    """
    __tablename__ = "users"

    id         = Column(Integer, primary_key=True, index=True)
    name       = Column(String, nullable=False)
    email      = Column(String, unique=True, nullable=False, index=True)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))


# ── Pydantic schemas ───────────────────────────────────────────────────────────
# Pydantic models define what JSON we accept (request) and return (response).
# They are separate from the ORM model on purpose — the DB shape and the API
# shape don't have to be identical, and keeping them separate makes it easy
# to add fields to one without changing the other.

class UserCreate(BaseModel):
    name:  str
    email: str      # use str instead of EmailStr to avoid email-validator dep


class UserResponse(BaseModel):
    id:         int
    name:       str
    email:      str
    created_at: datetime

    class Config:
        from_attributes = True   # allows Pydantic to read SQLAlchemy ORM objects


# ── App setup ──────────────────────────────────────────────────────────────────

app = FastAPI(title="User Service", version="1.0.0")


@app.on_event("startup")
def create_tables():
    """
    Create all tables that don't exist yet on startup.
    In production you'd use Alembic migrations instead, but for this
    project startup creation is fine.
    """
    Base.metadata.create_all(bind=engine)


def get_db():
    """
    Dependency that yields a database session, then closes it when done.
    This ensures the connection is always returned to the pool, even if
    the request raises an exception.
    """
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


# ── Routes ─────────────────────────────────────────────────────────────────────

from fastapi import Depends
from sqlalchemy.orm import Session


@app.get("/health")
def health():
    return {"status": "ok", "service": "user-service"}


@app.get("/users", response_model=list[UserResponse])
def list_users(db: Session = Depends(get_db)):
    return db.query(User).all()


@app.get("/users/{user_id}", response_model=UserResponse)
def get_user(user_id: int, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail=f"User {user_id} not found")
    return user


@app.post("/users", response_model=UserResponse, status_code=201)
def create_user(payload: UserCreate, db: Session = Depends(get_db)):
    # Check for duplicate email before inserting.
    existing = db.query(User).filter(User.email == payload.email).first()
    if existing:
        raise HTTPException(status_code=409, detail="Email already registered")

    user = User(name=payload.name, email=payload.email)
    db.add(user)
    db.commit()
    db.refresh(user)   # reload from DB so generated fields (id, created_at) are populated
    return user


@app.delete("/users/{user_id}", status_code=204)
def delete_user(user_id: int, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail=f"User {user_id} not found")
    db.delete(user)
    db.commit()
