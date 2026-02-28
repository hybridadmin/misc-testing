from pydantic_settings import BaseSettings
from functools import lru_cache


class Settings(BaseSettings):
    app_name: str = "FastAPI Test App"

    db_user: str = "appuser"
    db_pass: str = "apppass"
    db_host: str = "postgres"
    db_port: int = 5432
    db_name: str = "appdb"

    @property
    def database_url(self) -> str:
        return (
            f"postgresql+asyncpg://{self.db_user}:{self.db_pass}"
            f"@{self.db_host}:{self.db_port}/{self.db_name}"
        )

    model_config = {"env_prefix": "APP_"}


@lru_cache
def get_settings() -> Settings:
    return Settings()
