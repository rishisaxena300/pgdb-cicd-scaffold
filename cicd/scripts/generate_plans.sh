#!/usr/bin/env bash

set -euo pipefail


echo "========================================"
echo "GENERATE DATABASE PLAN"
echo "========================================"


CONFIG_FILE="cicd/db/database-config.json"


if [ ! -f "${CONFIG_FILE}" ]; then

  echo "ERROR - Database configuration file not found"
  echo "Expected file is ${CONFIG_FILE}"

  exit 1

fi


DATABASE="AWDIM"


SCHEMA="$(
  jq -er \
    ".${DATABASE}[0]" \
    "${CONFIG_FILE}" |
  xargs
)"


if [ -z "${SCHEMA}" ]; then

  echo "ERROR - Schema is not configured for database ${DATABASE}"

  exit 1

fi


echo "Environment is ${ENVIRONMENT}"
echo "Database is ${DATABASE}"
echo "Schema is '${SCHEMA}'"


DESIRED_DIR="Aurora-PostgreSQL-DB/${DATABASE}/${SCHEMA}"


echo "========================================"
echo "VERIFY DESIRED SCHEMA DIRECTORY"
echo "========================================"


echo "Desired schema directory is ${DESIRED_DIR}"


if [ ! -d "${DESIRED_DIR}" ]; then

  echo "ERROR - Desired schema directory does not exist"
  echo "Expected directory is ${DESIRED_DIR}"

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


echo "Database connectivity successful"


echo "========================================"
echo "VERIFY SCHEMA EXISTS"
echo "========================================"


echo "Database is '${DATABASE}'"
echo "Configured schema is '${SCHEMA}'"


SCHEMA_EXISTS="$(
  psql \
    --host="${PGHOST}" \
    --port="${PGPORT}" \
    --username="${PGUSER}" \
    --dbname="${DATABASE}" \
    --set ON_ERROR_STOP=1 \
    --tuples-only \
    --no-align \
    --set="schema_name=${SCHEMA}" \
    --command="
      SELECT EXISTS
      (
        SELECT 1
        FROM information_schema.schemata
        WHERE schema_name = :'schema_name'
      );
    "
)"


SCHEMA_EXISTS="$(
  printf '%s' "${SCHEMA_EXISTS}" |
  xargs
)"


if [ "${SCHEMA_EXISTS}" != "t" ]; then

  echo "ERROR - Schema '${SCHEMA}' does not exist in database '${DATABASE}'"

  echo "Schemas visible to ${PGUSER}:"

  psql \
    --host="${PGHOST}" \
    --port="${PGPORT}" \
    --username="${PGUSER}" \
    --dbname="${DATABASE}" \
    --set ON_ERROR_STOP=1 \
    --command="
      SELECT schema_name
      FROM information_schema.schemata
      ORDER BY schema_name;
    "

  exit 1

fi


echo "Schema '${SCHEMA}' exists in database '${DATABASE}'"


echo "========================================"
echo "CAPTURE EXISTING SCHEMA"
echo "========================================"


BASELINE_FILE="${BASELINE_DIR}/${SCHEMA}.sql"

BASELINE_HASH_FILE="${BASELINE_FILE}.sha256"


#
# pg_dump --schema accepts a pattern.
#
# The database contains a quoted uppercase schema:
#
#   \"MAAS\"
#
# Therefore pass the quoted identifier as the pattern rather
# than passing MAAS as an unquoted PostgreSQL identifier.
#

SCHEMA_PATTERN="\"${SCHEMA}\""


echo "Database is ${DATABASE}"
echo "Schema is '${SCHEMA}'"
echo "pg_dump schema pattern is '${SCHEMA_PATTERN}'"
echo "Baseline file is ${BASELINE_FILE}"


pg_dump \
  --host="${PGHOST}" \
  --port="${PGPORT}" \
  --username="${PGUSER}" \
  --dbname="${DATABASE}" \
  --schema="${SCHEMA_PATTERN}" \
  --schema-only \
  --no-owner \
  --no-privileges \
  --file="${BASELINE_FILE}"


if [ ! -s "${BASELINE_FILE}" ]; then

  echo "ERROR - Captured baseline schema file is empty"

  exit 1

fi


echo "Existing schema captured successfully"


echo "========================================"
echo "CREATE BASELINE HASH"
echo "========================================"


sha256sum \
  "${BASELINE_FILE}" \
  > "${BASELINE_HASH_FILE}"


BASELINE_SHA="$(
  awk '{print $1}' \
    "${BASELINE_HASH_FILE}"
)"


echo "Baseline SHA256 is ${BASELINE_SHA}"


echo "========================================"
echo "GENERATE FORWARD MIGRATION"
echo "========================================"


FORWARD_FILE="${FORWARD_DIR}/${SCHEMA}.sql"

FORWARD_HASH_FILE="${FORWARD_FILE}.sha256"


echo "Desired schema directory is ${DESIRED_DIR}"
echo "Forward migration file is ${FORWARD_FILE}"


#
# Do not enable shell tracing here.
# The DSN contains the database password.
#

DB_DSN="postgres://${PGUSER}:${PGPASSWORD}@${PGHOST}:${PGPORT}/${DATABASE}"


pg-schema-diff plan \
  --from-dsn="${DB_DSN}" \
  --to-dir="${DESIRED_DIR}" \
  > "${FORWARD_FILE}"


if [ ! -f "${FORWARD_FILE}" ]; then

  echo "ERROR - Forward migration file was not created"

  exit 1

fi


sha256sum \
  "${FORWARD_FILE}" \
  > "${FORWARD_HASH_FILE}"


FORWARD_SHA="$(
  awk '{print $1}' \
    "${FORWARD_HASH_FILE}"
)"


echo "Forward migration generated successfully"

echo "Forward migration SHA256 is ${FORWARD_SHA}"


echo "========================================"
echo "FORWARD MIGRATION SUMMARY"
echo "========================================"


if [ -s "${FORWARD_FILE}" ]; then

  echo "Database changes were detected"

  echo "Migration file is ${FORWARD_FILE}"

else

  echo "No database schema changes were detected"

fi


echo "========================================"
echo "UPLOAD RELEASE ARTIFACTS"
echo "========================================"


if [ ! -f "output/release-prefix.txt" ]; then

  echo "ERROR - Release prefix file does not exist"

  exit 1

fi


RELEASE_PREFIX="$(
  cat output/release-prefix.txt |
  xargs
)"


if [ -z "${RELEASE_PREFIX}" ]; then

  echo "ERROR - Release prefix is empty"

  exit 1

fi


echo "Release bucket is ${RELEASE_BUCKET}"

echo "Release prefix is ${RELEASE_PREFIX}"


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


echo "========================================"
echo "GENERATION SUCCESSFUL"
echo "========================================"


echo "Environment is ${ENVIRONMENT}"

echo "Database is ${DATABASE}"

echo "Schema is ${SCHEMA}"

echo "Baseline file is ${BASELINE_FILE}"

echo "Forward migration file is ${FORWARD_FILE}"

echo "Release location is s3://${RELEASE_BUCKET}/${RELEASE_PREFIX}/"
