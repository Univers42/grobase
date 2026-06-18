#!/bin/bash

DB="hambooking"
USER="root"
PASS="sergio1234"

LOGFILE="test_results.log"
echo "" >> "$LOGFILE"   # Reset log

TEST_COUNT=0
TOTAL_TESTS=7

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
echo -e " TEST CONSTRAINT USERS"
echo -e "===============================================${RESET}"

run_test "1.1 Valid insert" \
"INSERT INTO users (dni, first_name, last_name, email, phone, password_hash, role)
 VALUES ('11111111H', 'Juan', 'García', 'juan@test.com', '600111111', '\$2a\$10\$test', 'CLIENT');" \
"EMPTY_OK"

run_test "1.2 Duplicate DNI" \
"INSERT INTO users (dni, first_name, last_name, email, phone, password_hash, role)
 VALUES ('11111111H', 'Pedro', 'López', 'pedro@test.com', '600222222', '\$2a\$10\$test', 'CLIENT');" \
"ERROR 1062"

run_test "1.3 Duplicate email" \
"INSERT INTO users (dni, first_name, last_name, email, phone, password_hash, role)
 VALUES ('22222222J', 'Pedro', 'López', 'juan@test.com', '600222222', '\$2a\$10\$test', 'CLIENT');" \
"ERROR 1062"

run_test "1.4 Invalid DNI format" \
"INSERT INTO users (dni, first_name, last_name, email, phone, password_hash, role)
 VALUES ('INVALID', 'Test', 'User', 'invalid@test.com', '600333333', '\$2a\$10\$test', 'CLIENT');" \
"ERROR 3819"

run_test "1.5 Incorrect DNI letter" \
"INSERT INTO users (dni, first_name, last_name, email, phone, password_hash, role)
 VALUES ('1234567A', 'Test', 'User', 'short@test.com', '600444444', '\$2a\$10\$test', 'CLIENT');" \
"ERROR 3819"

run_test "1.6 NULL DNI" \
"INSERT INTO users (dni, first_name, last_name, email, phone, password_hash, role)
 VALUES (NULL, 'Test', 'User', 'null@test.com', '600555555', '\$2a\$10\$test', 'CLIENT');" \
"ERROR 1048"

run_test "Final state of CLIENT users" \
"SELECT id, dni, email, role FROM users WHERE role = 'CLIENT';" \
"11111111H"

echo ""
echo -e "${BLUE}==============================================="
echo -e " FINAL SUMMARY"
echo -e "===============================================${RESET}"
echo -e "${GREEN}✔ Passed: $PASSED${RESET}"
echo -e "${RED}✘ Failed: $FAILED${RESET}"
echo ""
echo -e "Full details saved in: ${YELLOW}$LOGFILE${RESET}"
