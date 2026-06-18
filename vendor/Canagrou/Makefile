# ─────────────────────────────────────────────────────────────────────────────
#  CAMAGRU — Makefile
#  Usage: make <target>
# ─────────────────────────────────────────────────────────────────────────────

COMPOSE     := docker compose
APP_URL     := http://localhost:8080
MAIL_URL    := http://localhost:8026
DB_PORT     := 3308
PHP_SERVICE := php
DC_FILE     := docker-compose.yml

# Detect 'open' command for browser launching
UNAME := $(shell uname -s)
ifeq ($(UNAME), Linux)
  OPEN := xdg-open
else ifeq ($(UNAME), Darwin)
  OPEN := open
else
  OPEN := echo "Open your browser at"
endif

.DEFAULT_GOAL := help

.PHONY: help run up build stop down restart re logs logs-php logs-nginx logs-db \
        shell shell-php shell-nginx shell-db db reset-db status clean fclean \
        flutter flutter-run flutter-build overlays

# ─── Help ────────────────────────────────────────────────────────────────────

help:
	@printf "\n\033[1;34m  CAMAGRU — Available targets\033[0m\n\n"
	@printf "  \033[1;32mProject\033[0m\n"
	@printf "  %-22s %s\n" "make run"        "Build, start, and open the app in your browser"
	@printf "  %-22s %s\n" "make up"         "Start all containers (detached)"
	@printf "  %-22s %s\n" "make build"      "Rebuild Docker images"
	@printf "  %-22s %s\n" "make stop"       "Stop containers (keep data)"
	@printf "  %-22s %s\n" "make down"       "Stop and remove containers (keep volumes)"
	@printf "  %-22s %s\n" "make re"         "Full rebuild from scratch (down + build + up)"
	@printf "  %-22s %s\n" "make restart"    "Restart all containers"
	@printf "  %-22s %s\n" "make status"     "Show container status"
	@printf "\n  \033[1;32mLogs\033[0m\n"
	@printf "  %-22s %s\n" "make logs"       "Tail logs from all containers"
	@printf "  %-22s %s\n" "make logs-php"   "Tail PHP-FPM logs"
	@printf "  %-22s %s\n" "make logs-nginx" "Tail Nginx logs"
	@printf "  %-22s %s\n" "make logs-db"    "Tail MariaDB logs"
	@printf "\n  \033[1;32mShells\033[0m\n"
	@printf "  %-22s %s\n" "make shell"      "Open a shell in the PHP container"
	@printf "  %-22s %s\n" "make shell-php"  "Open a shell in the PHP container"
	@printf "  %-22s %s\n" "make shell-nginx" "Open a shell in the Nginx container"
	@printf "  %-22s %s\n" "make shell-db"   "Open a shell in the MariaDB container"
	@printf "\n  \033[1;32mDatabase\033[0m\n"
	@printf "  %-22s %s\n" "make db"         "Connect to MariaDB (interactive)"
	@printf "  %-22s %s\n" "make reset-db"   "Drop and recreate the database (WARNING: data loss)"
	@printf "\n  \033[1;32mTools\033[0m\n"
	@printf "  %-22s %s\n" "make mail"       "Open Mailpit email catcher in browser"
	@printf "  %-22s %s\n" "make overlays"   "Regenerate overlay PNG files"
	@printf "\n  \033[1;32mCleaning\033[0m\n"
	@printf "  %-22s %s\n" "make clean"      "Remove containers and network (keep volumes + images)"
	@printf "  %-22s %s\n" "make fclean"     "Remove everything (containers, volumes, images)"
	@printf "\n  \033[1;32mFlutter\033[0m\n"
	@printf "  %-22s %s\n" "make flutter"    "Install Flutter dependencies"
	@printf "  %-22s %s\n" "make flutter-run" "Run the Flutter app (requires emulator or device)"
	@printf "  %-22s %s\n" "make flutter-build" "Build Flutter APK"
	@printf "\n"

# ─── Core ────────────────────────────────────────────────────────────────────

## Build images, start all services, wait for healthy, open in browser
run: build up _wait
	@printf "\033[1;32m✓ Camagru is running!\033[0m\n"
	@printf "  Web app : \033[4m$(APP_URL)\033[0m\n"
	@printf "  Mail UI : \033[4m$(MAIL_URL)\033[0m\n"
	@$(OPEN) $(APP_URL) 2>/dev/null || true

