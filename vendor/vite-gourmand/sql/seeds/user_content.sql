-- ============================================
-- SEED: UserConsent (GDPR tracking — ~20 rows)
-- ============================================

INSERT INTO "UserConsent" ("user_id","consent_type","is_granted","granted_at","ip_address") VALUES
    (8,'terms_of_service',TRUE,NOW(),'82.120.45.12'),
    (8,'marketing',FALSE,NULL,'82.120.45.12'),
    (9,'terms_of_service',TRUE,NOW(),'90.55.12.34'),
    (9,'marketing',TRUE,NOW(),'90.55.12.34'),
    (10,'terms_of_service',TRUE,NOW(),'78.200.10.5'),
    (11,'terms_of_service',TRUE,NOW(),'176.30.22.8'),
    (11,'analytics',TRUE,NOW(),'176.30.22.8'),
    (12,'terms_of_service',TRUE,NOW(),'86.10.20.30'),
    (13,'terms_of_service',TRUE,NOW(),'92.44.55.66'),
    (19,'terms_of_service',TRUE,NOW(),'176.30.22.9'),
    (19,'marketing',TRUE,NOW(),'176.30.22.9');
