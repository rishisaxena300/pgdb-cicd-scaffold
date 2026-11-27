#!/usr/bin/env bash

set -euo pipefail


echo "========================================"
echo "DATABASE RELEASE DEPLOYMENT"
echo "========================================"


# ----------------------------------------------------------
# Validate deployment configuration
# ----------------------------------------------------------

for variable in \
  RELEASE_BUCKET \
  TARGET_ENVIRONMENT \
  TARGET_ROLE_ARN \
  DEPLOY_SECRET_ID
do

  if [ -z "${!variable:-}" ]; then
    echo "ERROR - ${variable} is required"
    exit 1
  fi

done


RELEASE_BUCKET="$(
  printf '%s' "${RELEASE_BUCKET}" |
  xargs
)"


TARGET_ENVIRONMENT="$(
  printf '%s' "${TARGET_ENVIRONMENT}" |
  xargs |
  tr '[:lower:]' '[:upper:]'
)"


TARGET_ROLE_ARN="$(
  printf '%s' "${TARGET_ROLE_ARN}" |
  xargs
)"


DEPLOY_SECRET_ID="$(
  printf '%s' "${DEPLOY_SECRET_ID}" |
  xargs
)"


export RELEASE_BUCKET
export TARGET_ENVIRONMENT
export TARGET_ROLE_ARN
export DEPLOY_SECRET_ID


case "${TARGET_ENVIRONMENT}" in

  T1|T2|STAGING|PRODUCTION)
    ;;

  *)
    echo "ERROR - Unsupported TARGET_ENVIRONMENT"
    echo "Received value is '${TARGET_ENVIRONMENT}'"
    exit 1
    ;;

esac


echo "Target environment=${TARGET_ENVIRONMENT}"
echo "Release bucket=${RELEASE_BUCKET}"
echo "Target role=${TARGET_ROLE_ARN}"
echo "Deploy secret=${DEPLOY_SECRET_ID}"


# ----------------------------------------------------------
# Verify deployment tools
# ----------------------------------------------------------

echo "========================================"
echo "VERIFY DEPLOYMENT TOOLS"
echo "========================================"


for command_name in \
  aws \
  jq \
  unzip \
  sha256sum \
  psql \
  pg_dump
do

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "ERROR - Required command is unavailable"
    echo "Command=${command_name}"
    exit 1
  fi

done


aws --version
jq --version
psql --version
pg_dump --version


POSTGRES_CLIENT_MAJOR="$(
  pg_dump --version |
  awk '{print $3}' |
  cut -d. -f1
)"


if [ "${POSTGRES_CLIENT_MAJOR}" != "17" ]; then
  echo "ERROR - PostgreSQL client 17 is required"
  echo "Installed major=${POSTGRES_CLIENT_MAJOR}"
  exit 1
fi


# ----------------------------------------------------------
# Read approved release pointer
#
# This operation uses the DevSecOps CodeBuild role.
# The target-account role is assumed later, after every
# approved release artifact has been downloaded.
# ----------------------------------------------------------

echo "========================================"
echo "READ APPROVED RELEASE"
echo "========================================"


aws s3 cp \
  "s3://${RELEASE_BUCKET}/approved-release/current.json" \
  /tmp/approved-release.json


if ! jq -e . \
  /tmp/approved-release.json \
  >/dev/null
then
  echo "ERROR - Approved release pointer is invalid JSON"
  exit 1
fi


APPROVED="$(
  jq -r \
    '.approved // false' \
    /tmp/approved-release.json
)"


RELEASE_BRANCH="$(
  jq -r \
    '.release_branch // empty' \
    /tmp/approved-release.json
)"


RELEASE_COMMIT="$(
  jq -r \
    '.release_commit // empty' \
    /tmp/approved-release.json
)"


RELEASE_PREFIX="$(
  jq -r \
    '.release_prefix // empty' \
    /tmp/approved-release.json
)"


PLAN_ENVIRONMENT="$(
  jq -r \
    '.plan_environment // empty' \
    /tmp/approved-release.json
)"


if [ "${APPROVED}" != "true" ]; then
  echo "ERROR - Release is not approved"
  exit 1
fi


if [ -z "${RELEASE_BRANCH}" ]; then
  echo "ERROR - release_branch is missing"
  exit 1
fi


