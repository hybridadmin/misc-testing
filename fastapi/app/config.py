from pydantic_settings import BaseSettings
from functools import lru_cache


class Settings(BaseSettings):
    app_name: str = "FastAPI Test App"

    # PostgreSQL (required — no defaults)
    db_user: str
    db_pass: str
    db_host: str
    db_port: int
    db_name: str

    # Valkey cache (required — no defaults)
    cache_host: str
    cache_port: int
    cache_pass: str
    cache_db: int
    cache_ttl: int = 60  # default TTL in seconds is fine as a sensible fallback

    @property
    def database_url(self) -> str:
        return (
            f"postgresql+asyncpg://{self.db_user}:{self.db_pass}"
            f"@{self.db_host}:{self.db_port}/{self.db_name}"
        )

    @property
    def cache_url(self) -> str:
        return (
            f"redis://:{self.cache_pass}"
            f"@{self.cache_host}:{self.cache_port}/{self.cache_db}"
        )

    model_config = {"env_prefix": "APP_"}


@lru_cache
def get_settings() -> Settings:
    return Settings()
