from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import JSONResponse
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy import text
from slowapi import Limiter
from slowapi.util import get_remote_address
from slowapi.middleware import SlowAPIMiddleware
import redis.asyncio as redis
from redis.asyncio import ConnectionPool
import logging
import time
from typing import Optional

from config import get_settings

settings = get_settings()
limiter = Limiter(key_func=get_remote_address)

logger = logging.getLogger(__name__)

db_engine: Optional[create_async_engine] = None
db_session_maker: Optional[async_sessionmaker] = None
redis_pool: Optional[ConnectionPool] = None
redis_client: Optional[redis.Redis] = None


async def init_db():
    global db_engine, db_session_maker
    db_engine = create_async_engine(
        settings.database_url,
        pool_size=settings.database_pool_size,
        max_overflow=settings.database_max_overflow,
        pool_timeout=settings.database_pool_timeout,
        pool_recycle=settings.database_pool_recycle,
        echo=settings.database_echo,
    )
    db_session_maker = async_sessionmaker(
        bind=db_engine,
        class_=AsyncSession,
        expire_on_commit=False,
        autoflush=False,
    )


async def init_redis():
    global redis_pool, redis_client
    redis_pool = ConnectionPool.from_url(
        settings.valkey_url,
        max_connections=settings.valkey_max_connections,
        socket_timeout=settings.valkey_socket_timeout,
        socket_connect_timeout=settings.valkey_socket_connect_timeout,
        decode_responses=settings.valkey_decode_responses,
    )
    redis_client = redis.Redis(connection_pool=redis_pool)


async def close_db():
    global db_engine
    if db_engine:
        await db_engine.dispose()


async def close_redis():
    global redis_pool, redis_client
    if redis_client:
        await redis_client.aclose()
    if redis_pool:
        await redis_pool.disconnect()


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Starting FastAPI application...")
    await init_db()
    await init_redis()
    yield
    logger.info("Shutting down FastAPI application...")
    await close_redis()
    await close_db()


app = FastAPI(
    title="FastAPI Performance Test",
    description="Production-ready FastAPI with PostgreSQL and Valkey caching",
    version="1.0.0",
    lifespan=lifespan,
    docs_url="/docs" if settings.debug else None,
    redoc_url="/redoc" if settings.debug else None,
)

app.add_middleware(SlowAPIMiddleware)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"] if settings.debug else [],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
app.add_middleware(GZipMiddleware, minimum_size=1000)

app.state.limiter = limiter


@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    logger.error(f"Unhandled exception: {exc}", exc_info=True)
    return JSONResponse(
        status_code=500,
        content={
            "detail": "Internal server error",
            "error": str(exc) if settings.debug else None,
        },
    )


@app.get("/health")
async def health_check():
    db_status = "healthy"
    redis_status = "healthy"

    try:
        if redis_client:
            async with redis_client.pipeline() as pipe:
                pipe.ping()
                result = await pipe.execute()
                if result and result[0]:
                    redis_status = "healthy"
    except Exception as e:
        redis_status = f"unhealthy: {str(e)[:50]}"

    return {
        "status": "healthy",
        "app": settings.app_name,
        "database": db_status,
        "cache": redis_status,
        "timestamp": time.time(),
    }


@app.get("/")
async def root():
    return {"message": "FastAPI is running", "version": "1.0.0"}


@app.get("/db-test")
async def db_test():
    start = time.perf_counter()
    async with db_session_maker() as session:
        result = await session.execute(text("SELECT 1 as id, NOW() as timestamp"))
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


@app.get("/cached endpoint")
@limiter.limit("100/second")
async def cached_endpoint(request: Request, key: str = "default"):
    cache_key = f"cached:endpoint:{key}"
    cached = await redis_client.get(cache_key)

    if cached:
        import json

        data = json.loads(cached)
        data["cached"] = True
        return data

    start = time.perf_counter()
    async with db_session_maker() as session:
        result = await session.execute(text("SELECT NOW() as timestamp, 42 as answer"))
        row = result.fetchone()

    duration = time.perf_counter() - start
    data = {
        "timestamp": str(row[0]),
        "answer": row[1],
        "db_duration_ms": round(duration * 1000, 3),
        "cached": False,
    }

    import json

    await redis_client.setex(cache_key, settings.cache_default_ttl, json.dumps(data))
    return data


@app.get("/complex-query")
async def complex_query(n: int = 100):
    start = time.perf_counter()
    async with db_session_maker() as session:
        result = await session.execute(
            text(f"SELECT generate_series(1, {n}) as num, NOW() as ts")
        )
        rows = result.fetchall()
    duration = time.perf_counter() - start
    return {
        "count": len(rows),
        "duration_ms": round(duration * 1000, 3),
        "sample": [{"num": r[0], "ts": str(r[1])} for r in rows[:5]],
    }


@app.post("/bulk-insert")
async def bulk_insert(count: int = 1000):
    start = time.perf_counter()
    async with db_session_maker() as session:
        values = ", ".join([f"({i}, 'test_{i}', NOW())" for i in range(count)])
        await session.execute(
            text(
                f"INSERT INTO benchmark_table (id, data, created_at) VALUES {values} ON CONFLICT (id) DO NOTHING"
            )
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
