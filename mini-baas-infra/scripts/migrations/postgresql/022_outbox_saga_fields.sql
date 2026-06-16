-- ****************************************************************************
--                                                                              
--                                                         :::      ::::::::    
--    022_outbox_saga_fields.sql                        :+:      :+:    :+:    
--                                                     +:+ +:+         +:+      
--    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         
--                                                 +#+#+#+#+#+   +#+            
--    Created: 2026/05/31 21:30:00 by dlesieur          #+#    #+#              
--    Updated: 2026/05/31 21:30:00 by dlesieur         ###   ########.fr        
--                                                                              
-- ****************************************************************************

-- File: scripts/migrations/postgresql/022_outbox_saga_fields.sql
-- M8: generalize outbox events for cross-engine saga dispatch and compensation.

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = 22) THEN
    RAISE NOTICE 'Migration 022 already applied - skipping';
    RETURN;
  END IF;

  ALTER TABLE public.outbox_events
    ADD COLUMN IF NOT EXISTS target_engine TEXT,
    ADD COLUMN IF NOT EXISTS target_resource TEXT,
    ADD COLUMN IF NOT EXISTS op TEXT,
    ADD COLUMN IF NOT EXISTS compensation_payload JSONB,
    ADD COLUMN IF NOT EXISTS idempotency_key TEXT,
    ADD COLUMN IF NOT EXISTS saga_state TEXT NOT NULL DEFAULT 'pending'
      CHECK (saga_state IN ('pending', 'dispatched', 'compensating', 'compensated', 'dead')),
    ADD COLUMN IF NOT EXISTS next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now();

  CREATE INDEX IF NOT EXISTS outbox_saga_target_idx
    ON public.outbox_events (target_engine, target_resource, saga_state, next_attempt_at)
    WHERE target_engine IS NOT NULL;

  CREATE INDEX IF NOT EXISTS outbox_idempotency_idx
    ON public.outbox_events (idempotency_key)
    WHERE idempotency_key IS NOT NULL;

  INSERT INTO public.schema_migrations (version, name)
  VALUES (22, '022_outbox_saga_fields')
  ON CONFLICT (version) DO NOTHING;
END $$;

COMMIT;