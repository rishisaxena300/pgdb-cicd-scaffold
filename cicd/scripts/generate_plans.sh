#!/usr/bin/env bash

set -euo pipefail


echo "========================================"
echo "GENERATE DATABASE PLANS"
echo "========================================"


CONFIG_FILE="cicd/db/database-config.json"


# ----------------------------------------------------------
# Validate required inputs
# ----------------------------------------------------------

if [ ! -f "${CONFIG_FILE}" ]; then
  echo "ERROR - Database configuration file not found"
  echo "Expected file is ${CONFIG_FILE}"
  exit 1
fi


if ! jq -e \
  'type == "object" and length > 0' \
  "${CONFIG_FILE}" \
  >/dev/null
then
  echo "ERROR - Database configuration is empty or invalid"
  exit 1
fi


if [ -z "${ENVIRONMENT:-}" ]; then
  echo "ERROR - ENVIRONMENT is required"
  exit 1
fi


if [ -z "${RELEASE_BUCKET:-}" ]; then
  echo "ERROR - RELEASE_BUCKET is required"
  exit 1
fi


if [ -z "${PGHOST:-}" ]; then
  echo "ERROR - PGHOST is required"
  exit 1
fi


if [ -z "${PGPORT:-}" ]; then
  echo "ERROR - PGPORT is required"
  exit 1
fi


if [ -z "${PGUSER:-}" ]; then
  echo "ERROR - PGUSER is required"
  exit 1
fi


if [ -z "${PGPASSWORD:-}" ]; then
  echo "ERROR - PGPASSWORD is required"
  exit 1
fi


# ----------------------------------------------------------
# Validate release files created by create_release.sh
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
  echo "ERROR - output/desired/desired-schema.zip does not exist"
  exit 1
fi


if [ ! -f "output/desired/desired-schema.zip.sha256" ]; then
  echo "ERROR - output/desired/desired-schema.zip.sha256 does not exist"
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
echo "Release location is ${S3_RELEASE_URI}"


# ----------------------------------------------------------
# Temporary workspace
#
# pg-schema-diff needs a complete DDL representation,
# including CREATE SCHEMA.
# ----------------------------------------------------------

TEMP_ROOT="$(
  mktemp -d
)"


cleanup()
{
  rm -rf "${TEMP_ROOT}"
}


trap cleanup EXIT


echo "Temporary pg-schema-diff workspace is ${TEMP_ROOT}"


# ----------------------------------------------------------
# Counters used for final verification
# ----------------------------------------------------------

DATABASE_COUNT=0
SCHEMA_TOTAL=0


# ----------------------------------------------------------
# Read every configured database
# ----------------------------------------------------------