## Start all containers (detached, use existing images)
up:
	$(COMPOSE) -f $(DC_FILE) up -d

## Build or rebuild Docker images
build:
	$(COMPOSE) -f $(DC_FILE) build

## Stop all containers (data preserved)
stop:
	$(COMPOSE) -f $(DC_FILE) stop

## Stop and remove containers + network (volumes preserved)
down:
	$(COMPOSE) -f $(DC_FILE) down

## Restart all running containers
restart:
	$(COMPOSE) -f $(DC_FILE) restart

## Full clean rebuild: down → build → up → open browser
re: down build up _wait
	@printf "\033[1;32m✓ Camagru rebuilt and running!\033[0m\n"
	@printf "  Web app : \033[4m$(APP_URL)\033[0m\n"
	@$(OPEN) $(APP_URL) 2>/dev/null || true

## Show status of all containers
status:
	$(COMPOSE) -f $(DC_FILE) ps

# Internal: wait for web to become responsive
_wait:
	@printf "  Waiting for app to be ready..."
	@for i in $$(seq 1 30); do \
		if curl -s -o /dev/null -w "%{http_code}" $(APP_URL) | grep -qE '^[23]'; then \
			printf " \033[1;32mready!\033[0m\n"; \
			exit 0; \
		fi; \
		printf "."; \
		sleep 1; \
	done; \
	printf " \033[1;33mtimed out (app may still be starting)\033[0m\n"

# ─── Logs ────────────────────────────────────────────────────────────────────

logs:
	$(COMPOSE) -f $(DC_FILE) logs -f --tail=50

logs-php:
	$(COMPOSE) -f $(DC_FILE) logs -f --tail=50 php

logs-nginx:
	$(COMPOSE) -f $(DC_FILE) logs -f --tail=50 nginx

logs-db:
	$(COMPOSE) -f $(DC_FILE) logs -f --tail=50 mariadb

# ─── Shells ──────────────────────────────────────────────────────────────────

shell shell-php:
	$(COMPOSE) -f $(DC_FILE) exec php sh

shell-nginx:
	$(COMPOSE) -f $(DC_FILE) exec nginx sh

shell-db:
	$(COMPOSE) -f $(DC_FILE) exec mariadb sh

# ─── Database ────────────────────────────────────────────────────────────────

db:
	$(COMPOSE) -f $(DC_FILE) exec mariadb mariadb -u camagru -pcamagru_secret camagru

reset-db:
	@printf "\033[1;31mWARNING: This will DESTROY all data. Continue? [y/N] \033[0m"; \
	read ans; \
	if [ "$$ans" = "y" ] || [ "$$ans" = "Y" ]; then \
		$(COMPOSE) -f $(DC_FILE) exec mariadb mariadb -u root -proot_secret \
			-e "DROP DATABASE IF EXISTS camagru; CREATE DATABASE camagru CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL ON camagru.* TO 'camagru'@'%';"; \
		$(COMPOSE) -f $(DC_FILE) exec mariadb mariadb -u camagru -pcamagru_secret camagru < sql/init.sql; \
		printf "\033[1;32m✓ Database reset.\033[0m\n"; \
	else \
		printf "Aborted.\n"; \
	fi

# ─── Tools ───────────────────────────────────────────────────────────────────

mail:
	@printf "  Mail UI : \033[4m$(MAIL_URL)\033[0m\n"
	@$(OPEN) $(MAIL_URL) 2>/dev/null || true

overlays:
	$(COMPOSE) -f $(DC_FILE) exec php php bin/generate-overlays.php
	@printf "\033[1;32m✓ Overlays regenerated.\033[0m\n"

# ─── Cleaning ────────────────────────────────────────────────────────────────

## Stop + remove containers and network (keep volumes and images)
clean: down

## Stop + remove containers, volumes, and built images
fclean:
	$(COMPOSE) -f $(DC_FILE) down -v --rmi local
	@printf "\033[1;32m✓ All containers, volumes and local images removed.\033[0m\n"

# ─── Flutter ─────────────────────────────────────────────────────────────────

flutter:
	cd mobile && flutter pub get

flutter-run:
	cd mobile && flutter run

flutter-build:
	cd mobile && flutter build apk --release
	@printf "\033[1;32m✓ APK built: mobile/build/app/outputs/flutter-apk/app-release.apk\033[0m\n"
