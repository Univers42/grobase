#!/bin/bash

DB="hambooking"
USER="root"
PASS="sergio1234"

LOGFILE="test_results.log"
echo "" >> "$LOGFILE"   # Append log

TEST_COUNT=0
TOTAL_TESTS=3

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
echo -e " TEST SUITE 7: NOTIFICATIONS"
echo -e "===============================================${RESET}"

# ============================================================
# SETUP: Create a reservation for test 7.1
# ============================================================

# Create test client if not exists
mysql -u"$USER" -p"$PASS" "$DB" -e "
INSERT IGNORE INTO users (dni, first_name, last_name, email, phone, password_hash, role)
VALUES ('77777777T', 'Notif', 'Client', 'notifclient@test.com', '600777777', '\$2a\$10\$test', 'CLIENT');
"

CLIENT_ID=$(mysql -u"$USER" -p"$PASS" "$DB" --silent -e "SELECT id FROM users WHERE dni='77777777T';")

# Create test carver if not exists
mysql -u"$USER" -p"$PASS" "$DB" -e "
INSERT IGNORE INTO users (dni, first_name, last_name, email, phone, password_hash, role)
VALUES ('88888888R', 'Notif', 'Carver', 'notifcarver@test.com', '600888888', '\$2a\$10\$test', 'CLIENT');
"

CARVER_USER_ID=$(mysql -u"$USER" -p"$PASS" "$DB" --silent -e "SELECT id FROM users WHERE dni='88888888R';")

mysql -u"$USER" -p"$PASS" "$DB" -e "
INSERT IGNORE INTO carvers (user_id, specialty, experience_years, max_hams_per_day, is_active)
VALUES ($CARVER_USER_ID, 'Jamon', 5, 3, TRUE);
"

CARVER_ID=$(mysql -u"$USER" -p"$PASS" "$DB" --silent -e "SELECT id FROM carvers WHERE user_id=$CARVER_USER_ID;")

# Create test service if not exists
mysql -u"$USER" -p"$PASS" "$DB" -e "
INSERT IGNORE INTO services (name, description, duration_minutes, base_price)
VALUES ('NotifService', 'Service for notifications', 30, 25.00);
"

SERVICE_ID=$(mysql -u"$USER" -p"$PASS" "$DB" --silent -e "SELECT id FROM services WHERE name='NotifService';")

# Create reservation for test 7.1
mysql -u"$USER" -p"$PASS" "$DB" -e "
INSERT INTO reservations (client_id, carver_id, service_id, reservation_date, start_time, end_time, status)
VALUES ($CLIENT_ID, $CARVER_ID, $SERVICE_ID, '2025-12-24', '10:00:00', '10:30:00', 'CONFIRMED');
"

RES_ID=$(mysql -u"$USER" -p"$PASS" "$DB" --silent -e "SELECT id FROM reservations ORDER BY id DESC LIMIT 1;")

# ============================================================
# TEST 7.1 - Valid notification
# ============================================================
run_test "7.1 Create valid notification" \
"INSERT INTO notifications (reservation_id, recipient_type, recipient_email, notification_type, subject, message)
 VALUES ($RES_ID, 'CLIENT', 'juan@test.com', 'CREATED', 'Reserva Confirmada', 'Su reserva para el 20/12 a las 10:00 ha sido confirmada.');" \
"EMPTY_OK"

# ============================================================
# TEST 7.2 - Notification without reservation (NULL allowed)
# ============================================================
run_test "7.2 Notification with NULL reservation" \
"INSERT INTO notifications (reservation_id, recipient_type, recipient_email, notification_type, subject, message)
 VALUES (NULL, 'ADMIN', 'admin@hambooking.com', 'REMINDER', 'Test', 'Mensaje sin reserva');" \
"EMPTY_OK"

# ============================================================
# TEST 7.3 - JOIN verification
# ============================================================
run_test "7.3 Notification JOIN check" \
"SELECT n.id, n.recipient_type, n.recipient_email, n.notification_type, n.subject, r.id, r.reservation_date
   FROM notifications n
   LEFT JOIN reservations r ON n.reservation_id = r.id;" \
"Reserva Confirmada"

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
