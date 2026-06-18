#!/bin/bash

DB="hambooking"
USER="root"
PASS="sergio1234"

LOGFILE="test_results.log"
echo "" >> "$LOGFILE"   # Append log

TEST_COUNT=0
TOTAL_TESTS=5

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

PASSED=0
FAILED=0

print_header() {
    echo -e "\n${BLUE}===============================================${RESET}"
    echo -e "${BLUE}TEST: $1${RESET}"
    echo -e "${BLUE}===============================================${RESET}"
}

run_test() {
    local description="$1"
    local sql="$2"
    local expected="$3"

    TEST_COUNT=$((TEST_COUNT+1))

    # Progress bar
    local progress=$((TEST_COUNT * 100 / TOTAL_TESTS))
    local filled=$((progress / 10))
    local empty=$((10 - filled))
    local bar=$(printf "%${filled}s" | tr ' ' '#')
    bar+=$(printf "%${empty}s" | tr ' ' '-')

    echo -ne "${YELLOW}[${bar}] ${progress}% (${TEST_COUNT}/${TOTAL_TESTS})${RESET}  ${description}... "

    RAW_OUTPUT=$(mysql -u"$USER" -p"$PASS" "$DB" --silent --skip-column-names -e "$sql" 2>&1)
    OUTPUT=$(echo "$RAW_OUTPUT" | grep -v "Using a password")

    {
        echo ""
        echo "==============================================="
        echo "TEST $TEST_COUNT: $description"
        echo "==============================================="
        echo "SQL:"
        echo "$sql"
        echo ""
        echo "Output:"
        echo "$OUTPUT"
        echo ""
    } >> "$LOGFILE"

    # Evaluate
    if echo "$OUTPUT" | grep -q "$expected"; then
        echo -e "${GREEN}PASSED${RESET}"
        PASSED=$((PASSED+1))
    else
        echo -e "${RED}FAILED${RESET}"
        FAILED=$((FAILED+1))
    fi
}

echo -e "${BLUE}==============================================="
echo -e " TEST SUITE 6: INDEXES & PERFORMANCE"
echo -e "===============================================${RESET}"

# ============================================================
# TEST 6.1 - Verify indexes exist
# ============================================================
run_test "6.1 Indexes exist in users" \
"SHOW INDEX FROM users;" \
"PRIMARY"

run_test "6.1 Indexes exist in carvers" \
"SHOW INDEX FROM carvers;" \
"PRIMARY"

run_test "6.1 Indexes exist in reservations" \
"SHOW INDEX FROM reservations;" \
"idx_res"

# ============================================================
# TEST 6.2 - Explain plan uses correct index (client/date)
# ============================================================
run_test "6.2 Explain uses idx_res_client_date" \
"EXPLAIN SELECT * FROM reservations
 WHERE client_id = 2 AND reservation_date = '2025-12-20';" \
"idx_res_client_date"

# ============================================================
# TEST 6.3 - Explain plan uses correct index (carver/date/status)
# ============================================================
run_test "6.3 Explain uses idx_res_carver_date_status" \
"EXPLAIN SELECT * FROM reservations
 WHERE carver_id = 1 AND reservation_date = '2025-12-20' AND status = 'PENDING';" \
"idx_res_carver_date_status"

# ============================================================
# FINAL SUMMARY
# ============================================================
echo ""
echo -e "${BLUE}==============================================="
echo -e " FINAL SUMMARY"
echo -e "===============================================${RESET}"
echo -e "${GREEN}✔ Passed: $PASSED${RESET}"
echo -e "${RED}✘ Failed: $FAILED${RESET}"
echo ""
echo -e "Full details saved in: ${YELLOW}$LOGFILE${RESET}"
