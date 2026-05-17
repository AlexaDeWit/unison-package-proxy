#!/usr/bin/env bash
# Integration test for the npm registry proxy.
# Prerequisites:
#   1. The proxy must be running: ucm run NpmRegistryProxy.main
#   2. npm must be available
#
# This script uses a local .npmrc pointing to localhost:4873

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROXY_URL="http://localhost:4873"

echo "=== npm Registry Proxy Integration Test ==="
echo ""

# Check if proxy is reachable
echo "1. Checking proxy is reachable..."
if ! curl -s --max-time 5 "$PROXY_URL/" > /dev/null 2>&1; then
  echo "   FAIL: Proxy not reachable at $PROXY_URL"
  echo "   Start it with: ucm run NpmRegistryProxy.main"
  exit 1
fi
echo "   OK: Proxy is running at $PROXY_URL"
echo ""

# Test: fetch axios packument metadata
echo "2. Fetching axios package metadata via proxy..."
RESPONSE=$(curl -s --max-time 30 "$PROXY_URL/axios" -H "Accept: application/json")
if echo "$RESPONSE" | grep -q '"name":"axios"'; then
  echo "   OK: Got axios packument metadata"
else
  echo "   FAIL: Did not get valid axios metadata"
  echo "   Response (first 500 chars): ${RESPONSE:0:500}"
  exit 1
fi
echo ""

# Test: npm view axios through proxy
echo "3. Running 'npm view axios version' through proxy..."
AXIOS_VERSION=$(npm view axios version --registry="$PROXY_URL" 2>&1)
if [[ "$AXIOS_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  echo "   OK: axios latest version is $AXIOS_VERSION"
else
  echo "   FAIL: Could not get axios version via npm"
  echo "   Output: $AXIOS_VERSION"
  exit 1
fi
echo ""

# Test: npm pack axios (downloads the tarball)
echo "4. Running 'npm pack axios' through proxy..."
rm -f axios-*.tgz
PACK_OUTPUT=$(npm pack axios --registry="$PROXY_URL" 2>&1)
if ls axios-*.tgz 1>/dev/null 2>&1; then
  TARBALL=$(ls axios-*.tgz)
  echo "   OK: Downloaded tarball: $TARBALL ($(du -h "$TARBALL" | cut -f1))"
  rm -f axios-*.tgz
else
  echo "   FAIL: npm pack did not produce a tarball"
  echo "   Output: $PACK_OUTPUT"
  exit 1
fi
echo ""

echo "=== All integration tests passed! ==="
