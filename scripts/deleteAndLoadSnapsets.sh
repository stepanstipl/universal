#!/bin/sh
APP_DIR=${APP_DIR:-"/app"}

STATIC_DATA_DIR=${STATIC_DATA_DIR:-"${APP_DIR}/testData/dbData"}
PREFERENCES_DATA_DIR=${PREFERENCES_DATA_DIR:-"${APP_DIR}/testData/preferences"}
BUILD_DATA_DIR=${BUILD_DATA_DIR:-'/tmp/build/dbData'}

DATALOADER_JS="${APP_DIR}/scripts/deleteAndLoadSnapsets.js"
CONVERT_JS="${APP_DIR}/scripts/convertPrefs.js"

log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') - $1"
}

warm_indices(){
  log "Warming indices..."

  for view in $(curl -s "${COUCHDB_URL}/_design/views/" | jq -r '.views | keys[]'); do
    curl -fsS "${COUCHDB_URL}/_design/views/_view/${view}" >/dev/null
  done

  log "Finished warming indices..."
}

# Verify variables
if [ -z "${COUCHDB_URL}" ]; then
  echo "COUCHDB_URL environment variable must be defined"
  exit 1
fi

COUCHDB_URL_SANITIZED=$(echo "${COUCHDB_URL}" | sed -e 's,\(://\)[^/]*\(@\),\1<SENSITIVE>\2,g')

log 'Starting'
log "CouchDB: ${COUCHDB_URL_SANITIZED}"
log "Clear index: ${CLEAR_INDEX}"
log "Static: ${STATIC_DATA_DIR}"
log "Build: ${BUILD_DATA_DIR}"
log "Working directory: $(pwd)"

# Check we can connect to CouchDB
COUCHDB_URL_ROOT=$(echo "${COUCHDB_URL}" | sed 's/[^\/]*$//g')
RET_CODE=$(curl --write-out '%{http_code}' --silent --output /dev/null "${COUCHDB_URL_ROOT}/_up")
if [ "$RET_CODE" != '200' ]; then
  log "[ERROR] Failed to connect to CouchDB: ${COUCHDB_URL_SANITIZED}"
  exit 1
fi

# Create build dir if it does not exist
if [ ! -d "${BUILD_DATA_DIR}" ]; then
  mkdir -p "${BUILD_DATA_DIR}"
fi

# Convert preferences json5 to GPII keys and preferences safes
if [ -d "${PREFERENCES_DATA_DIR}" ]; then
  node "${CONVERT_JS}" "${PREFERENCES_DATA_DIR}" "${BUILD_DATA_DIR}" snapset
  if [ "$?" != '0' ]; then
    log "[ERROR] ${CONVERT_JS} failed (exit code: $?)"
    exit 1
  fi
else
  log "PREFERENCES_DATA_DIR ($PREFERENCES_DATA_DIR) does not exist, nothing to convert"
fi

# Initialize (possibly clear) data base
if [ "${CLEAR_INDEX}" == 'true' ]; then
  log "Deleting database at ${COUCHDB_URL_SANITIZED}"
  if ! curl -fsS -X DELETE "${COUCHDB_URL}"; then
    log "Error deleting database"
  fi
fi

log "Creating database at ${COUCHDB_URL_SANITIZED}"
if ! curl -fsS -X PUT "${COUCHDB_URL}"; then
  log "Database already exists at ${COUCHDB_URL_SANITIZED}"
fi

# Submit data
node "${DATALOADER_JS}" "${COUCHDB_URL}" "${STATIC_DATA_DIR}" "${BUILD_DATA_DIR}"
err=$?
if [ "${err}" != '0' ]; then
  log "${DATALOADER_JS} failed with ${err}, exiting"
  exit "${err}"
fi

# Warm Data
warm_indices
