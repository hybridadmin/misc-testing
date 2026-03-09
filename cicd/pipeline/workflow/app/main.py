from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(
    title="Pipeline Demo API",
    version="1.0.0",
    description="Sample FastAPI app deployed via GitHub Actions + Argo CD",
)


class HealthResponse(BaseModel):
    status: str
    version: str


@app.get("/health", response_model=HealthResponse)
def health_check():
    return HealthResponse(status="healthy", version=app.version)


@app.get("/")
def root():
    return {"message": "Hello from the CI/CD pipeline!"}
