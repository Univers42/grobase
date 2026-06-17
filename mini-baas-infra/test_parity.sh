#!/bin/bash
cd mini-baas-infra 2>/dev/null || cd .
bash scripts/verify/parity.sh 2>&1 | head -3
echo "Exit code: $?"
