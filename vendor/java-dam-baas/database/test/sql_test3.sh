#!/bin/bash

DB="hambooking"
USER="root"
PASS="sergio1234"

LOGFILE="test_results.log"
echo "" >> "$LOGFILE"   # Reset log

TEST_COUNT=0
TOTAL_TESTS=4

# read -s -p "Enter MySQL password: " PASS
# echo ""

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

    # Update progress bar
    local progress=$((TEST_COUNT * 100 / TOTAL_TESTS))
    local filled=$((progress / 10))
    local empty=$((10 - filled))
    local bar=$(printf "%${filled}s" | tr ' ' '#')
    bar+=$(printf "%${empty}s" | tr ' ' '-')

    echo -ne "${YELLOW}[${bar}] ${progress}% (${TEST_COUNT}/${TOTAL_TESTS})${RESET}  ${description}... "

    # Execute SQL
    RAW_OUTPUT=$(mysql -u"$USER" -p"$PASS" "$DB" --silent --skip-column-names -e "$sql" 2>&1)
    OUTPUT=$(echo "$RAW_OUTPUT" | grep -v "Using a password on the command line interface can be insecure")

    # Log everything
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

    # Evaluate result
    if [ "$expected" == "EMPTY_OK" ]; then
        if [ -z "$OUTPUT" ]; then
            echo -e "${GREEN}PASSED${RESET}"
            PASSED=$((PASSED+1))
        else
            echo -e "${RED}FAILED${RESET}"
            FAILED=$((FAILED+1))
        fi
        return
    fi

    if echo "$OUTPUT" | grep -q "$expected"; then
        echo -e "${GREEN}PASSED${RESET}"
        PASSED=$((PASSED+1))
    else
        echo -e "${RED}FAILED${RESET}"
        FAILED=$((FAILED+1))
    fi
}

echo -e "${BLUE}==============================================="
echo -e " TEST CONSTRAINT SERVICES"
echo -e "===============================================${RESET}"

# ============================================================
# TEST 3.1 - Verify seed data
# ============================================================
run_test "3.1 Verify seed data" \
"SELECT name, duration_minutes, base_price FROM services ORDER BY duration_minutes DESC;" \
"Jamón"

# ============================================================
# TEST 3.2 - Duplicate service name
# ============================================================
run_test "3.2 Duplicate service name" \
"INSERT INTO services (name, description, duration_minutes, base_price)
 VALUES ('Jamón', 'Duplicated', 90, 40.00);" \
"ERROR 1062"

# ============================================================
# TEST 3.3 - Invalid duration (0 or negative)
# ============================================================
run_test "3.3 Invalid duration (0 or negative)" \
"INSERT INTO services (name, description, duration_minutes, base_price)
 VALUES ('Invalid', 'Test', 0, 10.00);" \
"ERROR 3819"

# ============================================================
# TEST 3.4 - Negative price
# ============================================================
run_test "3.4 Negative price" \
"INSERT INTO services (name, description, duration_minutes, base_price)
 VALUES ('Invalid2', 'Test', 30, -10.00);" \
"ERROR 3819"

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
