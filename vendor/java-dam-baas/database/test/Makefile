# ============================================
# TEST CONSTRAINT USERS - MAKEFILE
# ============================================

SHELL := /bin/bash

# Path to your test script
TEST_USERS			:=	./sql_test1.sh
TEST_CARVERS		:=	./sql_test2.sh
TEST_SERVICES		:=	./sql_test3.sh
TEST_RESERVATIONS	:=	./sql_test4.sh
TEST_DELETES		:=	./sql_test5.sh
TEST_INDEXES		:=	./sql_test6.sh
TEST_NOTIFICATIONS	:=	./sql_test7.sh

# Default target
help:
	@echo ""
	@echo "==============================================="
	@echo "               TEST SUITE MENU"
	@echo "==============================================="
	@echo ""
	@echo "Available commands:"
	@echo ""
	@echo "  make help			- Show this help menu"
	@echo "  make users			- Run Users Constraint Test Suite"
	@echo "  make carvers		- Run Carvers Constraint Test Suite"
	@echo "  make services		- Run Services Constraint Test Suite"
	@echo "  make reservations	- Run Reservations Constraint Test Suite"
	@echo "  make deletes		- Run Delete Restrictions Test Suite"
	@echo "  make indexes		- Run Indexes & Performance Test Suite"
	@echo "  make notifications	- Run Notifications Test Suite"
	@echo "  make all			- Run ALL test suites"
	@echo ""
	@echo "==============================================="
	@echo ""

# Run the Users test suite
users:
	@echo ""
	@echo "Running Users Constraint Test Suite..."
	@$(TEST_USERS)

# Run Carvers test suite
carvers:
	@echo ""
	@echo "Running Carvers Constraint Test Suite..."
	@$(TEST_CARVERS)

# Run Services test suite services:
	@echo ""
	@echo "Running Services Constraint Test Suite..."
	@$(TEST_SERVICES)

# Run Reservations test suite reservations:
	@echo ""
	@echo "Running Reservations Constraint Test Suite..."
	@$(TEST_RESERVATIONS)

# Run Delete Restrictions test suite deletes:
	@echo ""
	@echo "Running Delete Restrictions Test Suite..."
	@$(TEST_DELETES)

# Run Indexes & Performance test suite indexes:
	@echo ""
	@echo "Running Indexes & Performance Test Suite..."
	@$(TEST_INDEXES)

# Run Notifications test suite notifications:
	@echo ""
	@echo "Running Notifications Test Suite..."
	@$(TEST_NOTIFICATIONS)

# Run all test suites
all:
	@echo ""
	@echo "Running ALL test suites..."
	@$(TEST_USERS)
	@$(TEST_CARVERS)
	@$(TEST_SERVICES)
	@$(TEST_RESERVATIONS)
	@$(TEST_DELETES)
	@$(TEST_INDEXES)
	@$(TEST_NOTIFICATIONS)
	@echo ""
	@echo "All test suites completed."
