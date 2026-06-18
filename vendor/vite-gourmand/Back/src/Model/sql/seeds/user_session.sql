INSERT INTO "UserSession" ("user_id","session_token","ip_address","user_agent","expires_at","is_active") VALUES
    (1,'seed_session_superadmin_001','127.0.0.1','Seed/1.0',NOW()+INTERVAL '7 days',TRUE),
    (2,'seed_session_admin_jose_001','127.0.0.1','Seed/1.0',NOW()+INTERVAL '7 days',TRUE),
    (3,'seed_session_admin_julie_001','127.0.0.1','Seed/1.0',NOW()+INTERVAL '7 days',TRUE),
    (4,'seed_session_employee_pierre','127.0.0.1','Seed/1.0',NOW()+INTERVAL '7 days',TRUE),
    (8,'seed_session_client_alice','82.120.45.12','Mozilla/5.0',NOW()+INTERVAL '7 days',TRUE),
    (9,'seed_session_client_bob','90.55.12.34','Mozilla/5.0',NOW()+INTERVAL '7 days',TRUE),
    -- expired session for test
    (11,'seed_session_expired_david','176.30.22.8','Mozilla/5.0',NOW()-INTERVAL '1 day',FALSE);
