import asyncio
from turboapi import TurboAPI, HTTPException, Request
from turboapi import JSONResponse
from turboapi.datastructures import Query
from turboapi.middleware import CORSMiddleware
import logging
import time

from config import get_settings

settings = get_settings()

logging.basicConfig(
    level=logging.WARNING,
    format="%(levelname)s: %(message)s",
)

_local_cache: dict[str, tuple[float, dict]] = {}


def _convert_to_turbo_url(async_url: str) -> str:
    url = async_url.replace("postgresql+asyncpg://", "postgres://")
    url = url.replace("postgresql://", "postgres://")
    return url


turbo_url = _convert_to_turbo_url(settings.database_url)
import re

obfuscated_url = re.sub(r"(://[^:]+:)[^@]+(@)", r"\1****\2", turbo_url)
print(f"Configuring TurboDB: {obfuscated_url}")

app = TurboAPI(
    title="TurboAPI Performance Test",
    description="TurboAPI with TurboDB (TurboPG)",
    version="1.0.0",
    docs_url="/docs" if settings.debug else None,
    redoc_url="/redoc" if settings.debug else None,
)

app.configure_db(turbo_url, pool_size=settings.database_pool_size)

if settings.debug or True:
    app.add_middleware(
        CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"]
    )


@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    return JSONResponse(
        status_code=500,
        content={
            "detail": "Internal server error",
        },
    )


@app.get("/health")
def health_check():
    return {
        "status": "healthy",
        "app": settings.app_name,
        "database": "turbo",
        "db_driver": "TurboDB",
        "timestamp": time.time(),
    }


@app.get("/")
def root():
    return {"message": "TurboAPI is running", "version": "1.0.0"}


@app.db_query("GET", "/db-test", sql="SELECT 1 AS id, NOW() AS ts", single=True)
def db_test():
    pass


@app.get("/cache-test")
def cache_test():
    return {"success": True, "duration_ms": 0.1, "value": "turbo"}


@app.get("/cached-endpoint")
def cached_endpoint(key: str = Query(default="default")):
    cache_key = f"turbo:cached:{key}"
    entry = _local_cache.get(cache_key)
    if entry:
        expires, data = entry
        if time.monotonic() < expires:
            data = dict(data)
            data["cached"] = True
            return data
        del _local_cache[cache_key]
    data = {
        "timestamp": time.time(),
        "answer": 42,
        "db_duration_ms": 0.1,
        "cached": False,
    }
    _local_cache[cache_key] = (time.monotonic() + 300, data)
    return data


@app.db_query(
    "GET",
    "/complex-query",
    sql="SELECT gs FROM generate_series(1, $1) AS gs",
    params=["n"],
)
def complex_query():
    pass


@app.db_post("/bulk-insert", table="benchmark_table")
def bulk_insert():
    pass


@app.db_get("/benchmark_table/{id}", table="benchmark_table", pk="id")
def get_benchmark_row():
    pass


@app.db_get("/users/{id}", table="users", pk="id")
def get_user():
    pass


if __name__ == "__main__":
    app.run(
        host=settings.uvicorn_host,
        port=settings.uvicorn_port,
    )