if ! [[ "${RELEASE_COMMIT}" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "ERROR - release_commit is invalid"
  echo "Received value=${RELEASE_COMMIT}"
  exit 1
fi


if [ -z "${RELEASE_PREFIX}" ]; then
  echo "ERROR - release_prefix is missing"
  exit 1
fi


case "${PLAN_ENVIRONMENT}" in

  T1|T2)
    ;;

  *)
    echo "ERROR - Invalid plan_environment"
    echo "Received value=${PLAN_ENVIRONMENT}"
    exit 1
    ;;

esac


export RELEASE_BRANCH
export RELEASE_COMMIT
export RELEASE_PREFIX
export PLAN_ENVIRONMENT


echo "Release branch=${RELEASE_BRANCH}"
echo "Release commit=${RELEASE_COMMIT}"
echo "Release prefix=${RELEASE_PREFIX}"
echo "Plan environment=${PLAN_ENVIRONMENT}"
echo "Target environment=${TARGET_ENVIRONMENT}"


# ----------------------------------------------------------
# Verify approved release manifest
# ----------------------------------------------------------

echo "========================================"
echo "VERIFY RELEASE MANIFEST"
echo "========================================"


aws s3 cp \
  "s3://${RELEASE_BUCKET}/${RELEASE_PREFIX}/manifest.json" \
  /tmp/release-manifest.json


if ! jq -e . \
  /tmp/release-manifest.json \
  >/dev/null
then
  echo "ERROR - Release manifest is invalid JSON"
  exit 1
fi


MANIFEST_BRANCH="$(
  jq -r \
    '.release_branch // empty' \
    /tmp/release-manifest.json
)"


MANIFEST_COMMIT="$(
  jq -r \
    '.git_commit // empty' \
    /tmp/release-manifest.json
)"


if [ "${MANIFEST_BRANCH}" != "${RELEASE_BRANCH}" ]; then
  echo "ERROR - Manifest branch mismatch"
  echo "Approved=${RELEASE_BRANCH}"
  echo "Manifest=${MANIFEST_BRANCH}"
  exit 1
fi


if [ "${MANIFEST_COMMIT}" != "${RELEASE_COMMIT}" ]; then
  echo "ERROR - Manifest commit mismatch"
  echo "Approved=${RELEASE_COMMIT}"
  echo "Manifest=${MANIFEST_COMMIT}"
  exit 1
fi


echo "Release manifest verified"


# ----------------------------------------------------------
# Download and verify desired schema bundle
# ----------------------------------------------------------

echo "========================================"
echo "DOWNLOAD DESIRED SCHEMA"
echo "========================================"


aws s3 cp \
  "s3://${RELEASE_BUCKET}/${RELEASE_PREFIX}/desired/desired-schema.zip" \
  /tmp/desired-schema.zip


aws s3 cp \
  "s3://${RELEASE_BUCKET}/${RELEASE_PREFIX}/desired/desired-schema.zip.sha256" \
  /tmp/desired-schema.zip.sha256


EXPECTED_DESIRED_SHA="$(
  awk '{print $1}' \
    /tmp/desired-schema.zip.sha256
)"


ACTUAL_DESIRED_SHA="$(
  sha256sum \
    /tmp/desired-schema.zip |
  awk '{print $1}'
)"


if [ -z "${EXPECTED_DESIRED_SHA}" ]; then
  echo "ERROR - Desired schema expected SHA256 is empty"
  exit 1
fi


