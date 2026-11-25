#!/usr/bin/env bash
 
set -euo pipefail
 
DATABASE="AWDIM"
SCHEMA="$(jq -er '.AWDIM[0]' cicd/db/database-config.json)"
 
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
 
echo "========================================"
echo "DATABASE PLAN"
echo "========================================"
 
echo "Environment : ${ENVIRONMENT}"
echo "Database    : ${DATABASE}"
echo "Schema      : ${SCHEMA}"
 
psql \
  --host="${PGHOST}" \
  --port="${PGPORT}" \
  --username="${PGUSER}" \
  --dbname="${DATABASE}" \
  --set ON_ERROR_STOP=1 \
  --command="SELECT current_database(), current_user;"
 
echo "Capturing baseline..."
 
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
 
DESIRED_DIR="Aurora-PostgreSQL-DB/${DATABASE}/${SCHEMA}"
 
test -d "${DESIRED_DIR}"
 
echo "Generating forward migration..."
 
DB_DSN="postgres://${PGUSER}:${PGPASSWORD}@${PGHOST}:${PGPORT}/${DATABASE}"
 
pg-schema-diff plan \
  --from-dsn="${DB_DSN}" \
  --to-dir="${DESIRED_DIR}" \
  > "${FORWARD_DIR}/${SCHEMA}.sql"
 
sha256sum \
  "${FORWARD_DIR}/${SCHEMA}.sql" \
  > "${FORWARD_DIR}/${SCHEMA}.sql.sha256"
 
echo "Forward migration generated."