while IFS= read -r DATABASE
do

  if [ -z "${DATABASE}" ]; then
    continue
  fi


  DATABASE_COUNT=$((DATABASE_COUNT + 1))


  echo "========================================"
  echo "PROCESS DATABASE ${DATABASE}"
  echo "========================================"


  # --------------------------------------------------------
  # Validate database identifier
  # --------------------------------------------------------

  if ! [[ "${DATABASE}" =~ ^[A-Za-z_][A-Za-z0-9_\$]*$ ]]; then
    echo "ERROR - Unsupported database identifier '${DATABASE}'"
    exit 1
  fi


  SCHEMA_COUNT="$(
    jq -r \
      --arg database "${DATABASE}" \
      '.[$database] | length' \
      "${CONFIG_FILE}"
  )"


  if ! [[ "${SCHEMA_COUNT}" =~ ^[0-9]+$ ]]; then
    echo "ERROR - Invalid schema configuration for database ${DATABASE}"
    exit 1
  fi


  if [ "${SCHEMA_COUNT}" -eq 0 ]; then
    echo "ERROR - No schemas configured for database ${DATABASE}"
    exit 1
  fi


  # --------------------------------------------------------
  # Test connectivity once per database
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
  # Build database DSN
  #
  # Do not enable shell tracing.
  # This value contains the PLAN database password.
  # --------------------------------------------------------

  DB_DSN="postgres://${PGUSER}:${PGPASSWORD}@${PGHOST}:${PGPORT}/${DATABASE}"


  # --------------------------------------------------------
  # Process every configured schema
  # --------------------------------------------------------

  while IFS= read -r SCHEMA
  do

    if [ -z "${SCHEMA}" ]; then
      echo "ERROR - Empty schema configured for database ${DATABASE}"
      exit 1
    fi


    SCHEMA_TOTAL=$((SCHEMA_TOTAL + 1))


    echo "========================================"
    echo "PROCESS ${DATABASE}.${SCHEMA}"
    echo "========================================"


    echo "Environment is ${ENVIRONMENT}"
    echo "Database is ${DATABASE}"
    echo "Schema is '${SCHEMA}'"


    # ------------------------------------------------------
    # Validate schema identifier
    # ------------------------------------------------------

    if ! [[ "${SCHEMA}" =~ ^[A-Za-z_][A-Za-z0-9_\$]*$ ]]; then
      echo "ERROR - Unsupported schema identifier '${SCHEMA}'"
      exit 1
    fi


    # ------------------------------------------------------
    # Locate repository desired-state directory
    # ------------------------------------------------------

    REPOSITORY_DESIRED_DIR="Aurora-PostgreSQL-DB/${DATABASE}/${SCHEMA}"


    echo "========================================"
    echo "VERIFY REPOSITORY DESIRED STATE"
    echo "========================================"


    echo "Repository desired-state directory is:"
    echo "${REPOSITORY_DESIRED_DIR}"


    if [ ! -d "${REPOSITORY_DESIRED_DIR}" ]; then
      echo "ERROR - Desired-state directory does not exist"
      echo "Expected directory is ${REPOSITORY_DESIRED_DIR}"
      exit 1
    fi


    DESIRED_SQL_COUNT="$(
      find "${REPOSITORY_DESIRED_DIR}" \
        -type f \
        -name "*.sql" |
      wc -l
    )"


    if [ "${DESIRED_SQL_COUNT}" -eq 0 ]; then
      echo "ERROR - No SQL files found in desired-state directory"
      echo "Directory is ${REPOSITORY_DESIRED_DIR}"
      exit 1
    fi


    echo "Desired SQL file count is ${DESIRED_SQL_COUNT}"


    # ------------------------------------------------------
    # Build complete desired-state input
    #
    # Git contains object DDL but does not need schema.sql.
    # The build adds 000_schema.sql temporarily.
    # ------------------------------------------------------

    TEMP_DESIRED_DIR="${TEMP_ROOT}/desired/${DATABASE}/${SCHEMA}"


    rm -rf "${TEMP_DESIRED_DIR}"

    mkdir -p "${TEMP_DESIRED_DIR}"


    cp -a \
      "${REPOSITORY_DESIRED_DIR}/." \
      "${TEMP_DESIRED_DIR}/"


    GENERATED_SCHEMA_FILE="${TEMP_DESIRED_DIR}/000_schema.sql"


    printf 'CREATE SCHEMA "%s";\n' \
      "${SCHEMA}" \
      > "${GENERATED_SCHEMA_FILE}"


    echo "========================================"
    echo "PREPARE COMPLETE DESIRED STATE"
    echo "========================================"


    echo "Generated schema bootstrap file:"
    echo "${GENERATED_SCHEMA_FILE}"

    echo "Schema bootstrap DDL:"

    cat "${GENERATED_SCHEMA_FILE}"

    echo "Prepared desired-state files:"

    find "${TEMP_DESIRED_DIR}" \
      -type f \
      -print |
    sort


    # ------------------------------------------------------
    # Output directories
    # ------------------------------------------------------

    BASE_DIR="output/${ENVIRONMENT}"

    BASELINE_DIR="${BASE_DIR}/baseline/${DATABASE}/${SCHEMA}"

    FORWARD_DIR="${BASE_DIR}/forward/${DATABASE}/${SCHEMA}"

    ROLLBACK_DIR="${BASE_DIR}/rollback/${DATABASE}/${SCHEMA}"

    REVIEW_DIR="${BASE_DIR}/review/${DATABASE}/${SCHEMA}"


    mkdir -p \
      "${BASELINE_DIR}" \
      "${FORWARD_DIR}" \
      "${ROLLBACK_DIR}" \
      "${REVIEW_DIR}"


    # ------------------------------------------------------
    # Verify live schema exists
    # ------------------------------------------------------

    echo "========================================"
    echo "VERIFY LIVE SCHEMA EXISTS"
    echo "========================================"


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
    #
    # This is the starting state for:
    # - drift validation
    # - forward migration
    # - rollback generation
    # ------------------------------------------------------

    echo "========================================"
    echo "CAPTURE EXISTING SCHEMA"
    echo "========================================"


    BASELINE_FILE="${BASELINE_DIR}/schema.sql"

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
    # Hash baseline
    # ------------------------------------------------------

    echo "========================================"
    echo "CREATE BASELINE HASH"
    echo "========================================"


    (
      cd "${BASELINE_DIR}"

      sha256sum \
        "schema.sql" \
        > "schema.sql.sha256"
    )


    if ! (
      cd "${BASELINE_DIR}"

      sha256sum \
        --check \
        "schema.sql.sha256"
    )
    then
      echo "ERROR - Baseline checksum verification failed"
      exit 1
    fi


    BASELINE_SHA="$(
      awk '{print $1}' \
        "${BASELINE_HASH_FILE}"
    )"


    echo "Baseline SHA256 is ${BASELINE_SHA}"


    # ------------------------------------------------------
    # Generate forward migration
    #
    # FROM: Current live database
    # TO:   Desired Git schema
    # ------------------------------------------------------

    echo "========================================"
    echo "GENERATE FORWARD MIGRATION"
    echo "========================================"


    FORWARD_FILE="${FORWARD_DIR}/migration.sql"

    FORWARD_HASH_FILE="${FORWARD_FILE}.sha256"


    echo "Forward migration source:"
    echo "Live ${DATABASE}.${SCHEMA}"

    echo "Forward migration destination:"
    echo "${TEMP_DESIRED_DIR}"

    echo "Forward migration file:"
    echo "${FORWARD_FILE}"


    pg-schema-diff plan \
      --from-dsn="${DB_DSN}" \
      --to-dir="${TEMP_DESIRED_DIR}" \
      > "${FORWARD_FILE}"


    if [ ! -f "${FORWARD_FILE}" ]; then
      echo "ERROR - Forward migration file was not created"
      exit 1
    fi


    (
      cd "${FORWARD_DIR}"

      sha256sum \
        "migration.sql" \
        > "migration.sql.sha256"
    )


    if ! (
      cd "${FORWARD_DIR}"

      sha256sum \
        --check \
        "migration.sql.sha256"
    )
    then
      echo "ERROR - Forward migration checksum verification failed"
      exit 1
    fi


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

      echo "Database schema changes were detected"
      echo "Migration file is ${FORWARD_FILE}"

    else

      echo "No forward database schema changes were detected"

    fi


    # ------------------------------------------------------
    # Prepare captured baseline as rollback target
    #
    # The baseline directory already contains schema.sql.
    # The .sha256 file is ignored because pg-schema-diff
    # reads SQL files as DDL schema sources.
    # ------------------------------------------------------

    TEMP_BASELINE_DIR="${TEMP_ROOT}/baseline/${DATABASE}/${SCHEMA}"


    rm -rf "${TEMP_BASELINE_DIR}"

    mkdir -p "${TEMP_BASELINE_DIR}"


    cp \
      "${BASELINE_FILE}" \
      "${TEMP_BASELINE_DIR}/schema.sql"


    if [ ! -s "${TEMP_BASELINE_DIR}/schema.sql" ]; then
      echo "ERROR - Temporary rollback baseline is empty"
      exit 1
    fi


    echo "========================================"
    echo "PREPARE ROLLBACK TARGET"
    echo "========================================"


    echo "Rollback target baseline is:"
    echo "${TEMP_BASELINE_DIR}/schema.sql"


    # ------------------------------------------------------
    # Generate rollback migration
    #
    # FROM: Desired Git schema
    # TO:   Captured pre-deployment baseline
    #
    # Both sides are DDL directories, so pg-schema-diff
    # needs --temp-db-dsn for temporary schema extraction.
    # ------------------------------------------------------

    echo "========================================"
    echo "GENERATE ROLLBACK MIGRATION"
    echo "========================================"


    ROLLBACK_FILE="${ROLLBACK_DIR}/rollback.sql"

    ROLLBACK_HASH_FILE="${ROLLBACK_FILE}.sha256"


    echo "Rollback migration source:"
    echo "${TEMP_DESIRED_DIR}"

    echo "Rollback migration destination:"
    echo "${TEMP_BASELINE_DIR}"

    echo "Rollback migration file:"
    echo "${ROLLBACK_FILE}"


    pg-schema-diff plan \
      --from-dir="${TEMP_DESIRED_DIR}" \
      --to-dir="${TEMP_BASELINE_DIR}" \
      --temp-db-dsn="${DB_DSN}" \
      > "${ROLLBACK_FILE}"


    if [ ! -f "${ROLLBACK_FILE}" ]; then
      echo "ERROR - Rollback migration file was not created"
      exit 1
    fi


    (
      cd "${ROLLBACK_DIR}"

      sha256sum \
        "rollback.sql" \
        > "rollback.sql.sha256"
    )


    if ! (
      cd "${ROLLBACK_DIR}"

      sha256sum \
        --check \
        "rollback.sql.sha256"
    )
    then
      echo "ERROR - Rollback migration checksum verification failed"
      exit 1
    fi


    ROLLBACK_SHA="$(
      awk '{print $1}' \
        "${ROLLBACK_HASH_FILE}"
    )"


    echo "Rollback migration generated successfully"
    echo "Rollback migration SHA256 is ${ROLLBACK_SHA}"


    echo "========================================"
    echo "ROLLBACK MIGRATION SUMMARY"
    echo "========================================"


    if [ -s "${ROLLBACK_FILE}" ]; then

      echo "Rollback SQL was generated"
      echo "Rollback migration file is ${ROLLBACK_FILE}"

    else

      echo "No rollback SQL is required"

    fi


    # ------------------------------------------------------
    # Verify complete local schema release
    # ------------------------------------------------------

    echo "========================================"
    echo "VERIFY LOCAL SCHEMA RELEASE"
    echo "========================================"


    for required_file in \
      "${BASELINE_FILE}" \
      "${BASELINE_HASH_FILE}" \
      "${FORWARD_FILE}" \
      "${FORWARD_HASH_FILE}" \
      "${ROLLBACK_FILE}" \
      "${ROLLBACK_HASH_FILE}"
    do

      if [ ! -f "${required_file}" ]; then
        echo "ERROR - Required release artifact is missing"
        echo "${required_file}"
        exit 1
      fi

      echo "Verified ${required_file}"

    done


    echo "Baseline SHA256=${BASELINE_SHA}"
    echo "Forward SHA256=${FORWARD_SHA}"
    echo "Rollback SHA256=${ROLLBACK_SHA}"

    echo "Completed plan generation for ${DATABASE}.${SCHEMA}"


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


