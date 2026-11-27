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


for required_variable in \
  ENVIRONMENT \
  RELEASE_BUCKET \
  PGHOST \
  PGPORT \
  PGUSER \
  PGPASSWORD
do

  if [ -z "${!required_variable:-}" ]; then
    echo "ERROR - ${required_variable} is required"
    exit 1
  fi

done


ENVIRONMENT="$(
  printf '%s' "${ENVIRONMENT}" |
  xargs |
  tr '[:lower:]' '[:upper:]'
)"


RELEASE_BUCKET="$(
  printf '%s' "${RELEASE_BUCKET}" |
  xargs
)"


export ENVIRONMENT
export RELEASE_BUCKET


case "${ENVIRONMENT}" in

  T1|T2)
    ;;

  *)
    echo "ERROR - ENVIRONMENT must be T1 or T2"
    echo "Received value is '${ENVIRONMENT}'"
    exit 1
    ;;

esac


# ----------------------------------------------------------
# Validate release files created by create_release.sh
# ----------------------------------------------------------

for required_file in \
  output/release-prefix.txt \
  output/manifest.json \
  output/deployspec.yml \
  output/deployspec.yml.sha256 \
  output/deploy.sh \
  output/deploy.sh.sha256 \
  output/desired/desired-schema.zip \
  output/desired/desired-schema.zip.sha256
do

  if [ ! -s "${required_file}" ]; then
    echo "ERROR - Required release file is missing or empty"
    echo "${required_file}"
    exit 1
  fi

done


# ----------------------------------------------------------
# Verify packaged deployment file checksums
# ----------------------------------------------------------

echo "========================================"
echo "VERIFY PACKAGED DEPLOYMENT FILES"
echo "========================================"


if ! (
  cd output

  sha256sum \
    --check \
    deployspec.yml.sha256

  sha256sum \
    --check \
    deploy.sh.sha256
)
then
  echo "ERROR - Packaged deployment file checksum verification failed"
  exit 1
fi


echo "Packaged deployspec.yml checksum verified"

echo "Packaged deploy.sh checksum verified"


# ----------------------------------------------------------
# Read release prefix
# ----------------------------------------------------------

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


DATABASE_COUNT=0
SCHEMA_TOTAL=0


