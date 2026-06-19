INSERT INTO "OrderOrderTag" ("order_id","tag_id") VALUES
    (1,2),(1,4),(1,5),     -- ORD-00001: vip, matériel, grande tablée
    (6,1),(6,5),           -- ORD-00006: urgent, grande tablée
    (7,4),                 -- ORD-00007: matériel
    (14,2),(14,4),(14,5),  -- ORD-00014: vip, matériel, grande tablée
    (18,1),(18,4),(18,5),  -- ORD-00018: urgent, matériel, grande tablée
    (4,6)                  -- ORD-00004: weekend
ON CONFLICT DO NOTHING;