if [ "${DATABASE_COUNT}" -eq 0 ]; then
  echo "ERROR - No databases were processed"
  exit 1
fi


if [ "${SCHEMA_TOTAL}" -eq 0 ]; then
  echo "ERROR - No schemas were processed"
  exit 1
fi


echo "========================================"
echo "LOCAL PLAN GENERATION COMPLETE"
echo "========================================"


echo "Database count is ${DATABASE_COUNT}"
echo "Schema count is ${SCHEMA_TOTAL}"


echo "Generated plan files:"


find "output/${ENVIRONMENT}" \
  -type f \
  -print |
sort


# ----------------------------------------------------------
# Verify all configured local artifacts before S3 upload
#
# Nothing is uploaded until all configured schemas have
# successfully generated baseline, forward, and rollback.
# ----------------------------------------------------------

echo "========================================"
echo "VERIFY COMPLETE LOCAL RELEASE"
echo "========================================"


while IFS= read -r DATABASE
do

  while IFS= read -r SCHEMA
  do

    LOCAL_SCHEMA_ROOT="output/${ENVIRONMENT}"

    for required_file in \
      "${LOCAL_SCHEMA_ROOT}/baseline/${DATABASE}/${SCHEMA}/schema.sql" \
      "${LOCAL_SCHEMA_ROOT}/baseline/${DATABASE}/${SCHEMA}/schema.sql.sha256" \
      "${LOCAL_SCHEMA_ROOT}/forward/${DATABASE}/${SCHEMA}/migration.sql" \
      "${LOCAL_SCHEMA_ROOT}/forward/${DATABASE}/${SCHEMA}/migration.sql.sha256" \
      "${LOCAL_SCHEMA_ROOT}/rollback/${DATABASE}/${SCHEMA}/rollback.sql" \
      "${LOCAL_SCHEMA_ROOT}/rollback/${DATABASE}/${SCHEMA}/rollback.sql.sha256"
    do

      if [ ! -f "${required_file}" ]; then
        echo "ERROR - Complete release verification failed"
        echo "Missing ${required_file}"
        exit 1
      fi

    done


    echo "Complete local release verified for ${DATABASE}.${SCHEMA}"


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
# Upload desired schema once per release
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
# Upload manifest once per release
# ----------------------------------------------------------

