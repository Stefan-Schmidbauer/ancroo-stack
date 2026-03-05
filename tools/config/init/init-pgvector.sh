#!/bin/bash
# Initialize PGVector extension
# Runs automatically on first PostgreSQL container startup
set -e

PGUSER="${POSTGRES_USER:-postgres}"

echo "Initializing PGVector extension..."

psql -v ON_ERROR_STOP=1 --username "$PGUSER" --dbname "${POSTGRES_DB:-ancroo}" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS vector;
EOSQL

echo "Database initialization completed"
