#!/usr/bin/env bash

set -euo pipefail


: "${RELEASE_BRANCH:?RELEASE_BRANCH is required}"
: "${RELEASE_BUCKET:?RELEASE_BUCKET is required}"


echo "========================================"
echo "CREATE DATABASE RELEASE"
echo "========================================"


# ----------------------------------------------------------
# Determine exact Git commit
# ----------------------------------------------------------

COMMIT="$(
  git rev-parse HEAD
)"


if [ -z "${COMMIT}" ]; then
  echo "ERROR - Unable to determine Git commit"
  exit 1
fi


if ! [[ "${COMMIT}" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "ERROR - Git commit is not a full 40-character SHA"
  echo "Received commit is '${COMMIT}'"
  exit 1
fi


SHORT_COMMIT="${COMMIT:0:8}"


# ----------------------------------------------------------
# Create safe S3 branch key
# ----------------------------------------------------------

SAFE_BRANCH="$(
  printf '%s' "${RELEASE_BRANCH}" |
  sed 's#[^A-Za-z0-9._-]#-#g'
)"


if [ -z "${SAFE_BRANCH}" ]; then
  echo "ERROR - Unable to create safe release branch key"
  exit 1
fi


RELEASE_PREFIX="releases/${SAFE_BRANCH}/${SHORT_COMMIT}"


echo "Release branch : ${RELEASE_BRANCH}"
echo "Git commit     : ${COMMIT}"
echo "Release prefix : ${RELEASE_PREFIX}"


# ----------------------------------------------------------
# Repository paths
# ----------------------------------------------------------

DATABASE_ROOT="Aurora-PostgreSQL-DB"

DATABASE_CONFIG="cicd/db/database-config.json"

DEPLOY_BUILDSPEC_SOURCE="cicd/db/buildspec-deploy.yml"

DEPLOY_SCRIPT_SOURCE="cicd/scripts/deploy.sh"


# ----------------------------------------------------------
# Validate required repository content
# ----------------------------------------------------------

echo "========================================"
echo "VALIDATE RELEASE SOURCE"
echo "========================================"


if [ ! -d "${DATABASE_ROOT}" ]; then
  echo "ERROR - ${DATABASE_ROOT} directory is missing"
  exit 1
fi


if [ ! -f "${DATABASE_CONFIG}" ]; then
  echo "ERROR - ${DATABASE_CONFIG} is missing"
  exit 1
fi


if [ ! -f "${DEPLOY_BUILDSPEC_SOURCE}" ]; then
  echo "ERROR - ${DEPLOY_BUILDSPEC_SOURCE} is missing"
  exit 1
fi


if [ ! -s "${DEPLOY_BUILDSPEC_SOURCE}" ]; then
  echo "ERROR - ${DEPLOY_BUILDSPEC_SOURCE} is empty"
  exit 1
fi


if [ ! -f "${DEPLOY_SCRIPT_SOURCE}" ]; then
  echo "ERROR - ${DEPLOY_SCRIPT_SOURCE} is missing"
  exit 1
fi


if [ ! -s "${DEPLOY_SCRIPT_SOURCE}" ]; then
  echo "ERROR - ${DEPLOY_SCRIPT_SOURCE} is empty"
  exit 1
fi


if ! jq -e \
  'type == "object" and length > 0' \
  "${DATABASE_CONFIG}" \
  >/dev/null
then
  echo "ERROR - ${DATABASE_CONFIG} is empty or invalid"
  exit 1
fi


if ! grep -q \
  '^version:[[:space:]]*0\.2[[:space:]]*$' \
  "${DEPLOY_BUILDSPEC_SOURCE}"
then
  echo "ERROR - Deployment BuildSpec does not declare version 0.2"
  echo "File=${DEPLOY_BUILDSPEC_SOURCE}"
  exit 1
fi


if ! head -1 "${DEPLOY_SCRIPT_SOURCE}" |
   grep -q '^#!/usr/bin/env bash$'
then
  echo "ERROR - deploy.sh does not have the expected Bash shebang"
  echo "File=${DEPLOY_SCRIPT_SOURCE}"
  exit 1
fi


echo "Database configuration:"


cat "${DATABASE_CONFIG}"


echo "Required deployment files found:"

echo "${DEPLOY_BUILDSPEC_SOURCE}"

echo "${DEPLOY_SCRIPT_SOURCE}"


# ----------------------------------------------------------
# Validate configured database/schema directories
# ----------------------------------------------------------

echo "========================================"
echo "VALIDATE CONFIGURED DATABASE SCHEMAS"
echo "========================================"


DATABASE_COUNT=0

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


  DATABASE_COUNT=$((DATABASE_COUNT + 1))


  if [ ! -d "${DATABASE_ROOT}/${DATABASE}" ]; then
    echo "ERROR - Configured database directory is missing"
    echo "${DATABASE_ROOT}/${DATABASE}"
    exit 1
  fi


  while IFS= read -r SCHEMA
  do

    if [ -z "${SCHEMA}" ]; then
      echo "ERROR - Empty schema configured for database ${DATABASE}"
      exit 1
    fi


    if ! [[ "${SCHEMA}" =~ ^[A-Za-z_][A-Za-z0-9_\$]*$ ]]; then
      echo "ERROR - Unsupported schema identifier"
      echo "Schema=${SCHEMA}"
      exit 1
    fi


    SCHEMA_COUNT=$((SCHEMA_COUNT + 1))


    DESIRED_DIR="${DATABASE_ROOT}/${DATABASE}/${SCHEMA}"


    if [ ! -d "${DESIRED_DIR}" ]; then
      echo "ERROR - Configured schema directory is missing"
      echo "${DESIRED_DIR}"
      exit 1
    fi


    SQL_FILE_COUNT="$(
      find "${DESIRED_DIR}" \
        -type f \
        -name "*.sql" |
      wc -l
    )"


    if [ "${SQL_FILE_COUNT}" -eq 0 ]; then
      echo "ERROR - No SQL files found for configured schema"
      echo "${DATABASE}.${SCHEMA}"
      exit 1
    fi


    echo "Validated ${DATABASE}.${SCHEMA}"
    echo "SQL files=${SQL_FILE_COUNT}"


  done < <(
    jq -r \
      --arg database "${DATABASE}" \
      '.[$database][]' \
      "${DATABASE_CONFIG}"
  )


