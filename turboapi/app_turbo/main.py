import asyncio
from turboapi import TurboAPI, HTTPException, Request
from turboapi.responses import JSONResponse
from turboapi.params import Query
from sqlalchemy.ext.asyncio import (
    create_async_engine,
    AsyncSession,
    async_sessionmaker,
)
from sqlalchemy import text
import redis.asyncio as redis
from redis.asyncio.sentinel import Sentinel
from redis.asyncio import ConnectionPool
import logging
import time
import json
import os
from typing import Optional

from config import get_settings

settings = get_settings()

logger = logging.getLogger(__name__)
logging.basicConfig(
    level=getattr(logging, settings.log_level.upper(), logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)

db_engine: Optional[create_async_engine] = None
db_session_maker: Optional[async_sessionmaker] = None
redis_client: Optional[redis.Redis] = None

# ─── In-process L1 cache (per-worker) ────────────────────────
_local_cache: dict[str, tuple[float, dict]] = {}
_semaphore = asyncio.Semaphore(200)


class TurboCache:
    """Two-tier cache: in-process dict (L1) + Valkey (L2)."""

    __slots__ = ("_l1", "_redis", "_ttl")

    def __init__(self, redis_client: redis.Redis, default_ttl: int = 300):
        self._l1 = _local_cache
        self._redis = redis_client
        self._ttl = default_ttl

    async def get(self, key: str) -> Optional[dict]:
        # L1
        entry = self._l1.get(key)
        if entry:
            expires, data = entry
            if time.monotonic() < expires:
                return data
            del self._l1[key]
        # L2
        raw = await self._redis.get(key)
        if raw:
            data = json.loads(raw)
            self._l1[key] = (time.monotonic() + self._ttl, data)
            return data
        return None

    async def set(self, key: str, value: dict, ttl: Optional[int] = None) -> None:
        t = ttl or self._ttl
        self._l1[key] = (time.monotonic() + t, value)
        await self._redis.setex(key, t, json.dumps(value))

    async def invalidate(self, key: str) -> None:
        self._l1.pop(key, None)
        await self._redis.delete(key)


turbo_cache: Optional[TurboCache] = None


async def init_db():
    global db_engine, db_session_maker
    db_engine = create_async_engine(
        settings.database_url,
        pool_size=settings.database_pool_size,
        max_overflow=settings.database_max_overflow,
        pool_timeout=settings.database_pool_timeout,
        pool_recycle=settings.database_pool_recycle,
        pool_pre_ping=True,
        echo=settings.database_echo,
    )
    db_session_maker = async_sessionmaker(
        bind=db_engine,
        class_=AsyncSession,
        expire_on_commit=False,
        autoflush=False,
    )


async def init_redis():
    """Connect to Valkey via Sentinel (with direct fallback)."""
    global redis_client, turbo_cache
    sentinel_hosts_str = os.getenv("VALKEY_SENTINEL_HOSTS", "")
    sentinel_master = os.getenv("VALKEY_SENTINEL_MASTER", "valkey-primary")

    if sentinel_hosts_str:
        sentinels = []
        for hp in sentinel_hosts_str.split(","):
            hp = hp.strip()
            if ":" in hp:
                h, p = hp.rsplit(":", 1)
                sentinels.append((h, int(p)))
        if sentinels:
            try:
                sentinel = Sentinel(
                    sentinels,
                    socket_timeout=settings.valkey_socket_timeout,
                    socket_connect_timeout=settings.valkey_socket_connect_timeout,
                )
                redis_client = sentinel.master_for(
                    sentinel_master,
                    redis_class=redis.Redis,
                    decode_responses=settings.valkey_decode_responses,
                )
                await redis_client.ping()
                logger.info(
                    "Connected to Valkey via Sentinel (master=%s)", sentinel_master
                )
                turbo_cache = TurboCache(redis_client, settings.cache_default_ttl)
                return
            except Exception as e:
                logger.warning(
                    "Sentinel connection failed (%s), falling back to direct", e
                )

    pool = ConnectionPool.from_url(
        settings.valkey_url,
        max_connections=settings.valkey_max_connections,
        socket_timeout=settings.valkey_socket_timeout,
        socket_connect_timeout=settings.valkey_socket_connect_timeout,
        decode_responses=settings.valkey_decode_responses,
    )
    redis_client = redis.Redis(connection_pool=pool)
    turbo_cache = TurboCache(redis_client, settings.cache_default_ttl)
    logger.info("Connected to Valkey directly at %s", settings.valkey_url)


async def close_db():
    global db_engine
    if db_engine:
        await db_engine.dispose()


async def close_redis():
    global redis_client
    if redis_client:
        await redis_client.aclose()


async def startup():
    logger.info("Starting TurboAPI application ...")
    await init_db()
    await init_redis()


async def shutdown():
    logger.info("Shutting down TurboAPI application ...")
    _local_cache.clear()
    await close_redis()
    await close_db()


app = TurboAPI(
    title="TurboAPI Performance Test",
    description="Optimized TurboAPI with PostgreSQL and Valkey caching",
    version="1.0.0",
    on_startup=[startup],
    on_shutdown=[shutdown],
    docs_url="/docs" if settings.debug else None,
    redoc_url="/redoc" if settings.debug else None,
)


@app.middleware("http")
async def add_cors_headers(request, call_next):
    if settings.debug or True:
        response = await call_next(request)
        response.headers["Access-Control-Allow-Origin"] = "*"
        response.headers["Access-Control-Allow-Methods"] = "*"
        response.headers["Access-Control-Allow-Headers"] = "*"
        return response
    return await call_next(request)


@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    logger.error("Unhandled exception: %s", exc, exc_info=True)
    return JSONResponse(
        status_code=500,
        content={
            "detail": "Internal server error",
            "error": str(exc) if settings.debug else None,
        },
    )


# ─── Routes ──────────────────────────────────────────────────


@app.get("/health")
async def health_check():
    db_ok = True
    cache_ok = True
    try:
        async with db_session_maker() as session:
            await session.execute(text("SELECT 1"))
    except Exception:
        db_ok = False
    try:
        if redis_client:
            await redis_client.ping()
    except Exception:
        cache_ok = False

    status = "healthy" if (db_ok and cache_ok) else "degraded"
    return {
        "status": status,
        "app": settings.app_name,
        "database": "healthy" if db_ok else "unhealthy",
        "cache": "healthy" if cache_ok else "unhealthy",
        "timestamp": time.time(),
    }


@app.get("/")
async def root():
    return {"message": "TurboAPI is running", "version": "1.0.0"}


@app.get("/db-test")
async def db_test():
    start = time.perf_counter()
    async with db_session_maker() as session:
        result = await session.execute(text("SELECT 1 AS id, NOW() AS ts"))
        row = result.fetchone()
    duration = time.perf_counter() - start
    return {
        "success": True,
        "duration_ms": round(duration * 1000, 3),
        "data": {"id": row[0], "timestamp": str(row[1])},
    }


@app.get("/cache-test")
async def cache_test():
    start = time.perf_counter()
    key = "test:cache:ping"
    await redis_client.set(key, "pong", ex=60)
    value = await redis_client.get(key)
    duration = time.perf_counter() - start
    return {
        "success": value == "pong",
        "duration_ms": round(duration * 1000, 3),
        "value": value,
    }


@app.get("/cached-endpoint")
async def cached_endpoint(request: Request):
    key = request.query_params.get("key", "default")
    cache_key = f"turbo:cached:{key}"
    cached = await turbo_cache.get(cache_key)

    if cached:
        cached["cached"] = True
        return cached

    start = time.perf_counter()
    async with _semaphore:
        async with db_session_maker() as session:
            result = await session.execute(text("SELECT NOW() AS ts, 42 AS answer"))
            row = result.fetchone()
    duration = time.perf_counter() - start

    data = {
        "timestamp": str(row[0]),
        "answer": row[1],
        "db_duration_ms": round(duration * 1000, 3),
        "cached": False,
    }
    await turbo_cache.set(cache_key, data)
    return data


@app.get("/complex-query")
async def complex_query(n=Query(default=100, ge=1, le=10000)):
    n = int(n)
    start = time.perf_counter()
    async with db_session_maker() as session:
        result = await session.execute(
            text("SELECT gs, NOW() AS ts FROM generate_series(1, :n) AS gs"),
            {"n": n},
        )
        rows = result.fetchall()
    duration = time.perf_counter() - start
    return {
        "count": len(rows),
        "duration_ms": round(duration * 1000, 3),
        "sample": [{"num": r[0], "ts": str(r[1])} for r in rows[:5]],
    }


@app.post("/bulk-insert")
async def bulk_insert(request: Request):
    count = int(request.query_params.get("count", 1000))
    if count < 1 or count > 50000:
        raise HTTPException(status_code=400, detail="count must be between 1 and 50000")
    start = time.perf_counter()
    async with db_session_maker() as session:
        await session.execute(
            text(
                "INSERT INTO benchmark_table (data, created_at) "
                "SELECT 'bench_' || gs, NOW() "
                "FROM generate_series(1, :cnt) AS gs "
                "ON CONFLICT DO NOTHING"
            ),
            {"cnt": count},
        )
        await session.commit()
    duration = time.perf_counter() - start
    return {"inserted": count, "duration_ms": round(duration * 1000, 3)}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "main:app",
        host=settings.uvicorn_host,
        port=settings.uvicorn_port,
        workers=settings.uvicorn_workers,
        timeout_keep_alive=settings.uvicorn_timeout_keep_alive,
        limit_concurrency=settings.uvicorn_limit_concurrency,
        limit_max_requests=settings.uvicorn_limit_max_requests,
        access_log=False,
    )
