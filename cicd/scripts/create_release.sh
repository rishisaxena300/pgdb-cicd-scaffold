#!/usr/bin/env bash

set -euo pipefail

# ==========================================================
# Validate required inputs
# ==========================================================

: "${RELEASE_BRANCH:?RELEASE_BRANCH is required}"
: "${RELEASE_BUCKET:?RELEASE_BUCKET is required}"
: "${CODEBUILD_RESOLVED_SOURCE_VERSION:?Git commit is required}"

COMMIT="${CODEBUILD_RESOLVED_SOURCE_VERSION}"
SHORT_COMMIT="${COMMIT:0:8}"

# Convert:
# release/1.0
# to:
# release-1.0

SAFE_BRANCH="$(
  printf '%s' "${RELEASE_BRANCH}" |
  sed 's#[^A-Za-z0-9._-]#-#g'
)"

RELEASE_PREFIX="releases/${SAFE_BRANCH}/${SHORT_COMMIT}"

echo "=========================================="
echo "CREATE DATABASE RELEASE"
echo "=========================================="
echo "Release branch : ${RELEASE_BRANCH}"
echo "Git commit     : ${COMMIT}"
echo "Release prefix : ${RELEASE_PREFIX}"


# ==========================================================
# Validate desired schema directory
# ==========================================================

if [[ ! -d "Aurora-PostgreSQL-DB" ]]; then
  echo "ERROR: Aurora-PostgreSQL-DB directory not found."
  exit 1
fi


# ==========================================================
# Validate POC database/schema
# ==========================================================

DATABASE="$(
  jq -er 'keys[0]' cicd/db/database-config.json
)"

SCHEMA="$(
  jq -er --arg db "${DATABASE}" '.[$db][0]' \
  cicd/db/database-config.json
)"

echo "POC Database : ${DATABASE}"
echo "POC Schema   : ${SCHEMA}"

DESIRED_SCHEMA_PATH="Aurora-PostgreSQL-DB/${DATABASE}/${SCHEMA}"

if [[ ! -d "${DESIRED_SCHEMA_PATH}" ]]; then
  echo "ERROR: Desired schema directory does not exist:"
  echo "${DESIRED_SCHEMA_PATH}"
  exit 1
fi


# ==========================================================
# Create clean build workspace
# ==========================================================

rm -rf output

mkdir -p output/desired


# ==========================================================
# Package desired schema
# ==========================================================

echo "Packaging desired database schema..."

zip -qr \
  output/desired/desired-schema.zip \
  Aurora-PostgreSQL-DB


# ==========================================================
# Generate SHA256
# ==========================================================

(
  cd output/desired

  sha256sum desired-schema.zip \
    > desired-schema.zip.sha256
)

DESIRED_SCHEMA_SHA="$(
  awk '{print $1}' \
  output/desired/desired-schema.zip.sha256
)"


# ==========================================================
# Generate manifest.json
# ==========================================================

jq -n \
  --arg release_branch "${RELEASE_BRANCH}" \
  --arg git_commit "${COMMIT}" \
  --arg sha256 "${DESIRED_SCHEMA_SHA}" \
  '{
      release_branch: $release_branch,
      git_commit: $git_commit,
      artifact: "desired/desired-schema.zip",
      sha256: $sha256
  }' \
  > output/manifest.json


# ==========================================================
# Store release prefix for Pipeline/CodeBuild
# ==========================================================

printf '%s\n' "${RELEASE_PREFIX}" \
  > output/release-prefix.txt


# ==========================================================
# Upload release to S3
# ==========================================================

echo "Uploading release bundle to S3..."

aws s3 cp \
  output/desired/desired-schema.zip \
  "s3://${RELEASE_BUCKET}/${RELEASE_PREFIX}/desired/desired-schema.zip"

aws s3 cp \
  output/desired/desired-schema.zip.sha256 \
  "s3://${RELEASE_BUCKET}/${RELEASE_PREFIX}/desired/desired-schema.zip.sha256"

aws s3 cp \
  output/manifest.json \
  "s3://${RELEASE_BUCKET}/${RELEASE_PREFIX}/manifest.json"


echo "=========================================="
echo "DATABASE RELEASE CREATED SUCCESSFULLY"
echo "=========================================="

echo "Database       : ${DATABASE}"
echo "Schema         : ${SCHEMA}"
echo "Release branch : ${RELEASE_BRANCH}"
echo "Git commit     : ${COMMIT}"
echo "SHA256         : ${DESIRED_SCHEMA_SHA}"
echo "S3 location    : s3://${RELEASE_BUCKET}/${RELEASE_PREFIX}/"
