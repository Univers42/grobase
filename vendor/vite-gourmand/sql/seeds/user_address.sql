-- Users: 8=alice, 9=bob, 10=claire, 11=david, 12=emma, 13=francois, 14=helene, 15=igor, 16=julie.client, 17=karim, 18=laura, 19=nicolas, 2=jose, 4=pierre, 5=sophie
INSERT INTO "UserAddress" ("user_id","label","street_address","city","postal_code","country","is_default") VALUES
    (8,'home','10 Rue de Rivoli','Paris','75001','France',TRUE),
    (8,'work','5 Avenue Montaigne','Paris','75008','France',FALSE),
    (9,'home','22 Rue de la République','Lyon','69001','France',TRUE),
    (10,'home','8 Quai du Vieux-Port','Marseille','13001','France',TRUE),
    (11,'home','15 Cours de l''Intendance','Bordeaux','33000','France',TRUE),
    (11,'work','3 Place des Quinconces','Bordeaux','33000','France',FALSE),
    (12,'home','12 Place du Capitole','Toulouse','31000','France',TRUE),
    (13,'home','8 Promenade des Anglais','Nice','06000','France',TRUE),
    (14,'home','3 Rue Crébillon','Nantes','44000','France',TRUE),
    (15,'home','12 Place Kléber','Strasbourg','67000','France',TRUE),
    (16,'home','7 Place de la Comédie','Montpellier','34000','France',TRUE),
    (17,'home','25 Grand Place','Lille','59000','France',TRUE),
    (18,'home','4 Place des Lices','Rennes','35000','France',TRUE),
    (19,'home','42 Rue Sainte-Catherine','Bordeaux','33000','France',TRUE),
    (2,'home','10 Rue Vite Gourmand','Bordeaux','33000','France',TRUE),
    (4,'home','28 Rue du Palais Gallien','Bordeaux','33000','France',TRUE),
    (5,'home','5 Cours Victor Hugo','Bordeaux','33000','France',TRUE);
