from contextlib import asynccontextmanager

from fastapi import FastAPI
from sqlalchemy import text

from app.config import get_settings
from app.cache import init_cache, close_cache
from app.database import engine, Base
from app.routes import router
from app.telemetry import init_telemetry, shutdown_telemetry


@asynccontextmanager
async def lifespan(application: FastAPI):
    # Use a pg advisory lock so only one worker creates tables at a time.
    # This avoids the SERIAL type race condition with concurrent create_all.
    async with engine.begin() as conn:
        await conn.execute(text("SELECT pg_advisory_lock(1)"))
        await conn.run_sync(Base.metadata.create_all)
        await conn.execute(text("SELECT pg_advisory_unlock(1)"))

    # Initialise Valkey connection pool
    await init_cache()

    # Initialise OpenTelemetry tracing
    init_telemetry(application, engine)

    yield

    # Shutdown
    shutdown_telemetry()
    await close_cache()
    await engine.dispose()


settings = get_settings()

app = FastAPI(
    title=settings.app_name,
    version="0.1.0",
    lifespan=lifespan,
)

app.include_router(router, prefix="/api")


@app.get("/health")
async def health():
    return {"status": "ok"}