echo "========================================"
echo "UPLOAD MANIFEST"
echo "========================================"


aws s3 cp \
  output/manifest.json \
  "${S3_RELEASE_URI}/manifest.json"


# ----------------------------------------------------------
# Upload all environment artifacts
#
# This uploads baseline, forward, rollback, and checksums.
# ----------------------------------------------------------

echo "========================================"
echo "UPLOAD ENVIRONMENT RELEASE ARTIFACTS"
echo "========================================"


aws s3 cp \
  "output/${ENVIRONMENT}/" \
  "${S3_RELEASE_URI}/${ENVIRONMENT}/" \
  --recursive


# ----------------------------------------------------------
# Verify all required S3 objects
# ----------------------------------------------------------

echo "========================================"
echo "VERIFY S3 RELEASE ARTIFACTS"
echo "========================================"


aws s3api head-object \
  --bucket "${RELEASE_BUCKET}" \
  --key "${RELEASE_PREFIX}/manifest.json" \
  >/dev/null


aws s3api head-object \
  --bucket "${RELEASE_BUCKET}" \
  --key "${RELEASE_PREFIX}/desired/desired-schema.zip" \
  >/dev/null


aws s3api head-object \
  --bucket "${RELEASE_BUCKET}" \
  --key "${RELEASE_PREFIX}/desired/desired-schema.zip.sha256" \
  >/dev/null


