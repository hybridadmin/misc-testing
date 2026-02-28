"""OpenTelemetry SDK setup for the FastAPI application.

Configures tracing with OTLP/gRPC export to the OTel Collector.
All configuration is driven by standard OTel environment variables:

  OTEL_SERVICE_NAME          — service name in traces (default: fastapi-app)
  OTEL_EXPORTER_OTLP_ENDPOINT — collector endpoint (default: http://localhost:4317)
  OTEL_TRACES_EXPORTER       — exporter type (default: otlp)

Auto-instruments:
  - FastAPI (HTTP request/response spans)
  - SQLAlchemy (database query spans)
  - redis-py (Valkey/Redis command spans)
"""

import logging
import os

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.redis import RedisInstrumentor
from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

logger = logging.getLogger(__name__)


def init_telemetry(app, engine) -> None:
    """Initialise the OTel TracerProvider and instrument libraries.

    Args:
        app: The FastAPI application instance.
        engine: The SQLAlchemy async engine (its sync_engine is used for instrumentation).
    """
    service_name = os.environ.get("OTEL_SERVICE_NAME", "fastapi-app")

    resource = Resource.create({"service.name": service_name})
    provider = TracerProvider(resource=resource)

    # OTLP gRPC exporter — reads OTEL_EXPORTER_OTLP_ENDPOINT automatically
    exporter = OTLPSpanExporter()
    provider.add_span_processor(BatchSpanProcessor(exporter))

    trace.set_tracer_provider(provider)
    logger.info(
        "OTel TracerProvider initialised (service=%s, endpoint=%s)",
        service_name,
        os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317"),
    )

    # --- Auto-instrumentation ---

    # FastAPI: creates spans for every HTTP request.
    # Exclude /health to avoid noisy health-check spans.
    FastAPIInstrumentor.instrument_app(
        app,
        excluded_urls="health",
    )

    # SQLAlchemy: creates spans for every database query.
    SQLAlchemyInstrumentor().instrument(engine=engine.sync_engine)

    # redis-py: creates spans for every Valkey/Redis command.
    RedisInstrumentor().instrument()

    logger.info("OTel auto-instrumentation enabled (FastAPI, SQLAlchemy, Redis)")


def shutdown_telemetry() -> None:
    """Flush pending spans and shut down the TracerProvider."""
    provider = trace.get_tracer_provider()
    if hasattr(provider, "shutdown"):
        provider.shutdown()
        logger.info("OTel TracerProvider shut down")