done < <(
  jq -r \
    'keys[]' \
    "${DATABASE_CONFIG}"
)


if [ "${DATABASE_COUNT}" -eq 0 ]; then
  echo "ERROR - No databases configured"
  exit 1
fi


if [ "${SCHEMA_COUNT}" -eq 0 ]; then
  echo "ERROR - No schemas configured"
  exit 1
fi


echo "Configured databases=${DATABASE_COUNT}"

echo "Configured schemas=${SCHEMA_COUNT}"


# ----------------------------------------------------------
# Recreate release output
# ----------------------------------------------------------

echo "========================================"
echo "PREPARE RELEASE OUTPUT"
echo "========================================"


rm -rf output


mkdir -p \
  output/desired


# ----------------------------------------------------------
# Package deployment implementation
#
# The repository files are renamed in the release:
#
# cicd/db/buildspec-deploy.yml -> output/deployspec.yml
# cicd/scripts/deploy.sh       -> output/deploy.sh
# ----------------------------------------------------------

echo "========================================"
echo "PACKAGE DEPLOYMENT FILES"
echo "========================================"


cp \
  "${DEPLOY_BUILDSPEC_SOURCE}" \
  output/deployspec.yml


cp \
  "${DEPLOY_SCRIPT_SOURCE}" \
  output/deploy.sh


chmod +x \
  output/deploy.sh


if [ ! -s "output/deployspec.yml" ]; then
  echo "ERROR - output/deployspec.yml was not created"
  exit 1
fi


if [ ! -s "output/deploy.sh" ]; then
  echo "ERROR - output/deploy.sh was not created"
  exit 1
fi