while IFS= read -r DATABASE
do

  while IFS= read -r SCHEMA
  do

    for object_key in \
      "${RELEASE_PREFIX}/${ENVIRONMENT}/baseline/${DATABASE}/${SCHEMA}/schema.sql" \
      "${RELEASE_PREFIX}/${ENVIRONMENT}/baseline/${DATABASE}/${SCHEMA}/schema.sql.sha256" \
      "${RELEASE_PREFIX}/${ENVIRONMENT}/forward/${DATABASE}/${SCHEMA}/migration.sql" \
      "${RELEASE_PREFIX}/${ENVIRONMENT}/forward/${DATABASE}/${SCHEMA}/migration.sql.sha256" \
      "${RELEASE_PREFIX}/${ENVIRONMENT}/rollback/${DATABASE}/${SCHEMA}/rollback.sql" \
      "${RELEASE_PREFIX}/${ENVIRONMENT}/rollback/${DATABASE}/${SCHEMA}/rollback.sql.sha256"
    do

      aws s3api head-object \
        --bucket "${RELEASE_BUCKET}" \
        --key "${object_key}" \
        >/dev/null

      echo "Verified s3://${RELEASE_BUCKET}/${object_key}"

    done


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


echo "========================================"
echo "FINAL S3 RELEASE CONTENT"
echo "========================================"


aws s3 ls \
  "${S3_RELEASE_URI}/" \
  --recursive


# ----------------------------------------------------------
# Complete
# ----------------------------------------------------------

echo "========================================"
echo "DATABASE PLAN GENERATION SUCCESSFUL"
echo "========================================"


echo "Environment is ${ENVIRONMENT}"
echo "Databases processed is ${DATABASE_COUNT}"
echo "Schemas processed is ${SCHEMA_TOTAL}"
echo "Release location is ${S3_RELEASE_URI}/"