# ----------------------------------------------------------
# Process every configured database
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
    echo "ERROR - Invalid schema configuration for ${DATABASE}"
    exit 1
  fi


  if [ "${SCHEMA_COUNT}" -eq 0 ]; then
    echo "ERROR - No schemas configured for ${DATABASE}"
    exit 1
  fi


  # --------------------------------------------------------
  # Test database connectivity
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


  # Do not enable shell tracing. This contains the password.

  DB_DSN="postgres://${PGUSER}:${PGPASSWORD}@${PGHOST}:${PGPORT}/${DATABASE}"


  # --------------------------------------------------------
  # Process every configured schema
  # --------------------------------------------------------

  while IFS= read -r SCHEMA
  do

    if [ -z "${SCHEMA}" ]; then
      echo "ERROR - Empty schema configured for ${DATABASE}"
      exit 1
    fi


    SCHEMA_TOTAL=$((SCHEMA_TOTAL + 1))


    echo "========================================"
    echo "PROCESS ${DATABASE}.${SCHEMA}"
    echo "========================================"


    echo "Environment is ${ENVIRONMENT}"
    echo "Database is ${DATABASE}"
    echo "Schema is '${SCHEMA}'"


    if ! [[ "${SCHEMA}" =~ ^[A-Za-z_][A-Za-z0-9_\$]*$ ]]; then
      echo "ERROR - Unsupported schema identifier '${SCHEMA}'"
      exit 1
    fi


    # ------------------------------------------------------
    # Validate repository desired state
    # ------------------------------------------------------

    REPOSITORY_DESIRED_DIR="Aurora-PostgreSQL-DB/${DATABASE}/${SCHEMA}"


    echo "========================================"
    echo "VERIFY REPOSITORY DESIRED STATE"
    echo "========================================"


    echo "Repository desired-state directory:"
    echo "${REPOSITORY_DESIRED_DIR}"


    if [ ! -d "${REPOSITORY_DESIRED_DIR}" ]; then
      echo "ERROR - Desired-state directory does not exist"
      echo "${REPOSITORY_DESIRED_DIR}"
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
      echo "${REPOSITORY_DESIRED_DIR}"
      exit 1
    fi


    echo "Desired SQL file count is ${DESIRED_SQL_COUNT}"


    # ------------------------------------------------------
    # Prepare complete desired-state input
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
    # Prepare output directories
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

      echo "ERROR - Schema '${SCHEMA}' does not exist in '${DATABASE}'"

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
    # Capture original current/live schema
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
    # Hash original baseline
    # ------------------------------------------------------

    echo "========================================"
    echo "CREATE BASELINE HASH"
    echo "========================================"


    (
      cd "${BASELINE_DIR}"

      sha256sum \
        schema.sql \
        > schema.sql.sha256
    )


    if ! (
      cd "${BASELINE_DIR}"

      sha256sum \
        --check \
        schema.sql.sha256
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
        migration.sql \
        > migration.sql.sha256
    )


    if ! (
      cd "${FORWARD_DIR}"

      sha256sum \
        --check \
        migration.sql.sha256
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
    # Prepare normalized baseline for rollback planning
    # ------------------------------------------------------

    echo "========================================"
    echo "PREPARE NORMALIZED ROLLBACK BASELINE"
    echo "========================================"


    TEMP_BASELINE_DIR="${TEMP_ROOT}/baseline/${DATABASE}/${SCHEMA}"

    NORMALIZED_BASELINE_FILE="${TEMP_BASELINE_DIR}/schema.sql"


    rm -rf "${TEMP_BASELINE_DIR}"

    mkdir -p "${TEMP_BASELINE_DIR}"


    sed \
      -e '/^[[:space:]]*\\restrict\([[:space:]].*\)\{0,1\}[[:space:]]*$/d' \
      -e '/^[[:space:]]*\\unrestrict\([[:space:]].*\)\{0,1\}[[:space:]]*$/d' \
      "${BASELINE_FILE}" \
      > "${NORMALIZED_BASELINE_FILE}"


    if [ ! -s "${NORMALIZED_BASELINE_FILE}" ]; then
      echo "ERROR - Normalized rollback baseline is empty"
      exit 1
    fi


    echo "Original baseline:"
    echo "${BASELINE_FILE}"

    echo "Normalized rollback baseline:"
    echo "${NORMALIZED_BASELINE_FILE}"


    ORIGINAL_RESTRICT_COUNT="$(
      grep \
        -cE \
        '^[[:space:]]*\\(un)?restrict([[:space:]]|$)' \
        "${BASELINE_FILE}" \
        || true
    )"


    NORMALIZED_RESTRICT_COUNT="$(
      grep \
        -cE \
        '^[[:space:]]*\\(un)?restrict([[:space:]]|$)' \
        "${NORMALIZED_BASELINE_FILE}" \
        || true
    )"


    echo "Removed restrict/unrestrict command count:"
    echo "${ORIGINAL_RESTRICT_COUNT}"


    if [ "${NORMALIZED_RESTRICT_COUNT}" -ne 0 ]; then
      echo "ERROR - restrict/unrestrict commands remain after normalization"

      grep \
        -nE \
        '^[[:space:]]*\\(un)?restrict([[:space:]]|$)' \
        "${NORMALIZED_BASELINE_FILE}" \
        || true

      exit 1
    fi


    REMAINING_META_COMMANDS="$(
      grep \
        -nE \
        '^[[:space:]]*\\' \
        "${NORMALIZED_BASELINE_FILE}" \
        || true
    )"


    if [ -n "${REMAINING_META_COMMANDS}" ]; then
      echo "ERROR - Baseline contains unsupported psql meta-commands"
      echo "pg-schema-diff cannot execute these as SQL:"
      echo "${REMAINING_META_COMMANDS}"
      exit 1
    fi


    echo "Normalized rollback baseline contains SQL DDL only"


    # ------------------------------------------------------
    # Generate rollback migration
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
        rollback.sql \
        > rollback.sql.sha256
    )


    if ! (
      cd "${ROLLBACK_DIR}"

      sha256sum \
        --check \
        rollback.sql.sha256
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


# ----------------------------------------------------------
# Validate processing counts
# ----------------------------------------------------------

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
# Verify all local artifacts before S3 upload
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
# Upload release-level deployment files
# ----------------------------------------------------------

echo "========================================"
echo "UPLOAD DEPLOYMENT FILES"
echo "========================================"


aws s3 cp \
  output/deployspec.yml \
  "${S3_RELEASE_URI}/deployspec.yml"


aws s3 cp \
  output/deployspec.yml.sha256 \
  "${S3_RELEASE_URI}/deployspec.yml.sha256"


aws s3 cp \
  output/deploy.sh \
  "${S3_RELEASE_URI}/deploy.sh"


aws s3 cp \
  output/deploy.sh.sha256 \
  "${S3_RELEASE_URI}/deploy.sh.sha256"


echo "Deployment files uploaded"


# ----------------------------------------------------------
# Upload desired schema
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
# Upload manifest
# ----------------------------------------------------------

echo "========================================"
echo "UPLOAD MANIFEST"
echo "========================================"


aws s3 cp \
  output/manifest.json \
  "${S3_RELEASE_URI}/manifest.json"


# ----------------------------------------------------------
# Upload baseline, forward, rollback and checksums
# ----------------------------------------------------------

echo "========================================"
echo "UPLOAD ENVIRONMENT RELEASE ARTIFACTS"
echo "========================================"


aws s3 cp \
  "output/${ENVIRONMENT}/" \
  "${S3_RELEASE_URI}/${ENVIRONMENT}/" \
  --recursive


# ----------------------------------------------------------
# Verify release-level S3 artifacts
# ----------------------------------------------------------

echo "========================================"
echo "VERIFY S3 RELEASE ARTIFACTS"
echo "========================================"


for release_object in \
  "${RELEASE_PREFIX}/manifest.json" \
  "${RELEASE_PREFIX}/deployspec.yml" \
  "${RELEASE_PREFIX}/deployspec.yml.sha256" \
  "${RELEASE_PREFIX}/deploy.sh" \
  "${RELEASE_PREFIX}/deploy.sh.sha256" \
  "${RELEASE_PREFIX}/desired/desired-schema.zip" \
  "${RELEASE_PREFIX}/desired/desired-schema.zip.sha256"
do

  aws s3api head-object \
    --bucket "${RELEASE_BUCKET}" \
    --key "${release_object}" \
    >/dev/null

  echo "Verified s3://${RELEASE_BUCKET}/${release_object}"

done


# ----------------------------------------------------------
# Download and verify S3 deployment-file checksums
# ----------------------------------------------------------

echo "========================================"
echo "VERIFY S3 DEPLOYMENT FILE CHECKSUMS"
echo "========================================"


rm -rf "${TEMP_ROOT}/deployment-verification"


mkdir -p \
  "${TEMP_ROOT}/deployment-verification"


aws s3 cp \
  "${S3_RELEASE_URI}/deployspec.yml" \
  "${TEMP_ROOT}/deployment-verification/deployspec.yml"


aws s3 cp \
  "${S3_RELEASE_URI}/deployspec.yml.sha256" \
  "${TEMP_ROOT}/deployment-verification/deployspec.yml.sha256"


aws s3 cp \
  "${S3_RELEASE_URI}/deploy.sh" \
  "${TEMP_ROOT}/deployment-verification/deploy.sh"


aws s3 cp \
  "${S3_RELEASE_URI}/deploy.sh.sha256" \
  "${TEMP_ROOT}/deployment-verification/deploy.sh.sha256"


if ! (
  cd "${TEMP_ROOT}/deployment-verification"

  sha256sum \
    --check \
    deployspec.yml.sha256

  sha256sum \
    --check \
    deploy.sh.sha256
)
then
  echo "ERROR - S3 deployment file checksum verification failed"
  exit 1
fi


echo "S3 deployspec.yml checksum verified"

echo "S3 deploy.sh checksum verified"


# ----------------------------------------------------------
# Verify every database/schema S3 artifact
# ----------------------------------------------------------

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


echo "========================================"
echo "DATABASE PLAN GENERATION SUCCESSFUL"
echo "========================================"


echo "Environment is ${ENVIRONMENT}"

echo "Databases processed is ${DATABASE_COUNT}"

echo "Schemas processed is ${SCHEMA_TOTAL}"

echo "Deployment BuildSpec is ${S3_RELEASE_URI}/deployspec.yml"

echo "Deployment script is ${S3_RELEASE_URI}/deploy.sh"

echo "Release location is ${S3_RELEASE_URI}/"