if ! cmp -s \
  "${DEPLOY_BUILDSPEC_SOURCE}" \
  output/deployspec.yml
then
  echo "ERROR - Packaged deployspec.yml differs from source"
  exit 1
fi


if ! cmp -s \
  "${DEPLOY_SCRIPT_SOURCE}" \
  output/deploy.sh
then
  echo "ERROR - Packaged deploy.sh differs from source"
  exit 1
fi


echo "Deployment files packaged successfully"


# ----------------------------------------------------------
# Create deployment-file checksums
# ----------------------------------------------------------

echo "========================================"
echo "CREATE DEPLOYMENT FILE CHECKSUMS"
echo "========================================"


(
  cd output

  sha256sum \
    deployspec.yml \
    > deployspec.yml.sha256

  sha256sum \
    deploy.sh \
    > deploy.sh.sha256
)


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
  echo "ERROR - Deployment file checksum verification failed"
  exit 1
fi


DEPLOYSPEC_SHA="$(
  awk '{print $1}' \
    output/deployspec.yml.sha256
)"


DEPLOY_SCRIPT_SHA="$(
  awk '{print $1}' \
    output/deploy.sh.sha256
)"


if ! [[ "${DEPLOYSPEC_SHA}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ERROR - Invalid deployspec.yml SHA256"
  exit 1
fi


if ! [[ "${DEPLOY_SCRIPT_SHA}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ERROR - Invalid deploy.sh SHA256"
  exit 1
fi


echo "deployspec.yml SHA256=${DEPLOYSPEC_SHA}"

echo "deploy.sh SHA256=${DEPLOY_SCRIPT_SHA}"


# ----------------------------------------------------------
# Create desired schema bundle
#
# The bundle contains:
#
# Aurora-PostgreSQL-DB/
# cicd/db/database-config.json
# ----------------------------------------------------------

echo "========================================"
echo "CREATE DESIRED SCHEMA BUNDLE"
echo "========================================"


zip \
  -qr \
  output/desired/desired-schema.zip \
  "${DATABASE_ROOT}" \
  "${DATABASE_CONFIG}"


if [ ! -s "output/desired/desired-schema.zip" ]; then
  echo "ERROR - desired-schema.zip was not created"
  exit 1
fi


echo "Desired schema bundle created"


# ----------------------------------------------------------
# Verify desired schema bundle content
# ----------------------------------------------------------

echo "========================================"
echo "VERIFY DESIRED SCHEMA BUNDLE"
echo "========================================"


rm -rf /tmp/db-desired-bundle-verify


mkdir -p \
  /tmp/db-desired-bundle-verify


unzip \
  -q \
  output/desired/desired-schema.zip \
  -d /tmp/db-desired-bundle-verify


if [ ! -d "/tmp/db-desired-bundle-verify/${DATABASE_ROOT}" ]; then
  echo "ERROR - Desired bundle does not contain ${DATABASE_ROOT}"
  exit 1
fi


if [ ! -f "/tmp/db-desired-bundle-verify/${DATABASE_CONFIG}" ]; then
  echo "ERROR - Desired bundle does not contain ${DATABASE_CONFIG}"
  exit 1
fi


if ! cmp -s \
  "${DATABASE_CONFIG}" \
  "/tmp/db-desired-bundle-verify/${DATABASE_CONFIG}"
then
  echo "ERROR - database-config.json changed inside desired bundle"
  exit 1
fi


echo "Desired bundle content verified"


echo "Bundle files:"


unzip \
  -Z1 \
  output/desired/desired-schema.zip |
sort


# ----------------------------------------------------------
# Create desired schema checksum
# ----------------------------------------------------------

echo "========================================"
echo "CREATE DESIRED SCHEMA CHECKSUM"
echo "========================================"


(
  cd output/desired

  sha256sum \
    desired-schema.zip \
    > desired-schema.zip.sha256
)


if ! (
  cd output/desired

  sha256sum \
    --check \
    desired-schema.zip.sha256
)
then
  echo "ERROR - Desired schema checksum validation failed"
  exit 1
fi


DESIRED_SCHEMA_SHA="$(
  awk '{print $1}' \
    output/desired/desired-schema.zip.sha256
)"


if ! [[ "${DESIRED_SCHEMA_SHA}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ERROR - Invalid desired schema SHA256"
  echo "SHA256=${DESIRED_SCHEMA_SHA}"
  exit 1
fi


echo "Desired schema SHA256=${DESIRED_SCHEMA_SHA}"


# ----------------------------------------------------------
# Create release manifest
# ----------------------------------------------------------

echo "========================================"
echo "CREATE RELEASE MANIFEST"
echo "========================================"


jq -n \
  --arg branch "${RELEASE_BRANCH}" \
  --arg commit "${COMMIT}" \
  --arg desired_artifact "desired/desired-schema.zip" \
  --arg desired_sha256 "${DESIRED_SCHEMA_SHA}" \
  --arg config_path "cicd/db/database-config.json" \
  --arg deployspec_artifact "deployspec.yml" \
  --arg deployspec_sha256 "${DEPLOYSPEC_SHA}" \
  --arg deploy_script_artifact "deploy.sh" \
  --arg deploy_script_sha256 "${DEPLOY_SCRIPT_SHA}" \
  --argjson database_count "${DATABASE_COUNT}" \
  --argjson schema_count "${SCHEMA_COUNT}" \
  '{
    release_branch: $branch,
    git_commit: $commit,
    desired_schema: {
      artifact: $desired_artifact,
      sha256: $desired_sha256
    },
    deployment: {
      buildspec: {
        artifact: $deployspec_artifact,
        sha256: $deployspec_sha256
      },
      script: {
        artifact: $deploy_script_artifact,
        sha256: $deploy_script_sha256
      }
    },
    database_config: $config_path,
    database_count: $database_count,
    schema_count: $schema_count
  }' \
  > output/manifest.json


if ! jq -e . \
  output/manifest.json \
  >/dev/null
then
  echo "ERROR - Generated manifest is not valid JSON"
  exit 1
fi


echo "Release manifest:"


cat output/manifest.json


# ----------------------------------------------------------
# Create release prefix file
# ----------------------------------------------------------

echo "========================================"
echo "CREATE RELEASE PREFIX"
echo "========================================"


printf '%s\n' \
  "${RELEASE_PREFIX}" \
  > output/release-prefix.txt


if [ ! -s "output/release-prefix.txt" ]; then
  echo "ERROR - release-prefix.txt was not created"
  exit 1
fi


# ----------------------------------------------------------
# Final verification
# ----------------------------------------------------------

echo "========================================"
echo "VERIFY RELEASE OUTPUT"
echo "========================================"


for required_file in \
  output/deployspec.yml \
  output/deployspec.yml.sha256 \
  output/deploy.sh \
  output/deploy.sh.sha256 \
  output/desired/desired-schema.zip \
  output/desired/desired-schema.zip.sha256 \
  output/manifest.json \
  output/release-prefix.txt
do

  if [ ! -s "${required_file}" ]; then
    echo "ERROR - Required release file is missing or empty"
    echo "${required_file}"
    exit 1
  fi

  echo "Verified ${required_file}"

done


echo "========================================"
echo "DATABASE RELEASE CREATED SUCCESSFULLY"
echo "========================================"


echo "Release branch  : ${RELEASE_BRANCH}"

echo "Git commit      : ${COMMIT}"

echo "Databases       : ${DATABASE_COUNT}"

echo "Schemas         : ${SCHEMA_COUNT}"

echo "Desired artifact: desired/desired-schema.zip"

echo "Desired SHA256  : ${DESIRED_SCHEMA_SHA}"

echo "Deploy BuildSpec: deployspec.yml"

echo "Deployspec SHA  : ${DEPLOYSPEC_SHA}"

echo "Deploy script   : deploy.sh"

echo "Deploy script SHA: ${DEPLOY_SCRIPT_SHA}"

echo "Release prefix  : ${RELEASE_PREFIX}"