if ! [[ "${EXPECTED_DESIRED_SHA}" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "ERROR - Desired schema expected SHA256 is invalid"
  exit 1
fi


if [ "${EXPECTED_DESIRED_SHA}" != "${ACTUAL_DESIRED_SHA}" ]; then
  echo "ERROR - Desired schema checksum mismatch"
  echo "Expected=${EXPECTED_DESIRED_SHA}"
  echo "Actual=${ACTUAL_DESIRED_SHA}"
  exit 1
fi


echo "Desired schema checksum verified"


# ----------------------------------------------------------
# Extract release database configuration
# ----------------------------------------------------------

echo "========================================"
echo "EXTRACT DATABASE CONFIGURATION"
echo "========================================"


rm -rf /tmp/desired-schema


mkdir -p /tmp/desired-schema


unzip \
  -q \
  /tmp/desired-schema.zip \
  -d /tmp/desired-schema


CONFIG_FILE="$(
  find /tmp/desired-schema \
    -type f \
    -path "*/cicd/db/database-config.json" \
    -print \
    -quit
)"


if [ -z "${CONFIG_FILE}" ]; then
  echo "ERROR - database-config.json was not found"
  exit 1
fi


if ! jq -e \
  'type == "object" and length > 0' \
  "${CONFIG_FILE}" \
  >/dev/null
then
  echo "ERROR - database-config.json is empty or invalid"
  exit 1
fi


cp \
  "${CONFIG_FILE}" \
  /tmp/database-config.json


echo "Approved database configuration:"


cat /tmp/database-config.json


# ----------------------------------------------------------
# Download approved baseline, migration and rollback
#
# Rollback is downloaded and checksum-verified so the
# deployment package remains complete. It is not executed
# during normal forward deployment.
# ----------------------------------------------------------

echo "========================================"
echo "DOWNLOAD APPROVED DATABASE ARTIFACTS"
echo "========================================"


rm -rf /tmp/db-release


mkdir -p /tmp/db-release


SCHEMA_COUNT=0


while IFS= read -r DATABASE
do

  if [ -z "${DATABASE}" ]; then
    continue
  fi


  if ! [[ "${DATABASE}" =~ ^[A-Za-z_][A-Za-z0-9_\$]*$ ]]; then
    echo "ERROR - Unsupported database identifier"
    echo "Database=${DATABASE}"
    exit 1
  fi


  while IFS= read -r SCHEMA
  do

    if [ -z "${SCHEMA}" ]; then
      echo "ERROR - Empty schema configured for ${DATABASE}"
      exit 1
    fi


    if ! [[ "${SCHEMA}" =~ ^[A-Za-z_][A-Za-z0-9_\$]*$ ]]; then
      echo "ERROR - Unsupported schema identifier"
      echo "Schema=${SCHEMA}"
      exit 1
    fi


    SCHEMA_COUNT=$((SCHEMA_COUNT + 1))


    LOCAL_DIR="/tmp/db-release/${DATABASE}/${SCHEMA}"


    mkdir -p "${LOCAL_DIR}"


    BASELINE_URI="s3://${RELEASE_BUCKET}/${RELEASE_PREFIX}/${PLAN_ENVIRONMENT}/baseline/${DATABASE}/${SCHEMA}"


    FORWARD_URI="s3://${RELEASE_BUCKET}/${RELEASE_PREFIX}/${PLAN_ENVIRONMENT}/forward/${DATABASE}/${SCHEMA}"


    ROLLBACK_URI="s3://${RELEASE_BUCKET}/${RELEASE_PREFIX}/${PLAN_ENVIRONMENT}/rollback/${DATABASE}/${SCHEMA}"


    aws s3 cp \
      "${BASELINE_URI}/schema.sql" \
      "${LOCAL_DIR}/baseline.sql"


    aws s3 cp \
      "${BASELINE_URI}/schema.sql.sha256" \
      "${LOCAL_DIR}/baseline.sql.sha256"


    aws s3 cp \
      "${FORWARD_URI}/migration.sql" \
      "${LOCAL_DIR}/migration.sql"


    aws s3 cp \
      "${FORWARD_URI}/migration.sql.sha256" \
      "${LOCAL_DIR}/migration.sql.sha256"


    aws s3 cp \
      "${ROLLBACK_URI}/rollback.sql" \
      "${LOCAL_DIR}/rollback.sql"


    aws s3 cp \
      "${ROLLBACK_URI}/rollback.sql.sha256" \
      "${LOCAL_DIR}/rollback.sql.sha256"


    for artifact in \
      baseline \
      migration \
      rollback
    do

      case "${artifact}" in

        baseline)
          SQL_FILE="${LOCAL_DIR}/baseline.sql"
          HASH_FILE="${LOCAL_DIR}/baseline.sql.sha256"
          ;;

        migration)
          SQL_FILE="${LOCAL_DIR}/migration.sql"
          HASH_FILE="${LOCAL_DIR}/migration.sql.sha256"
          ;;

        rollback)
          SQL_FILE="${LOCAL_DIR}/rollback.sql"
          HASH_FILE="${LOCAL_DIR}/rollback.sql.sha256"
          ;;

        *)
          echo "ERROR - Unexpected deployment artifact"
          echo "Artifact=${artifact}"
          exit 1
          ;;

      esac


      if [ ! -f "${SQL_FILE}" ]; then
        echo "ERROR - Approved SQL artifact is missing"
        echo "${SQL_FILE}"
        exit 1
      fi


      if [ ! -s "${HASH_FILE}" ]; then
        echo "ERROR - Approved checksum file is missing or empty"
        echo "${HASH_FILE}"
        exit 1
      fi


      EXPECTED_SHA="$(
        awk '{print $1}' \
          "${HASH_FILE}"
      )"


      ACTUAL_SHA="$(
        sha256sum \
          "${SQL_FILE}" |
        awk '{print $1}'
      )"


      if [ -z "${EXPECTED_SHA}" ]; then
        echo "ERROR - Expected SHA256 is empty"
        echo "Artifact=${artifact}"
        echo "Database=${DATABASE}"
        echo "Schema=${SCHEMA}"
        exit 1
      fi


      if ! [[ "${EXPECTED_SHA}" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo "ERROR - Expected SHA256 is invalid"
        echo "Artifact=${artifact}"
        echo "Database=${DATABASE}"
        echo "Schema=${SCHEMA}"
        exit 1
      fi


      if [ "${EXPECTED_SHA}" != "${ACTUAL_SHA}" ]; then
        echo "ERROR - SQL artifact checksum mismatch"
        echo "Artifact=${artifact}"
        echo "Database=${DATABASE}"
        echo "Schema=${SCHEMA}"
        echo "Expected=${EXPECTED_SHA}"
        echo "Actual=${ACTUAL_SHA}"
        exit 1
      fi


      echo "Checksum verified for ${artifact} ${DATABASE}.${SCHEMA}"

    done


    echo "Approved artifacts verified for ${DATABASE}.${SCHEMA}"


  done < <(
    jq -r \
      --arg database "${DATABASE}" \
      '.[$database][]' \
      /tmp/database-config.json
  )


done < <(
  jq -r \
    'keys[]' \
    /tmp/database-config.json
)


if [ "${SCHEMA_COUNT}" -eq 0 ]; then
  echo "ERROR - No database schemas were found"
  exit 1
fi


echo "Approved database artifacts downloaded and verified"
echo "Configured schema count=${SCHEMA_COUNT}"


# ----------------------------------------------------------
# Assume target AWS account deployment role
#
# All DevSecOps S3 downloads must be completed before this
# point because the AWS credentials are replaced below.
# ----------------------------------------------------------

echo "========================================"
echo "ASSUME TARGET DEPLOY ROLE"
echo "========================================"


ROLE_SESSION_NAME="bach-db-$(
  printf '%s' "${TARGET_ENVIRONMENT}" |
  tr '[:upper:]' '[:lower:]'
)-deploy"


ASSUME_RESULT="$(
  aws sts assume-role \
    --role-arn "${TARGET_ROLE_ARN}" \
    --role-session-name "${ROLE_SESSION_NAME}"
)"


