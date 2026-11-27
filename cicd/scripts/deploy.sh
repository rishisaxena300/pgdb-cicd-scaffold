#!/usr/bin/env bash

set -euo pipefail


echo "========================================"
echo "DATABASE RELEASE DEPLOYMENT"
echo "========================================"


# ----------------------------------------------------------
# Validate configuration
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


TARGET_ENVIRONMENT="$(
  printf '%s' "${TARGET_ENVIRONMENT}" |
  xargs |
  tr '[:lower:]' '[:upper:]'
)"


export TARGET_ENVIRONMENT


echo "Target environment=${TARGET_ENVIRONMENT}"
echo "Release bucket=${RELEASE_BUCKET}"


# ----------------------------------------------------------
# Read approved release pointer
# ----------------------------------------------------------

echo "========================================"
echo "READ APPROVED RELEASE"
echo "========================================"


aws s3 cp \
  "s3://${RELEASE_BUCKET}/approved-release/current.json" \
  /tmp/approved-release.json


if ! jq -e \
  '.approved == true' \
  /tmp/approved-release.json \
  >/dev/null
then

  echo "ERROR - Release is not approved"
  exit 1

fi


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


if [ -z "${RELEASE_BRANCH}" ]; then
  echo "ERROR - release_branch is missing"
  exit 1
fi


if ! [[ "${RELEASE_COMMIT}" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "ERROR - release_commit is invalid"
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
    echo "Value=${PLAN_ENVIRONMENT}"
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


# ----------------------------------------------------------
# Verify manifest
# ----------------------------------------------------------

echo "========================================"
echo "VERIFY RELEASE MANIFEST"
echo "========================================"


aws s3 cp \
  "s3://${RELEASE_BUCKET}/${RELEASE_PREFIX}/manifest.json" \
  /tmp/release-manifest.json


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
  exit 1

fi


if [ "${MANIFEST_COMMIT}" != "${RELEASE_COMMIT}" ]; then

  echo "ERROR - Manifest commit mismatch"
  exit 1

fi


echo "Release manifest verified"


# ----------------------------------------------------------
# Download desired bundle
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


EXPECTED_SHA="$(
  awk '{print $1}' \
    /tmp/desired-schema.zip.sha256
)"


ACTUAL_SHA="$(
  sha256sum \
    /tmp/desired-schema.zip |
  awk '{print $1}'
)"


if [ "${EXPECTED_SHA}" != "${ACTUAL_SHA}" ]; then

  echo "ERROR - Desired schema checksum mismatch"
  exit 1

fi


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

  echo "ERROR - database-config.json not found"
  exit 1

fi


cp \
  "${CONFIG_FILE}" \
  /tmp/database-config.json


echo "Database configuration:"


cat /tmp/database-config.json


# ----------------------------------------------------------
# Download approved baseline and migration
# ----------------------------------------------------------

echo "========================================"
echo "DOWNLOAD APPROVED DATABASE ARTIFACTS"
echo "========================================"


rm -rf /tmp/db-release


mkdir -p /tmp/db-release


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


    LOCAL_DIR="/tmp/db-release/${DATABASE}/${SCHEMA}"


    mkdir -p "${LOCAL_DIR}"


    BASELINE_URI="s3://${RELEASE_BUCKET}/${RELEASE_PREFIX}/${PLAN_ENVIRONMENT}/baseline/${DATABASE}/${SCHEMA}"


    FORWARD_URI="s3://${RELEASE_BUCKET}/${RELEASE_PREFIX}/${PLAN_ENVIRONMENT}/forward/${DATABASE}/${SCHEMA}"


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


    BASELINE_EXPECTED_SHA="$(
      awk '{print $1}' \
        "${LOCAL_DIR}/baseline.sql.sha256"
    )"


    BASELINE_ACTUAL_SHA="$(
      sha256sum \
        "${LOCAL_DIR}/baseline.sql" |
      awk '{print $1}'
    )"


    if [ "${BASELINE_EXPECTED_SHA}" != "${BASELINE_ACTUAL_SHA}" ]; then

      echo "ERROR - Baseline checksum mismatch"
      echo "Database=${DATABASE}"
      echo "Schema=${SCHEMA}"

      exit 1

    fi


    MIGRATION_EXPECTED_SHA="$(
      awk '{print $1}' \
        "${LOCAL_DIR}/migration.sql.sha256"
    )"


    MIGRATION_ACTUAL_SHA="$(
      sha256sum \
        "${LOCAL_DIR}/migration.sql" |
      awk '{print $1}'
    )"


    if [ "${MIGRATION_EXPECTED_SHA}" != "${MIGRATION_ACTUAL_SHA}" ]; then

      echo "ERROR - Migration checksum mismatch"
      echo "Database=${DATABASE}"
      echo "Schema=${SCHEMA}"

      exit 1

    fi


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


# ----------------------------------------------------------
# Assume target AWS account role
# ----------------------------------------------------------

echo "========================================"
echo "ASSUME TARGET DEPLOY ROLE"
echo "========================================"


ASSUME_RESULT="$(
  aws sts assume-role \
    --role-arn "${TARGET_ROLE_ARN}" \
    --role-session-name "bach-db-${TARGET_ENVIRONMENT,,}-deploy"
)"


export AWS_ACCESS_KEY_ID="$(
  jq -r \
    '.Credentials.AccessKeyId // empty' \
    <<< "${ASSUME_RESULT}"
)"


export AWS_SECRET_ACCESS_KEY="$(
  jq -r \
    '.Credentials.SecretAccessKey // empty' \
    <<< "${ASSUME_RESULT}"
)"


export AWS_SESSION_TOKEN="$(
  jq -r \
    '.Credentials.SessionToken // empty' \
    <<< "${ASSUME_RESULT}"
)"


if [ -z "${AWS_ACCESS_KEY_ID}" ] || \
   [ -z "${AWS_SECRET_ACCESS_KEY}" ] || \
   [ -z "${AWS_SESSION_TOKEN}" ]
then

  echo "ERROR - AssumeRole did not return valid credentials"
  exit 1

fi


echo "Target role assumed successfully"


aws sts get-caller-identity


# ----------------------------------------------------------
# Load DEPLOY database secret
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


if [ -z "${PGHOST}" ] || \
   [ -z "${PGPORT}" ] || \
   [ -z "${PGUSER}" ] || \
   [ -z "${PGPASSWORD}" ]
then

  echo "ERROR - Deploy database secret is incomplete"
  exit 1

fi


echo "Deploy database credentials loaded"
echo "Database host=${PGHOST}"
echo "Database port=${PGPORT}"
echo "Database user=${PGUSER}"


# ----------------------------------------------------------
# Verify baseline for every configured schema
#
# All baselines are checked BEFORE any SQL is executed.
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


  psql \
    --host="${PGHOST}" \
    --port="${PGPORT}" \
    --username="${PGUSER}" \
    --dbname="${DATABASE}" \
    --set ON_ERROR_STOP=1 \
    --command="SELECT current_database(), current_user;"


  while IFS= read -r SCHEMA
  do

    LOCAL_DIR="/tmp/db-release/${DATABASE}/${SCHEMA}"


    CURRENT_DIR="/tmp/current-schema/${DATABASE}/${SCHEMA}"


    mkdir -p "${CURRENT_DIR}"


    SCHEMA_PATTERN="\"${SCHEMA}\""


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
# Execute approved migrations
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
echo "Plan environment=${PLAN_ENVIRONMENT}"
echo "Target environment=${TARGET_ENVIRONMENT}"
