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
# Validate required repository content
# ----------------------------------------------------------

echo "========================================"
echo "VALIDATE RELEASE SOURCE"
echo "========================================"


if [ ! -d "Aurora-PostgreSQL-DB" ]; then
  echo "ERROR - Aurora-PostgreSQL-DB directory is missing"
  exit 1
fi


if [ ! -f "cicd/db/database-config.json" ]; then
  echo "ERROR - cicd/db/database-config.json is missing"
  exit 1
fi


if ! jq -e \
  'type == "object" and length > 0' \
  cicd/db/database-config.json \
  >/dev/null
then
  echo "ERROR - cicd/db/database-config.json is empty or invalid"
  exit 1
fi


echo "Database configuration:"


cat cicd/db/database-config.json


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


  DATABASE_COUNT=$((DATABASE_COUNT + 1))


  if [ ! -d "Aurora-PostgreSQL-DB/${DATABASE}" ]; then
    echo "ERROR - Configured database directory is missing"
    echo "Aurora-PostgreSQL-DB/${DATABASE}"
    exit 1
  fi


  while IFS= read -r SCHEMA
  do

    if [ -z "${SCHEMA}" ]; then
      echo "ERROR - Empty schema configured for database ${DATABASE}"
      exit 1
    fi


    SCHEMA_COUNT=$((SCHEMA_COUNT + 1))


    DESIRED_DIR="Aurora-PostgreSQL-DB/${DATABASE}/${SCHEMA}"


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
      cicd/db/database-config.json
  )


done < <(
  jq -r \
    'keys[]' \
    cicd/db/database-config.json
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
# Create desired schema bundle
#
# The bundle contains:
#
#   Aurora-PostgreSQL-DB/
#   cicd/db/database-config.json
#
# This ensures that the immutable release contains both:
#   - desired database DDL
#   - exact database/schema membership for that release
# ----------------------------------------------------------

echo "========================================"
echo "CREATE DESIRED SCHEMA BUNDLE"
echo "========================================"


zip \
  -qr \
  output/desired/desired-schema.zip \
  Aurora-PostgreSQL-DB \
  cicd/db/database-config.json


if [ ! -s "output/desired/desired-schema.zip" ]; then
  echo "ERROR - desired-schema.zip was not created"
  exit 1
fi


echo "Desired schema bundle created"


# ----------------------------------------------------------
# Verify bundle content
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


if [ ! -d "/tmp/db-desired-bundle-verify/Aurora-PostgreSQL-DB" ]; then
  echo "ERROR - desired bundle does not contain Aurora-PostgreSQL-DB"
  exit 1
fi


if [ ! -f "/tmp/db-desired-bundle-verify/cicd/db/database-config.json" ]; then
  echo "ERROR - desired bundle does not contain database-config.json"
  exit 1
fi


if ! cmp -s \
  cicd/db/database-config.json \
  /tmp/db-desired-bundle-verify/cicd/db/database-config.json
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


SHA="$(
  awk '{print $1}' \
    output/desired/desired-schema.zip.sha256
)"


if ! [[ "${SHA}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ERROR - Invalid desired schema SHA256"
  echo "SHA256=${SHA}"
  exit 1
fi


echo "Desired schema SHA256=${SHA}"


# ----------------------------------------------------------
# Create release manifest
# ----------------------------------------------------------

echo "========================================"
echo "CREATE RELEASE MANIFEST"
echo "========================================"


jq -n \
  --arg branch "${RELEASE_BRANCH}" \
  --arg commit "${COMMIT}" \
  --arg artifact "desired/desired-schema.zip" \
  --arg sha256 "${SHA}" \
  --arg config_path "cicd/db/database-config.json" \
  --argjson database_count "${DATABASE_COUNT}" \
  --argjson schema_count "${SCHEMA_COUNT}" \
  '{
    release_branch: $branch,
    git_commit: $commit,
    desired_schema: {
      artifact: $artifact,
      sha256: $sha256
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


echo "Release branch : ${RELEASE_BRANCH}"
echo "Git commit     : ${COMMIT}"
echo "Databases      : ${DATABASE_COUNT}"
echo "Schemas        : ${SCHEMA_COUNT}"
echo "Artifact       : desired/desired-schema.zip"
echo "SHA256         : ${SHA}"
echo "Release prefix : ${RELEASE_PREFIX}"
