#!/usr/bin/env bash
 
set -euo pipefail
 
: "${RELEASE_BRANCH:?RELEASE_BRANCH is required}"
: "${CODEBUILD_RESOLVED_SOURCE_VERSION:?Git commit is required}"
 
COMMIT="${CODEBUILD_RESOLVED_SOURCE_VERSION}"
 
SHORT_COMMIT="${COMMIT:0:8}"
 
SAFE_BRANCH="$(
  printf '%s' "${RELEASE_BRANCH}" |
  sed 's#[^A-Za-z0-9._-]#-#g'
)"
 
RELEASE_PREFIX="releases/${SAFE_BRANCH}/${SHORT_COMMIT}"
 
echo "========================================"
echo "CREATE DATABASE RELEASE"
echo "========================================"
echo "Release branch : ${RELEASE_BRANCH}"
echo "Git commit     : ${COMMIT}"
echo "Release prefix : ${RELEASE_PREFIX}"
 
rm -rf output
 
mkdir -p output/desired
 
zip -qr \
  output/desired/desired-schema.zip \
  Aurora-PostgreSQL-DB
 
(
  cd output/desired
 
  sha256sum desired-schema.zip \
    > desired-schema.zip.sha256
)
 
SHA="$(
  awk '{print $1}' \
  output/desired/desired-schema.zip.sha256
)"
 
jq -n \
  --arg branch "${RELEASE_BRANCH}" \
  --arg commit "${COMMIT}" \
  --arg sha "${SHA}" \
  '{
      release_branch: $branch,
      git_commit: $commit,
      artifact: "desired/desired-schema.zip",
      sha256: $sha
  }' \
  > output/manifest.json
 
printf '%s\n' "${RELEASE_PREFIX}" \
  > output/release-prefix.txt
 