AWS_ACCESS_KEY_ID_VALUE="$(
  jq -r \
    '.Credentials.AccessKeyId // empty' \
    <<< "${ASSUME_RESULT}"
)"


AWS_SECRET_ACCESS_KEY_VALUE="$(
  jq -r \
    '.Credentials.SecretAccessKey // empty' \
    <<< "${ASSUME_RESULT}"
)"


AWS_SESSION_TOKEN_VALUE="$(
  jq -r \
    '.Credentials.SessionToken // empty' \
    <<< "${ASSUME_RESULT}"
)"


if [ -z "${AWS_ACCESS_KEY_ID_VALUE}" ] || \
   [ -z "${AWS_SECRET_ACCESS_KEY_VALUE}" ] || \
   [ -z "${AWS_SESSION_TOKEN_VALUE}" ]
then
  echo "ERROR - AssumeRole did not return valid credentials"
  exit 1
fi


export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID_VALUE}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY_VALUE}"
export AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN_VALUE}"


unset AWS_ACCESS_KEY_ID_VALUE
unset AWS_SECRET_ACCESS_KEY_VALUE
unset AWS_SESSION_TOKEN_VALUE
unset ASSUME_RESULT


echo "Target role assumed successfully"


aws sts get-caller-identity


# ----------------------------------------------------------
# Load target environment DEPLOY database secret
# ----------------------------------------------------------

