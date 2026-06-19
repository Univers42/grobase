INSERT INTO "Order" (
    "order_number","user_id","order_date","delivery_date","delivery_hour",
    "delivery_address","delivery_city","delivery_distance_km",
    "person_number","menu_price","delivery_price",
    "discount_percent","discount_amount","total_price",
    "status","material_lending","cancellation_reason","cancellation_contact_mode"
) VALUES
    ('ORD-2026-00001',8,'2026-01-10 09:00','2026-02-14','18:00','10 Rue de Rivoli','Paris',450.0,55,4675.00,270.50,10.00,467.50,4478.00,'completed',TRUE,NULL,NULL),
    ('ORD-2026-00002',9,'2026-01-12 14:00','2026-02-20','12:00','22 Rue de la République','Lyon',550.0,30,1350.00,329.50,0.00,0.00,1679.50,'delivered',FALSE,NULL,NULL),
    ('ORD-2026-00003',10,'2026-01-14 10:30','2026-03-01','19:00','8 Quai du Vieux-Port','Marseille',650.0,25,1625.00,388.50,10.00,162.50,1851.00,'accepted',FALSE,NULL,NULL),
    ('ORD-2026-00004',11,'2026-01-15 16:00','2026-02-28','11:00','15 Cours de l''Intendance','Bordeaux',0.0,15,525.00,0.00,0.00,0.00,525.00,'pending',FALSE,NULL,NULL),
    ('ORD-2026-00005',8,'2026-01-18 11:00','2026-04-15','20:00','5 Avenue Montaigne','Paris',450.0,10,1200.00,270.50,0.00,0.00,1470.50,'preparing',TRUE,NULL,NULL),
    ('ORD-2026-00006',9,'2026-01-20 08:30','2026-03-10','18:00','15 Rue Mercière','Lyon',550.0,60,3900.00,329.50,10.00,390.00,3839.50,'delivering',TRUE,NULL,NULL),
    ('ORD-2026-00007',11,'2026-01-22 13:00','2026-02-05','17:00','3 Place des Quinconces','Bordeaux',0.0,20,1300.00,0.00,0.00,0.00,1300.00,'awaiting_material_return',TRUE,NULL,NULL),
    ('ORD-2026-00008',10,'2026-01-25 09:15','2026-02-01','12:00','8 Quai du Vieux-Port','Marseille',650.0,20,700.00,388.50,0.00,0.00,1088.50,'cancelled',FALSE,NULL,NULL),
    ('ORD-2026-00009',8,'2026-02-01 10:00','2026-03-20','19:00','10 Rue de Rivoli','Paris',450.0,55,4675.00,270.50,10.00,467.50,4478.00,'pending',FALSE,NULL,NULL),
    ('ORD-2026-00010',11,'2026-02-05 14:30','2026-04-01','18:00','42 Rue Sainte-Catherine','Bordeaux',0.0,35,2975.00,0.00,10.00,297.50,2677.50,'pending',TRUE,NULL,NULL),
    ('ORD-2026-00011',12,'2026-01-05 08:00','2026-01-25','19:00','12 Place du Capitole','Toulouse',250.0,30,1350.00,152.50,0.00,0.00,1502.50,'completed',FALSE,NULL,NULL),
    ('ORD-2026-00012',13,'2026-01-08 09:30','2026-01-28','18:00','8 Promenade des Anglais','Nice',700.0,40,2600.00,418.00,10.00,260.00,2758.00,'completed',TRUE,NULL,NULL),
    ('ORD-2026-00013',14,'2026-02-10 11:00','2026-03-05','12:00','3 Rue Crébillon','Nantes',350.0,20,700.00,211.50,0.00,0.00,911.50,'delivered',FALSE,NULL,NULL),
    ('ORD-2026-00014',15,'2026-02-12 14:00','2026-03-15','19:00','12 Place Kléber','Strasbourg',600.0,50,4250.00,359.00,10.00,425.00,4184.00,'accepted',TRUE,NULL,NULL),
    ('ORD-2026-00015',16,'2026-02-15 10:00','2026-03-20','18:00','7 Place de la Comédie','Montpellier',500.0,25,1125.00,300.00,10.00,112.50,1312.50,'preparing',FALSE,NULL,NULL),
    ('ORD-2026-00016',17,'2026-02-18 09:00','2026-03-01','12:00','25 Grand Place','Lille',300.0,15,525.00,182.00,0.00,0.00,707.00,'cancelled',FALSE,'Ingrédients indisponibles','email'),
    ('ORD-2026-00017',18,'2026-02-20 16:00','2026-04-10','19:00','4 Place des Lices','Rennes',380.0,20,1700.00,229.20,0.00,0.00,1929.20,'pending',FALSE,NULL,NULL),
    ('ORD-2026-00018',19,'2026-02-22 08:00','2026-03-08','11:00','1 Allées de Tourny','Bordeaux',0.0,60,5100.00,0.00,10.00,510.00,4590.00,'delivering',TRUE,NULL,NULL),
    ('ORD-2026-00019',19,'2025-12-01 10:00','2025-12-20','18:00','42 Rue Sainte-Catherine','Bordeaux',0.0,30,2850.00,0.00,10.00,285.00,2565.00,'completed',FALSE,NULL,NULL),
    ('ORD-2026-00020',11,'2025-11-15 14:00','2025-12-05','19:00','15 Cours de l''Intendance','Bordeaux',0.0,15,525.00,0.00,0.00,0.00,525.00,'completed',FALSE,NULL,NULL);

-- OrderMenu junction
INSERT INTO "OrderMenu" ("order_id","menu_id","quantity") VALUES
    (1,1,1),(2,3,1),(3,2,1),(4,4,1),(5,5,1),(6,6,1),(7,5,1),(8,2,1),
    (9,1,1),(9,5,1),(10,6,1),(11,3,1),(12,8,1),(13,4,1),(14,1,1),
    (15,2,1),(16,4,1),(17,1,1),(18,6,1),(18,3,1),(19,9,1),(20,4,1);
