#!/bin/bash

DB="hambooking"
USER="root"
PASS="sergio1234"

LOGFILE="test_results.log"
echo "" >> "$LOGFILE"   # Reset log

TEST_COUNT=0
TOTAL_TESTS=16

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
echo -e " TEST CONSTRAINT RESERVATIONS"
echo -e "===============================================${RESET}"

# ============================================================
# SETUP: Retrieve dynamic IDs
# ============================================================

CLIENT_ID=$(mysql -u"$USER" -p"$PASS" "$DB" --silent --skip-column-names \
    -e "SELECT id FROM users WHERE dni='11111111H';" 2>/dev/null)

CARVER1_ID=$(mysql -u"$USER" -p"$PASS" "$DB" --silent --skip-column-names \
    -e "SELECT id FROM carvers ORDER BY id LIMIT 1;" 2>/dev/null)

echo -e "${YELLOW}Using CLIENT_ID=$CLIENT_ID, CARVER1_ID=$CARVER1_ID${RESET}"

# ============================================================
# TEST 4.1 - Valid reservation
# ============================================================
run_test "4.1 Valid reservation" \
"INSERT INTO reservations (client_id, carver_id, service_id, reservation_date, start_time, end_time, status, notes)
 VALUES ($CLIENT_ID, $CARVER1_ID, 1, '2025-12-24', '10:00:00', '12:00:00', 'PENDING', 'First test reservation');" \
"EMPTY_OK"

# ============================================================
# TEST 4.2 - Double booking same slot (should fail)
# ============================================================
run_test "4.2 Double booking same slot" \
"INSERT INTO reservations (client_id, carver_id, service_id, reservation_date, start_time, end_time, status)
 VALUES ($CLIENT_ID, $CARVER1_ID, 2, '2025-12-24', '10:00:00', '11:00:00', 'PENDING');" \
"ERROR 1062"

# ============================================================
# TEST 4.3 - Same carver, different slot (should work)
# ============================================================
run_test "4.3 Same carver, different slot" \
"INSERT INTO reservations (client_id, carver_id, service_id, reservation_date, start_time, end_time, status)
 VALUES ($CLIENT_ID, $CARVER1_ID, 2, '2025-12-24', '12:30:00', '13:30:00', 'PENDING');" \
"EMPTY_OK"

# ============================================================
# TEST 4.4 - Same slot, different carver
# ============================================================

# Create second carver
run_test "4.4.1 Create second carver user" \
"INSERT INTO users (dni, first_name, last_name, email, phone, password_hash, role)
 VALUES ('55555555K', 'Ana', 'López', 'ana@hambooking.com', '600888888', '\$2a\$10\$test', 'CLIENT');" \
"EMPTY_OK"

CARVER2_USER_ID=$(mysql -u"$USER" -p"$PASS" "$DB" --silent --skip-column-names \
    -e "SELECT id FROM users WHERE dni='55555555K';" 2>/dev/null)

run_test "4.4.2 Create second carver" \
"INSERT INTO carvers (user_id, specialty, is_active)
 VALUES ($CARVER2_USER_ID, 'Paleta', TRUE);" \
"EMPTY_OK"

CARVER2_ID=$(mysql -u"$USER" -p"$PASS" "$DB" --silent --skip-column-names \
    -e "SELECT id FROM carvers WHERE user_id=$CARVER2_USER_ID;" 2>/dev/null)

run_test "4.4.3 Same slot, different carver" \
"INSERT INTO reservations (client_id, carver_id, service_id, reservation_date, start_time, end_time, status)
 VALUES ($CLIENT_ID, $CARVER2_ID, 1, '2025-12-24', '10:00:00', '12:00:00', 'PENDING');" \
"EMPTY_OK"

# ============================================================
# TIME CONSTRAINT TESTS
# ============================================================

run_test "4.5 Invalid hour (before 10:00)" \
"INSERT INTO reservations (client_id, carver_id, service_id, reservation_date, start_time, end_time, status)
 VALUES ($CLIENT_ID, $CARVER1_ID, 1, '2025-12-25', '09:00:00', '11:00:00', 'PENDING');" \
"ERROR 3819"

run_test "4.6 Invalid hour (after 17:30)" \
"INSERT INTO reservations (client_id, carver_id, service_id, reservation_date, start_time, end_time, status)
 VALUES ($CLIENT_ID, $CARVER1_ID, 1, '2025-12-25', '18:00:00', '20:00:00', 'PENDING');" \
"ERROR 3819"

run_test "4.7 Invalid minutes (not 00 or 30)" \
"INSERT INTO reservations (client_id, carver_id, service_id, reservation_date, start_time, end_time, status)
 VALUES ($CLIENT_ID, $CARVER1_ID, 1, '2025-12-25', '10:15:00', '12:15:00', 'PENDING');" \
"ERROR 3819"

# ============================================================
# WEEKDAY CONSTRAINT TESTS
# ============================================================

run_test "4.8 Saturday (should fail)" \
"INSERT INTO reservations (client_id, carver_id, service_id, reservation_date, start_time, end_time, status)
 VALUES ($CLIENT_ID, $CARVER1_ID, 1, '2025-12-20', '14:00:00', '16:00:00', 'PENDING');" \
"ERROR 3819"

run_test "4.9 Sunday (should fail)" \
"INSERT INTO reservations (client_id, carver_id, service_id, reservation_date, start_time, end_time, status)
 VALUES ($CLIENT_ID, $CARVER1_ID, 1, '2025-12-21', '14:00:00', '16:00:00', 'PENDING');" \
"ERROR 3819"

run_test "4.10 Monday valid reservation" \
"INSERT INTO reservations (client_id, carver_id, service_id, reservation_date, start_time, end_time, status)
 VALUES ($CLIENT_ID, $CARVER1_ID, 3, '2025-12-22', '16:30:00', '17:00:00', 'CONFIRMED');" \
"EMPTY_OK"

# ============================================================
# FOREIGN KEY TESTS
# ============================================================

run_test "4.11 FK fail: non-existing client" \
"INSERT INTO reservations (client_id, carver_id, service_id, reservation_date, start_time, end_time, status)
 VALUES (999999, $CARVER1_ID, 1, '2025-12-23', '10:00:00', '12:00:00', 'PENDING');" \
"ERROR 1452"

run_test "4.12 FK fail: non-existing carver" \
"INSERT INTO reservations (client_id, carver_id, service_id, reservation_date, start_time, end_time, status)
 VALUES ($CLIENT_ID, 999999, 1, '2025-12-23', '10:00:00', '12:00:00', 'PENDING');" \
"ERROR 1452"

run_test "4.13 FK fail: non-existing service" \
"INSERT INTO reservations (client_id, carver_id, service_id, reservation_date, start_time, end_time, status)
 VALUES ($CLIENT_ID, $CARVER1_ID, 999999, '2025-12-23', '10:00:00', '12:00:00', 'PENDING');" \
"ERROR 1452"

# ============================================================
# FINAL STATE CHECK
# ============================================================

run_test "Final state: valid reservations" \
"SELECT COUNT(*) FROM reservations WHERE reservation_date IN ('2025-12-24');" \
"3"

# ============================================================
# SUMMARY
# ============================================================

echo ""
echo -e "${BLUE}==============================================="
echo -e " FINAL SUMMARY"
echo -e "===============================================${RESET}"
echo -e "${GREEN}✔ Passed: $PASSED${RESET}"
echo -e "${RED}✘ Failed: $FAILED${RESET}"
echo ""
echo -e "Full details saved in: ${YELLOW}$LOGFILE${RESET}"
