# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    006_add_connection_salt.sql                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

-- File: scripts/migrations/postgresql/006_add_connection_salt.sql
-- Migration: Add scrypt salt column to tenant_databases for key derivation
-- UP

ALTER TABLE public.tenant_databases
  ADD COLUMN IF NOT EXISTS connection_salt BYTEA;

-- Existing rows encrypted with SHA-256 key derivation will need re-encryption.
-- New rows will always have a salt.

INSERT INTO public.schema_migrations (version, name) VALUES (6, '006_add_connection_salt')
  ON CONFLICT (version) DO NOTHING;

-- DOWN
-- ALTER TABLE public.tenant_databases DROP COLUMN IF EXISTS connection_salt;
-- DELETE FROM public.schema_migrations WHERE version = 6;