echo "========================================"
echo "LOAD DEPLOY DATABASE SECRET"
echo "========================================"


SECRET_JSON="$(
  aws secretsmanager get-secret-value \
    --secret-id "${DEPLOY_SECRET_ID}" \
    --query SecretString \
    --output text
)"


if ! jq -e . \
  <<< "${SECRET_JSON}" \
  >/dev/null
then
  echo "ERROR - Deploy database secret is invalid JSON"
  exit 1
fi


export PGHOST="$(
  jq -r \
    '.host // empty' \
    <<< "${SECRET_JSON}"
)"


export PGPORT="$(
  jq -r \
    '.port // empty' \
    <<< "${SECRET_JSON}"
)"


export PGUSER="$(
  jq -r \
    '.username // empty' \
    <<< "${SECRET_JSON}"
)"


export PGPASSWORD="$(
  jq -r \
    '.password // empty' \
    <<< "${SECRET_JSON}"
)"


unset SECRET_JSON


if [ -z "${PGHOST}" ]; then
  echo "ERROR - host is missing from deploy secret"
  exit 1
fi


if [ -z "${PGPORT}" ]; then
  echo "ERROR - port is missing from deploy secret"
  exit 1
fi


if ! [[ "${PGPORT}" =~ ^[0-9]+$ ]]; then
  echo "ERROR - port in deploy secret must be numeric"
  exit 1
fi


if [ -z "${PGUSER}" ]; then
  echo "ERROR - username is missing from deploy secret"
  exit 1
fi


if [ -z "${PGPASSWORD}" ]; then
  echo "ERROR - password is missing from deploy secret"
  exit 1
fi


echo "Deploy database credentials loaded"
echo "Database host=${PGHOST}"
echo "Database port=${PGPORT}"
echo "Database user=${PGUSER}"


# ----------------------------------------------------------
# Verify target baseline for every configured schema
#
# Every configured schema must match before any migration is
# executed. This prevents a partial multi-schema deployment.
# ----------------------------------------------------------

echo "========================================"
echo "VERIFY TARGET DATABASE BASELINE"
echo "========================================"


rm -rf /tmp/current-schema


mkdir -p /tmp/current-schema


