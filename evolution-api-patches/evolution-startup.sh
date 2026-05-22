#!/bin/bash
set -e

# Install poppler-utils for PDF thumbnail generation in Baileys
apk add --no-cache poppler-utils >/dev/null 2>&1 || true

# Apply Baileys PDF thumbnail patch
node /evolution-patches/patch-baileys.js >/dev/null 2>&1 || true

# Original Evolution API startup
cd /evolution
. ./Docker/scripts/deploy_database.sh && npm run start:prod
