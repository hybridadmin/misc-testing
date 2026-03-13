#!/usr/bin/env bash
# Build and package Lambda functions for deployment.
#
# This script:
#   1. Installs npm dependencies
#   2. Compiles TypeScript to JavaScript
#   3. Copies node_modules into dist/
#   4. Creates a lambda.zip deployment package
#
# Usage: ./build.sh
#
# The resulting lambda.zip can be referenced by Terraform's
# aws_lambda_function resource via the `filename` attribute.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Installing dependencies..."
npm ci --production=false

echo "==> Compiling TypeScript..."
npx tsc

echo "==> Copying production dependencies to dist/..."
# Install production-only deps into dist/node_modules
cp package.json dist/
cp package-lock.json dist/ 2>/dev/null || true
(cd dist && npm ci --production --ignore-scripts && rm -f package.json package-lock.json)

echo "==> Creating lambda.zip..."
(cd dist && zip -rq ../lambda.zip .)

echo "==> Build complete: $(du -h lambda.zip | cut -f1) lambda.zip"
