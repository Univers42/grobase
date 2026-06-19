INSERT INTO "PasswordResetToken" ("token","user_id","expires_at","used") VALUES
    ('seed_reset_token_valid_alice',8,NOW()+INTERVAL '1 hour',FALSE),
    ('seed_reset_token_used_bob',9,NOW()-INTERVAL '1 hour',TRUE),
    ('seed_reset_token_expired_claire',10,NOW()-INTERVAL '2 hours',FALSE);
