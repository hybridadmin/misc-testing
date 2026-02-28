import json
import logging
from typing import Any

from redis.asyncio import ConnectionPool, Redis

from app.config import get_settings

logger = logging.getLogger(__name__)

_pool: ConnectionPool | None = None


async def init_cache() -> None:
    """Create the shared connection pool."""
    global _pool
    settings = get_settings()
    _pool = ConnectionPool.from_url(
        settings.cache_url,
        max_connections=20,
        decode_responses=True,
        socket_connect_timeout=5,
        socket_timeout=5,
        retry_on_timeout=True,
    )
    # Verify connectivity
    async with Redis(connection_pool=_pool) as r:
        await r.ping()
    logger.info("Valkey connection pool initialised")


async def close_cache() -> None:
    """Gracefully shut down the pool."""
    global _pool
    if _pool is not None:
        await _pool.aclose()
        _pool = None
        logger.info("Valkey connection pool closed")


def _get_redis() -> Redis:
    """Return a Redis client bound to the shared pool."""
    if _pool is None:
        raise RuntimeError("Cache not initialised — call init_cache() first")
    return Redis(connection_pool=_pool)


async def cache_get(key: str) -> Any | None:
    """Fetch a JSON-serialised value from cache. Returns None on miss or error."""
    try:
        async with _get_redis() as r:
            raw = await r.get(key)
            if raw is not None:
                return json.loads(raw)
    except Exception:
        logger.warning("cache_get failed for key=%s", key, exc_info=True)
    return None


async def cache_set(key: str, value: Any, ttl: int | None = None) -> None:
    """Store a JSON-serialised value in cache."""
    if ttl is None:
        ttl = get_settings().cache_ttl
    try:
        async with _get_redis() as r:
            await r.set(key, json.dumps(value, default=str), ex=ttl)
    except Exception:
        logger.warning("cache_set failed for key=%s", key, exc_info=True)


async def cache_delete(key: str) -> None:
    """Delete a single key."""
    try:
        async with _get_redis() as r:
            await r.delete(key)
    except Exception:
        logger.warning("cache_delete failed for key=%s", key, exc_info=True)


async def cache_delete_pattern(pattern: str) -> None:
    """Delete all keys matching a glob pattern (e.g. 'items:*')."""
    try:
        async with _get_redis() as r:
            cursor = None
            while cursor != 0:
                cursor, keys = await r.scan(
                    cursor=cursor or 0, match=pattern, count=100
                )
                if keys:
                    await r.delete(*keys)
    except Exception:
        logger.warning(
            "cache_delete_pattern failed for pattern=%s", pattern, exc_info=True
        )
