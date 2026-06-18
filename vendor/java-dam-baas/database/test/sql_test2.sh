#!/bin/bash

DB="hambooking"
USER="root"
PASS="sergio1234"

LOGFILE="test_results.log"
echo "" >> "$LOGFILE"   # Reset log

TEST_COUNT=0
TOTAL_TESTS=10

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
echo -e " TEST CONSTRAINT CARVERS"
echo -e "===============================================${RESET}"

# ============================================================
# TEST 2.1 - Create user for carver
# ============================================================
run_test "2.1 Create user for carver" \
"INSERT INTO users (dni, first_name, last_name, email, phone, password_hash, role)
 VALUES ('33333333P', 'Carlos', 'Martínez', 'carlos@hambooking.com', '600666666', '\$2a\$10\$test', 'CLIENT');" \
"EMPTY_OK"

# Retrieve dynamic user_id
CARLOS_ID=$(mysql -u"$USER" -p"$PASS" "$DB" --silent --skip-column-names \
    -e "SELECT id FROM users WHERE dni='33333333P';" 2>/dev/null)

echo -e "${YELLOW}Retrieved CARLOS_ID = $CARLOS_ID${RESET}"

# ============================================================
# TEST 2.2 - Create valid carver
# ============================================================
run_test "2.2 Create valid carver" \
"INSERT INTO carvers (user_id, specialty, experience_years, max_hams_per_day, is_active)
 VALUES ($CARLOS_ID, 'Jamón Ibérico', 5, 3, TRUE);" \
"EMPTY_OK"

# ============================================================
# TEST 2.3 - Duplicate carver for same user
# ============================================================
run_test "2.3 Duplicate carver for same user" \
"INSERT INTO carvers (user_id, specialty, experience_years)
 VALUES ($CARLOS_ID, 'Paleta', 3);" \
"ERROR 1062"

# ============================================================
# TEST 2.4 - Carver with non-existing user_id
# ============================================================
run_test "2.4 Carver with non-existing user_id" \
"INSERT INTO carvers (user_id, specialty)
 VALUES (999999, 'Test');" \
"ERROR 1452"

# ============================================================
# TEST 2.5 - Verify JOIN users-carvers
# ============================================================
run_test "2.5 Verify JOIN users-carvers" \
"SELECT CONCAT(u.first_name, ' ', u.last_name)
 FROM carvers c
 JOIN users u ON c.user_id = u.id
 WHERE u.id = $CARLOS_ID;" \
"Carlos Martínez"

# ============================================================
# TEST 2.6 - CASCADE delete: deleting user deletes carver
# ============================================================

# Create temp user
run_test "2.6.1 Create temp user" \
"INSERT INTO users (dni, first_name, last_name, email, phone, password_hash, role)
 VALUES ('44444444A', 'Temp', 'User', 'temp@test.com', '600777777', '\$2a\$10\$test', 'CLIENT');" \
"EMPTY_OK"

TEMP_ID=$(mysql -u"$USER" -p"$PASS" "$DB" --silent --skip-column-names \
    -e "SELECT id FROM users WHERE dni='44444444A';" 2>/dev/null)

echo -e "${YELLOW}Retrieved TEMP_ID = $TEMP_ID${RESET}"

# Create temp carver
run_test "2.6.2 Create temp carver" \
"INSERT INTO carvers (user_id, specialty)
 VALUES ($TEMP_ID, 'Test');" \
"EMPTY_OK"

# Verify exists
run_test "2.6.3 Verify temp carver exists" \
"SELECT specialty FROM carvers WHERE user_id = $TEMP_ID;" \
"Test"

# Delete user
run_test "2.6.4 Delete temp user (CASCADE)" \
"DELETE FROM users WHERE id = $TEMP_ID;" \
"EMPTY_OK"

# Verify carver deleted
run_test "2.6.5 Verify temp carver deleted" \
"SELECT * FROM carvers WHERE user_id = $TEMP_ID;" \
"EMPTY_OK"

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

