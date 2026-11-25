#!/usr/bin/env bash

set -euo pipefail

: "${RELEASE_BRANCH:?RELEASE_BRANCH is required}"
: "${RELEASE_BUCKET:?RELEASE_BUCKET is required}"

echo "========================================"
echo "CREATE DATABASE RELEASE"
echo "========================================"

COMMIT="$(git rev-parse HEAD)"

if [[ -z "${COMMIT}" ]]; then
  echo "ERROR: Unable to determine Git commit."
  exit 1
fi

SHORT_COMMIT="${COMMIT:0:8}"

SAFE_BRANCH="$(
  printf '%s' "${RELEASE_BRANCH}" |
  sed 's#[^A-Za-z0-9._-]#-#g'
)"

RELEASE_PREFIX="releases/${SAFE_BRANCH}/${SHORT_COMMIT}"

echo "Release branch : ${RELEASE_BRANCH}"
echo "Git commit     : ${COMMIT}"
echo "Release prefix : ${RELEASE_PREFIX}"

rm -rf output

mkdir -p output/desired

test -d Aurora-PostgreSQL-DB

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

echo "Desired schema bundle successfully created."
