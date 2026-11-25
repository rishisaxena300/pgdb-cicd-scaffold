#!/usr/bin/env bash

set -euo pipefail


echo "========================================"
echo "GENERATE DATABASE PLANS"
echo "========================================"


CONFIG_FILE="cicd/db/database-config.json"


if [ ! -f "${CONFIG_FILE}" ]; then
  echo "ERROR - Database configuration file not found"
  echo "Expected file is ${CONFIG_FILE}"
  exit 1
fi


if ! jq -e 'type == "object" and length > 0' \
  "${CONFIG_FILE}" >/dev/null
then
  echo "ERROR - Database configuration is empty or invalid"
  exit 1
fi


# ----------------------------------------------------------
# Verify release metadata produced by create_release.sh
# ----------------------------------------------------------

if [ ! -f "output/release-prefix.txt" ]; then
  echo "ERROR - output/release-prefix.txt does not exist"
  exit 1
fi


if [ ! -f "output/manifest.json" ]; then
  echo "ERROR - output/manifest.json does not exist"
  exit 1
fi


if [ ! -f "output/desired/desired-schema.zip" ]; then
  echo "ERROR - desired-schema.zip does not exist"
  exit 1
fi


if [ ! -f "output/desired/desired-schema.zip.sha256" ]; then
  echo "ERROR - desired-schema.zip.sha256 does not exist"
  exit 1
fi


RELEASE_PREFIX="$(
  xargs < output/release-prefix.txt
)"


if [ -z "${RELEASE_PREFIX}" ]; then
  echo "ERROR - Release prefix is empty"
  exit 1
fi


S3_RELEASE_URI="s3://${RELEASE_BUCKET}/${RELEASE_PREFIX}"


echo "Environment is ${ENVIRONMENT}"
echo "Release bucket is ${RELEASE_BUCKET}"
echo "Release prefix is ${RELEASE_PREFIX}"


# ----------------------------------------------------------
# Read each database from database-config.json
# ----------------------------------------------------------