while IFS= read -r DATABASE
do

  if [ -z "${DATABASE}" ]; then
    continue
  fi


  echo "Testing database connection to ${DATABASE}"


  psql \
    --host="${PGHOST}" \
    --port="${PGPORT}" \
    --username="${PGUSER}" \
    --dbname="${DATABASE}" \
    --set ON_ERROR_STOP=1 \
    --command="SELECT current_database(), current_user;"


  while IFS= read -r SCHEMA
  do

    if [ -z "${SCHEMA}" ]; then
      echo "ERROR - Empty schema configured for ${DATABASE}"
      exit 1
    fi


    echo "Checking baseline for ${DATABASE}.${SCHEMA}"


    LOCAL_DIR="/tmp/db-release/${DATABASE}/${SCHEMA}"


    CURRENT_DIR="/tmp/current-schema/${DATABASE}/${SCHEMA}"


    mkdir -p "${CURRENT_DIR}"


    SCHEMA_PATTERN="\"${SCHEMA}\""


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
      echo "ERROR - Target schema does not exist"
      echo "Database=${DATABASE}"
      echo "Schema=${SCHEMA}"
      exit 1
    fi


    pg_dump \
      --host="${PGHOST}" \
      --port="${PGPORT}" \
      --username="${PGUSER}" \
      --dbname="${DATABASE}" \
      --schema="${SCHEMA_PATTERN}" \
      --schema-only \
      --no-owner \
      --no-privileges \
      --file="${CURRENT_DIR}/current.sql"


    if [ ! -s "${CURRENT_DIR}/current.sql" ]; then
      echo "ERROR - Current schema dump is empty"
      echo "Database=${DATABASE}"
      echo "Schema=${SCHEMA}"
      exit 1
    fi


    sed \
      -e '/^[[:space:]]*\\restrict\([[:space:]].*\)\{0,1\}[[:space:]]*$/d' \
      -e '/^[[:space:]]*\\unrestrict\([[:space:]].*\)\{0,1\}[[:space:]]*$/d' \
      "${LOCAL_DIR}/baseline.sql" \
      > "${CURRENT_DIR}/baseline-normalized.sql"


    sed \
      -e '/^[[:space:]]*\\restrict\([[:space:]].*\)\{0,1\}[[:space:]]*$/d' \
      -e '/^[[:space:]]*\\unrestrict\([[:space:]].*\)\{0,1\}[[:space:]]*$/d' \
      "${CURRENT_DIR}/current.sql" \
      > "${CURRENT_DIR}/current-normalized.sql"


    BASELINE_META_COMMANDS="$(
      grep \
        -nE \
        '^[[:space:]]*\\' \
        "${CURRENT_DIR}/baseline-normalized.sql" \
        || true
    )"


    CURRENT_META_COMMANDS="$(
      grep \
        -nE \
        '^[[:space:]]*\\' \
        "${CURRENT_DIR}/current-normalized.sql" \
        || true
    )"


    if [ -n "${BASELINE_META_COMMANDS}" ]; then
      echo "ERROR - Approved baseline contains unsupported psql commands"
      echo "${BASELINE_META_COMMANDS}"
      exit 1
    fi


    if [ -n "${CURRENT_META_COMMANDS}" ]; then
      echo "ERROR - Current schema dump contains unsupported psql commands"
      echo "${CURRENT_META_COMMANDS}"
      exit 1
    fi


    if ! cmp -s \
      "${CURRENT_DIR}/baseline-normalized.sql" \
      "${CURRENT_DIR}/current-normalized.sql"
    then
      echo "ERROR - Schema drift detected"
      echo "Database=${DATABASE}"
      echo "Schema=${SCHEMA}"

      diff \
        -u \
        "${CURRENT_DIR}/baseline-normalized.sql" \
        "${CURRENT_DIR}/current-normalized.sql" \
        || true

      exit 1
    fi


    echo "Baseline matched for ${DATABASE}.${SCHEMA}"


  done < <(
    jq -r \
      --arg database "${DATABASE}" \
      '.[$database][]' \
      /tmp/database-config.json
  )


done < <(
  jq -r \
    'keys[]' \
    /tmp/database-config.json
)


echo "All target schemas match the approved baseline"


# ----------------------------------------------------------
# Execute approved forward migrations
#
# This section runs only after every configured schema has
# passed the baseline drift check.
# ----------------------------------------------------------

echo "========================================"
echo "DEPLOY APPROVED DATABASE MIGRATIONS"
echo "========================================"


while IFS= read -r DATABASE
do

  if [ -z "${DATABASE}" ]; then
    continue
  fi


  while IFS= read -r SCHEMA
  do

    if [ -z "${SCHEMA}" ]; then
      echo "ERROR - Empty schema configured for ${DATABASE}"
      exit 1
    fi


    MIGRATION_FILE="/tmp/db-release/${DATABASE}/${SCHEMA}/migration.sql"


    if [ ! -f "${MIGRATION_FILE}" ]; then
      echo "ERROR - Approved migration file is missing"
      echo "${MIGRATION_FILE}"
      exit 1
    fi


    echo "Deploying ${DATABASE}.${SCHEMA}"


    if [ -s "${MIGRATION_FILE}" ]; then

      psql \
        --host="${PGHOST}" \
        --port="${PGPORT}" \
        --username="${PGUSER}" \
        --dbname="${DATABASE}" \
        --set ON_ERROR_STOP=1 \
        --file="${MIGRATION_FILE}"


      echo "Migration completed for ${DATABASE}.${SCHEMA}"

    else

      echo "No migration required for ${DATABASE}.${SCHEMA}"

    fi


  done < <(
    jq -r \
      --arg database "${DATABASE}" \
      '.[$database][]' \
      /tmp/database-config.json
  )


done < <(
  jq -r \
    'keys[]' \
    /tmp/database-config.json
)


echo "========================================"
echo "DATABASE DEPLOYMENT SUCCESSFUL"
echo "========================================"


echo "Release branch=${RELEASE_BRANCH}"
echo "Release commit=${RELEASE_COMMIT}"
echo "Release prefix=${RELEASE_PREFIX}"
echo "Plan environment=${PLAN_ENVIRONMENT}"
echo "Target environment=${TARGET_ENVIRONMENT}"
