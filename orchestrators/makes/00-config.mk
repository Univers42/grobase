# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    00-config.mk                                       :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/17 23:00:09 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/17 23:00:29 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

SHELL          := /bin/bash
.SHELLFLAGS    := -ec
.DEFAULT_GOAL  := help

PROJECT        := mini-baas
COMPOSE_FILE   ?= docker-compose.yml
IMAGE_TAG      ?= latest
REGISTRY       ?= localhost:5000
SERVICE        ?=
STEPS          ?= 1
HOOKS_DIR      := vendor/scripts/hooks
DC             := docker compose -f $(COMPOSE_FILE)

# Colors
_B := \033[0;34m
_G := \033[0;32m
_Y := \033[1;33m
_R := \033[0;31m
_C := \033[0;36m
_W := \033[1m
_D := \033[2m
_0 := \033[0m

# ========================================================================== #
#  THE MANIFEST — single source of truth (see wiki/02-layer-edition-model.md) #
# ========================================================================== #
# A PLANE is a capability slice mapped to compose profile(s).
# An EDITION is a named, validated set of planes ("a known-good shape").
# Every up-/down-/logs- target below is GENERATED from these two maps, so
# adding a plane or an edition is a one-line change — never a new recipe.

PLANES := data control go rust adapter background analytics storage realtime \
          functions observability ops studio playground engines

# plane -> compose profile(s)
PROFILES_data          := data-plane
PROFILES_control       := control-plane
PROFILES_go            := go-control-plane
PROFILES_rust          := rust-data-plane
PROFILES_adapter       := adapter-plane
PROFILES_background    := background
PROFILES_analytics     := analytics
PROFILES_storage       := storage
PROFILES_realtime      := realtime
PROFILES_functions     := functions
PROFILES_observability := observability
PROFILES_ops           := ops backups
PROFILES_studio        := studio
PROFILES_playground    := playground
# Extra database engines (mariadb/cockroachdb/mssql) — the à-la-carte "extra
# engines" add-on / Max package. Optional; never in default editions.
PROFILES_engines       := engines-extra

EDITIONS := lean query realtime analytics prod full tetris

# edition -> plane list  (core, profile-less, is always included)
EDITION_lean      :=
EDITION_query     := data go rust adapter background
EDITION_realtime  := data go rust adapter background realtime storage
EDITION_analytics := data storage analytics
EDITION_prod      := data go rust adapter background storage realtime observability ops
# `playground` is a demo UI whose static assets are NOT checked into this repo, so its
# bind-mount (./playground) has nothing to serve. Excluded from `full` so `make up
# EDITION=full` comes up clean; restore the playground/ assets + drop the filter to re-enable.
EDITION_full      := $(filter-out playground,$(PLANES))
# `tetris` — the maximal red-tetris game edition: relational data + control + rust
# data plane + adapter + background, plus realtime (the multiplayer game bus + live
# leaderboard CDC), storage (avatars), functions (scheduled league recompute),
# analytics (game stats) and observability. The `red-tetris` SPA-serving compose
# profile is opted into separately by `make red-tetris` (like gourmand/hypertube).
EDITION_tetris    := data go rust adapter background realtime storage functions analytics observability

# Which edition `make up` / `make down` operate on by default.
EDITION ?= query

# A PACKAGE is the customer-facing service tier (Phase 4 — mirrors
# infra/config/packages/packages.json): like an EDITION but named for the product
# catalog. ADDONS appends à-la-carte planes (realtime/analytics/engines/…).
# `make up PACKAGE=pro ADDONS="analytics engines"` resolves to compose profiles
# exactly like EDITION. Precedence: PROFILES > PACKAGE > EDITION.
PACKAGES := basic essential pro max
# basic = the Pi-class lean tier: SQLite-first, served Node-free via the Rust
# /data/v1 bypass — only the always-on core + Go control + Rust data plane.
PACKAGE_basic     := go rust
# essential = pg/sqlite OLTP + Node orchestration, NO mongo/mysql containers:
# the `data` plane joins at pro. outbox-relay tolerates the missing mongo
# (MONGO_OPTIONAL) and the tier's capability mask already forbids mongo mounts.
PACKAGE_essential := go rust adapter background
PACKAGE_pro       := $(PACKAGE_essential) data storage realtime
PACKAGE_max       := $(PACKAGE_pro) analytics observability functions engines
ADDONS ?=

# Functions: plane-list -> sorted profiles -> `--profile x --profile y`
profiles_of = $(sort $(foreach p,$(1),$(PROFILES_$(p))))
flags_of    = $(addprefix --profile ,$(call profiles_of,$(1)))

# Active profiles for the generic edition-driven verbs. Precedence:
#   PROFILES= (raw profiles) > PACKAGE= (+ADDONS, the product tier) > EDITION=.
#   make up PROFILES="data-plane storage"     # ad-hoc raw profiles
#   make up PACKAGE=pro ADDONS="analytics"    # a product tier + add-on
#   make up EDITION=realtime                  # a known-good edition
ifdef PROFILES
ACTIVE_PROFILES := $(PROFILES)
else ifdef PACKAGE
ACTIVE_PROFILES := $(call profiles_of,$(PACKAGE_$(PACKAGE)) $(ADDONS))
else
ACTIVE_PROFILES := $(call profiles_of,$(EDITION_$(EDITION)))
endif
PROFILE_FLAGS := $(addprefix --profile ,$(ACTIVE_PROFILES))
DCE           := $(DC) $(PROFILE_FLAGS)

_require-docker:
	@command -v docker >/dev/null 2>&1 || { echo >&2 "Docker is not installed."; exit 1; }

_require-compose: _require-docker
	@docker compose version >/dev/null 2>&1 || { echo >&2 "Docker Compose v2 plugin is required."; exit 1; }

_rm-stale:
	@ids=$$(docker ps -a --format '{{.ID}} {{.Names}} {{.Status}}' | awk '/ mini-baas-/ && ($$3=="Created"||$$3=="Exited") {print $$1}'); \
	[ -z "$$ids" ] || { echo -e "$(_Y)Removing stale containers…$(_0)"; docker rm -f $$ids >/dev/null; }