while IFS= read -r DATABASE
do

  if [ -z "${DATABASE}" ]; then
    continue
  fi


  echo "========================================"
  echo "PROCESS DATABASE ${DATABASE}"
  echo "========================================"


  SCHEMA_COUNT="$(
    jq -r \
      --arg database "${DATABASE}" \
      '.[$database] | length' \
      "${CONFIG_FILE}"
  )"


  if [ "${SCHEMA_COUNT}" -eq 0 ]; then
    echo "ERROR - No schemas configured for database ${DATABASE}"
    exit 1
  fi


  # --------------------------------------------------------
  # Test database connectivity once per database
  # --------------------------------------------------------

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


  # --------------------------------------------------------
  # Read every configured schema for this database
  # --------------------------------------------------------

  while IFS= read -r SCHEMA
  do

    if [ -z "${SCHEMA}" ]; then
      echo "ERROR - Empty schema configured for database ${DATABASE}"
      exit 1
    fi


    echo "========================================"
    echo "PROCESS DATABASE SCHEMA"
    echo "========================================"


    echo "Environment is ${ENVIRONMENT}"
    echo "Database is ${DATABASE}"
    echo "Schema is '${SCHEMA}'"


    # ------------------------------------------------------
    # Desired schema directory
    # ------------------------------------------------------

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


    # ------------------------------------------------------
    # Output directories
    # ------------------------------------------------------

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


    # ------------------------------------------------------
    # Verify schema exists
    # ------------------------------------------------------

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
        --command="
          SELECT EXISTS
          (
            SELECT 1
            FROM information_schema.schemata
            WHERE schema_name = '${SCHEMA}'
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


    # ------------------------------------------------------
    # Capture current/live schema
    # ------------------------------------------------------

    echo "========================================"
    echo "CAPTURE EXISTING SCHEMA"
    echo "========================================"


    BASELINE_FILE="${BASELINE_DIR}/${SCHEMA}.sql"

    BASELINE_HASH_FILE="${BASELINE_FILE}.sha256"

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


    # ------------------------------------------------------
    # Baseline SHA
    # ------------------------------------------------------

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


    # ------------------------------------------------------
    # Generate forward migration
    # ------------------------------------------------------

    echo "========================================"
    echo "GENERATE FORWARD MIGRATION"
    echo "========================================"


    FORWARD_FILE="${FORWARD_DIR}/${SCHEMA}.sql"

    FORWARD_HASH_FILE="${FORWARD_FILE}.sha256"


    echo "Desired schema directory is ${DESIRED_DIR}"
    echo "Forward migration file is ${FORWARD_FILE}"


    #
    # Do not enable shell tracing.
    # This variable contains the PLAN DB password.
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


    # ------------------------------------------------------
    # Forward plan summary
    # ------------------------------------------------------

    echo "========================================"
    echo "FORWARD MIGRATION SUMMARY"
    echo "========================================"


    if [ -s "${FORWARD_FILE}" ]; then

      echo "Database schema changes were detected"

    else

      echo "No database schema changes were detected"

    fi


    # ------------------------------------------------------
    # Upload baseline
    # ------------------------------------------------------

    echo "========================================"
    echo "UPLOAD BASELINE"
    echo "========================================"


    aws s3 cp \
      "${BASELINE_FILE}" \
      "${S3_RELEASE_URI}/${ENVIRONMENT}/baseline/${DATABASE}/${SCHEMA}.sql"


    aws s3 cp \
      "${BASELINE_HASH_FILE}" \
      "${S3_RELEASE_URI}/${ENVIRONMENT}/baseline/${DATABASE}/${SCHEMA}.sql.sha256"


    # ------------------------------------------------------
    # Upload forward migration
    # ------------------------------------------------------

    echo "========================================"
    echo "UPLOAD FORWARD MIGRATION"
    echo "========================================"


    aws s3 cp \
      "${FORWARD_FILE}" \
      "${S3_RELEASE_URI}/${ENVIRONMENT}/forward/${DATABASE}/${SCHEMA}.sql"


    aws s3 cp \
      "${FORWARD_HASH_FILE}" \
      "${S3_RELEASE_URI}/${ENVIRONMENT}/forward/${DATABASE}/${SCHEMA}.sql.sha256"


    echo "Completed ${DATABASE}.${SCHEMA}"


  done < <(
    jq -r \
      --arg database "${DATABASE}" \
      '.[$database][]' \
      "${CONFIG_FILE}"
  )


done < <(
  jq -r \
    'keys[]' \
    "${CONFIG_FILE}"
)


# ----------------------------------------------------------
# Upload desired schema once
# ----------------------------------------------------------

echo "========================================"
echo "UPLOAD DESIRED SCHEMA"
echo "========================================"


aws s3 cp \
  output/desired/desired-schema.zip \
  "${S3_RELEASE_URI}/desired/desired-schema.zip"


aws s3 cp \
  output/desired/desired-schema.zip.sha256 \
  "${S3_RELEASE_URI}/desired/desired-schema.zip.sha256"


# ----------------------------------------------------------
# Upload manifest once
# ----------------------------------------------------------

echo "========================================"
echo "UPLOAD MANIFEST"
echo "========================================"


aws s3 cp \
  output/manifest.json \
  "${S3_RELEASE_URI}/manifest.json"


# ----------------------------------------------------------
# Verify S3 release
# ----------------------------------------------------------

echo "========================================"
echo "VERIFY S3 RELEASE ARTIFACTS"
echo "========================================"


aws s3 ls \
  "${S3_RELEASE_URI}/" \
  --recursive


# ----------------------------------------------------------
# Final
# ----------------------------------------------------------

echo "========================================"
echo "DATABASE PLAN GENERATION SUCCESSFUL"
echo "========================================"


echo "Environment is ${ENVIRONMENT}"
echo "Release location is ${S3_RELEASE_URI}/"
