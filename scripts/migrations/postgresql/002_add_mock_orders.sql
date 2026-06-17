# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    002_add_mock_orders.sql                            :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

-- File: scripts/migrations/postgresql/002_add_mock_orders.sql
-- Migration: Add mock_orders table for dual-data-plane demo
-- UP

CREATE TABLE IF NOT EXISTS public.mock_orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id TEXT NOT NULL,
  order_number TEXT NOT NULL UNIQUE,
  currency TEXT NOT NULL DEFAULT 'USD',
  total_cents INTEGER NOT NULL CHECK (total_cents >= 0),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'paid', 'cancelled')),
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE public.mock_orders ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS mock_orders_owner_crud ON public.mock_orders;
CREATE POLICY mock_orders_owner_crud ON public.mock_orders
  FOR ALL USING (auth.uid()::text = owner_id)
  WITH CHECK (auth.uid()::text = owner_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.mock_orders TO authenticated;

INSERT INTO public.schema_migrations (version, name) VALUES (2, '002_add_mock_orders')
  ON CONFLICT (version) DO NOTHING;

-- DOWN
-- DROP POLICY IF EXISTS mock_orders_owner_crud ON public.mock_orders;
-- DROP TABLE IF EXISTS public.mock_orders;
-- DELETE FROM public.schema_migrations WHERE version = 2;
