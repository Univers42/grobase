#!/bin/bash
# ============================================
# Backend: Show Service Summary
# Usage: make services
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "📊 Backend Service Summary"

cd "$BACKEND_PATH"

echo "Services by line count (top 20):"
echo "────────────────────────────────"
for f in $(find src -name "*.service.ts" ! -name "*.spec.ts" 2>/dev/null | sort); do
    lines=$(wc -l < "$f")
    spec="${f%.ts}.spec.ts"
    hasspec="NO"
    [ -f "$spec" ] && hasspec="YES"
    printf "%4d lines, spec: %s - %s\n" "$lines" "$hasspec" "$f"
done | sort -rn | head -20

echo ""
echo "────────────────────────────────"
TOTAL=$(find src -name "*.service.ts" ! -name "*.spec.ts" 2>/dev/null | wc -l)
WITH_SPEC=$(for f in $(find src -name "*.service.ts" ! -name "*.spec.ts" 2>/dev/null); do
    spec="${f%.ts}.spec.ts"
    [ -f "$spec" ] && echo 1
done | wc -l)

echo "Total services: $TOTAL"
echo "With spec files: $WITH_SPEC"
echo "Coverage: $(( WITH_SPEC * 100 / TOTAL ))%"
