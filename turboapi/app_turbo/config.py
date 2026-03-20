import os
from pydantic_settings import BaseSettings
from functools import lru_cache
from typing import Literal


class Settings(BaseSettings):
    app_name: str = "TurboAPI"
    debug: bool = False
    environment: Literal["development", "staging", "production"] = "production"

    database_url: str = "postgresql+asyncpg://appuser:changeme@postgres:5432/app_db"
    database_url_sync: str = (
        "postgresql+psycopg2://appuser:changeme@postgres:5432/app_db"
    )
    database_pool_size: int = 20
    database_max_overflow: int = 10
    database_pool_timeout: int = 30
    database_pool_recycle: int = 3600
    database_echo: bool = False

    valkey_url: str = "valkey://valkey:6379/0"
    valkey_pool_size: int = 20
    valkey_socket_timeout: int = 5
    valkey_socket_connect_timeout: int = 5
    valkey_max_connections: int = 100
    valkey_decode_responses: bool = True
    cache_default_ttl: int = 300

    uvicorn_workers: int = 4
    uvicorn_host: str = "0.0.0.0"
    uvicorn_port: int = 8002
    uvicorn_timeout_keep_alive: int = 65
    uvicorn_limit_concurrency: int = 2000
    uvicorn_limit_max_requests: int = 10000
    uvicorn_access_log: bool = False

    log_level: str = "INFO"

    class Config:
        env_file = ".env"
        case_sensitive = False


@lru_cache()
def get_settings() -> Settings:
    settings = Settings()

    settings.database_url = os.getenv("DATABASE_URL", settings.database_url)
    settings.database_url_sync = os.getenv(
        "DATABASE_URL_SYNC", settings.database_url_sync
    )
    settings.valkey_url = os.getenv("VALKEY_URL", settings.valkey_url)

    settings.database_pool_size = int(
        os.getenv("DATABASE_POOL_SIZE", settings.database_pool_size)
    )
    settings.database_max_overflow = int(
        os.getenv("DATABASE_MAX_OVERFLOW", settings.database_max_overflow)
    )
    settings.cache_default_ttl = int(
        os.getenv("CACHE_DEFAULT_TTL", settings.cache_default_ttl)
    )

    settings.uvicorn_workers = int(
        os.getenv("UVICORN_WORKERS", settings.uvicorn_workers)
    )
    settings.uvicorn_host = os.getenv("UVICORN_HOST", settings.uvicorn_host)
    settings.uvicorn_port = int(os.getenv("UVICORN_PORT", settings.uvicorn_port))
    settings.uvicorn_timeout_keep_alive = int(
        os.getenv("UVICORN_TIMEOUT_KEEP_ALIVE", settings.uvicorn_timeout_keep_alive)
    )
    settings.uvicorn_limit_concurrency = int(
        os.getenv("UVICORN_LIMIT_CONCURRENCY", settings.uvicorn_limit_concurrency)
    )
    settings.uvicorn_limit_max_requests = int(
        os.getenv("UVICORN_LIMIT_MAX_REQUESTS", settings.uvicorn_limit_max_requests)
    )
    settings.uvicorn_access_log = (
        os.getenv("UVICORN_ACCESS_LOG", "false").lower() == "true"
    )

    settings.log_level = os.getenv("LOG_LEVEL", settings.log_level)
    settings.debug = os.getenv("DEBUG", "false").lower() == "true"

    return settings
