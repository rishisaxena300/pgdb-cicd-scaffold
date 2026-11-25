#!/usr/bin/env bash

set -euo pipefail

echo "========================================"
echo "GENERATE DATABASE PLAN"
echo "========================================"

DATABASE="AWDIM"

SCHEMA="$(
  jq -er '.AWDIM[0]' \
  cicd/db/database-config.json
)"

DESIRED_DIR="Aurora-PostgreSQL-DB/${DATABASE}/${SCHEMA}"

if [[ ! -d "${DESIRED_DIR}" ]]; then
  echo "ERROR: Desired schema directory not found:"
  echo "${DESIRED_DIR}"
  exit 1
fi

BASE_DIR="output/${ENVIRONMENT}"

BASELINE_DIR="${BASE_DIR}/baseline/${DATABASE}"
FORWARD_DIR="${BASE_DIR}/forward/${DATABASE}"
ROLLBACK_DIR="${BASE_DIR}/rollback/${DATABASE}"
REVIEW_DIR="${BASE_DIR}/review/${DATABASE}"

mkdir -p \
  "${BASELINE_DIR}" \
  "${FORWARD_DIR}" \
  "${ROLLBACK_DIR}" \
  "${REVIEW_DIR}"

echo "Environment : ${ENVIRONMENT}"
echo "Database    : ${DATABASE}"
echo "Schema      : ${SCHEMA}"

echo "========================================"
echo "TEST DATABASE CONNECTIVITY"
echo "========================================"

psql \
  --host="${PGHOST}" \
  --port="${PGPORT}" \
  --username="${PGUSER}" \
  --dbname="${DATABASE}" \
  --set ON_ERROR_STOP=1 \
  --command="SELECT current_database(), current_user;"

echo "========================================"
echo "CAPTURE EXISTING SCHEMA"
echo "========================================"

pg_dump \
  --host="${PGHOST}" \
  --port="${PGPORT}" \
  --username="${PGUSER}" \
  --dbname="${DATABASE}" \
  --schema="${SCHEMA}" \
  --schema-only \
  --no-owner \
  --no-privileges \
  > "${BASELINE_DIR}/${SCHEMA}.sql"

sha256sum \
  "${BASELINE_DIR}/${SCHEMA}.sql" \
  > "${BASELINE_DIR}/${SCHEMA}.sql.sha256"

echo "========================================"
echo "GENERATE FORWARD MIGRATION"
echo "========================================"

DB_DSN="postgres://${PGUSER}:${PGPASSWORD}@${PGHOST}:${PGPORT}/${DATABASE}"

pg-schema-diff plan \
  --from-dsn="${DB_DSN}" \
  --to-dir="${DESIRED_DIR}" \
  > "${FORWARD_DIR}/${SCHEMA}.sql"

sha256sum \
  "${FORWARD_DIR}/${SCHEMA}.sql" \
  > "${FORWARD_DIR}/${SCHEMA}.sql.sha256"

echo "Forward migration generated successfully."

RELEASE_PREFIX="$(
  cat output/release-prefix.txt
)"

echo "========================================"
echo "UPLOAD RELEASE ARTIFACTS"
echo "========================================"

aws s3 cp \
  output/desired/ \
  "s3://${RELEASE_BUCKET}/${RELEASE_PREFIX}/desired/" \
  --recursive

aws s3 cp \
  output/manifest.json \
  "s3://${RELEASE_BUCKET}/${RELEASE_PREFIX}/manifest.json"

aws s3 cp \
  "output/${ENVIRONMENT}/" \
  "s3://${RELEASE_BUCKET}/${RELEASE_PREFIX}/${ENVIRONMENT}/" \
  --recursive

echo "Generation completed."
