#!/usr/bin/env bash

set -euo pipefail

PURPOSE="${1:?Usage: load_secret.sh plan|deploy}"

case "${PURPOSE}" in
  plan|deploy)
    ;;
  *)
    echo "ERROR: PURPOSE must be plan or deploy."
    exit 1
    ;;
esac

case "${ENVIRONMENT}" in

  T1)
    SECRET_ID="bach2/db-cicd/t1/${PURPOSE}"
    ;;

  T2)
    SECRET_ID="bach2/db-cicd/t2/${PURPOSE}"
    ;;

  *)
    echo "ERROR: ENVIRONMENT must be T1 or T2."
    exit 1
    ;;
esac

echo "Loading ${PURPOSE} database secret for ${ENVIRONMENT}"
echo "Secret ID: ${SECRET_ID}"

SECRET_JSON="$(
  aws secretsmanager get-secret-value \
    --secret-id "${SECRET_ID}" \
    --query SecretString \
    --output text
)"

export PGHOST="$(
  jq -er '.host' <<<"${SECRET_JSON}"
)"

export PGPORT="$(
  jq -er '.port' <<<"${SECRET_JSON}"
)"

export PGUSER="$(
  jq -er '.username' <<<"${SECRET_JSON}"
)"

export PGPASSWORD="$(
  jq -er '.password' <<<"${SECRET_JSON}"
)"

unset SECRET_JSON

echo "Database secret loaded successfully."
echo "Host: ${PGHOST}"
echo "Port: ${PGPORT}"
echo "User: ${PGUSER}"
