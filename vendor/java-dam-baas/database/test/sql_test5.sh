#!/bin/bash

DB="hambooking"
USER="root"
PASS="sergio1234"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

PASSED=0
FAILED=0
TEST_COUNT=0
TOTAL_TESTS=5

LOGFILE="test_results.log"
echo "" > "$LOGFILE"

# ============================
# Progress bar + test runner
# ============================
run_test() {
    local description="$1"
    local sql="$2"
    local expected="$3"

    TEST_COUNT=$((TEST_COUNT+1))

    local progress=$((TEST_COUNT * 100 / TOTAL_TESTS))
    local filled=$((progress / 10))
    local empty=$((10 - filled))
    local bar=$(printf "%${filled}s" | tr ' ' '#')
    bar+=$(printf "%${empty}s" | tr ' ' '-')

    echo -ne "${YELLOW}[${bar}] ${progress}% (${TEST_COUNT}/${TOTAL_TESTS})${RESET}  ${description}... "

    # Execute SQL
    RAW_OUTPUT=$(mysql -u"$USER" -p"$PASS" "$DB" --silent --skip-column-names -e "$sql" 2>&1)
    OUTPUT=$(echo "$RAW_OUTPUT" | grep -v "Using a password on the command line interface can be insecure")

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
echo -e " TEST SUITE 5: DELETE RESTRICTIONS (ON DELETE)"
echo -e "===============================================${RESET}"

# ============================================================
# 1️⃣ CREATE TEST DATA (client, carver, service)
# ============================================================

# Valid 9-char DNIs
CLIENT_DNI="00000000A"
CARVER_DNI="00000000B"

# Create test client
mysql -u"$USER" -p"$PASS" "$DB" -e "
INSERT INTO users (dni, first_name, last_name, email, phone, password_hash, role)
VALUES ('$CLIENT_DNI', 'Client5', 'Test', 'client5@test.com', '600000500', '\$2a\$10\$test', 'CLIENT');
"

CLIENT_ID=$(mysql -u"$USER" -p"$PASS" "$DB" --silent -e "SELECT id FROM users WHERE dni='$CLIENT_DNI';")

if [ -z "$CLIENT_ID" ]; then
    echo -e "${RED}ERROR: Failed to create test client.${RESET}"
    exit 1
fi

# Create test carver
mysql -u"$USER" -p"$PASS" "$DB" -e "
INSERT INTO users (dni, first_name, last_name, email, phone, password_hash, role)
VALUES ('$CARVER_DNI', 'Carver5', 'Test', 'carver5@test.com', '600000501', '\$2a\$10\$test', 'CLIENT');
"

CARVER_USER_ID=$(mysql -u"$USER" -p"$PASS" "$DB" --silent -e "SELECT id FROM users WHERE dni='$CARVER_DNI';")

if [ -z "$CARVER_USER_ID" ]; then
    echo -e "${RED}ERROR: Failed to create test carver user.${RESET}"
    exit 1
fi

mysql -u"$USER" -p"$PASS" "$DB" -e "
INSERT INTO carvers (user_id, specialty, experience_years, max_hams_per_day, is_active)
VALUES ($CARVER_USER_ID, 'Jamon', 5, 3, TRUE);
"

CARVER_ID=$(mysql -u"$USER" -p"$PASS" "$DB" --silent -e "SELECT id FROM carvers WHERE user_id=$CARVER_USER_ID;")

if [ -z "$CARVER_ID" ]; then
    echo -e "${RED}ERROR: Failed to create test carver.${RESET}"
    exit 1
fi

# Create test service
mysql -u"$USER" -p"$PASS" "$DB" -e "
INSERT INTO services (name, description, duration_minutes, base_price)
VALUES ('TestService5', 'Service for delete tests', 30, 20.00);
"

SERVICE_ID=$(mysql -u"$USER" -p"$PASS" "$DB" --silent -e "SELECT id FROM services WHERE name='TestService5';")

if [ -z "$SERVICE_ID" ]; then
    echo -e "${RED}ERROR: Failed to create test service.${RESET}"
    exit 1
fi

# ============================================================
# 2️⃣ CREATE RESERVATION THAT BLOCKS DELETES
# ============================================================

mysql -u"$USER" -p"$PASS" "$DB" -e "
INSERT INTO reservations (client_id, carver_id, service_id, reservation_date, start_time, end_time, status)
VALUES ($CLIENT_ID, $CARVER_ID, $SERVICE_ID, '2025-12-22', '10:00:00', '10:30:00', 'PENDING');
"

# ============================================================
# TESTS
# ============================================================

run_test "5.1 Delete user with reservations (RESTRICT)" \
"DELETE FROM users WHERE dni='$CLIENT_DNI';" \
"ERROR 1451"

run_test "5.2 Delete carver with reservations (RESTRICT)" \
"DELETE FROM carvers WHERE id=$CARVER_ID;" \
"ERROR 1451"

run_test "5.3 Delete service with reservations (RESTRICT)" \
"DELETE FROM services WHERE id=$SERVICE_ID;" \
"ERROR 1451"

run_test "5.4.1 Create reservation to delete" \
"INSERT INTO reservations (client_id, carver_id, service_id, reservation_date, start_time, end_time, status)
 VALUES ($CLIENT_ID, $CARVER_ID, $SERVICE_ID, '2025-12-23', '11:00:00', '11:30:00', 'PENDING');" \
"EMPTY_OK"

RES_ID=$(mysql -u"$USER" -p"$PASS" "$DB" --silent -e "SELECT id FROM reservations ORDER BY id DESC LIMIT 1;")

run_test "5.4.2 Delete created reservation" \
"DELETE FROM reservations WHERE id=$RES_ID;" \
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
