# Lecture 3: Writing Data

## Table of Contents

- [Introduction](#introduction)
- [Database Schema](#database-schema)
- [Inserting Data](#inserting-data)
- [Other Constraints](#other-constraints)
- [Inserting Multiple Rows](#inserting-multiple-rows)
- [Deleting Data](#deleting-data)
- [Updating Data](#updating-data)
- [Triggers](#triggers)
- [Soft Deletions](#soft-deletions)

---

## Introduction

Last week, we learned how to create our own database schema. In this lecture, we'll explore how to **add**, **update**, and **delete** data in our databases.

The **Boston MFA** (Museum of Fine Arts) is a century-old museum in Boston. The MFA manages a vast collection of historical and contemporary artifacts and artwork. They likely use a database of some kind to store data about their art and artifacts.

When a new artifact is added to their collection, we can imagine they would **insert** the corresponding data into their database. Similarly, there are use cases in which data might need to be **read**, **updated** or **deleted**.

We will focus now on the creation (or insertion) of data in a Boston MFA database.

---

## Database Schema

Consider this schema that the MFA might use for its collection:

> **"MFA Collections Table containing IDs, titles of artwork and other information"**

Each row contains:

- The **title** for a piece of artwork
- The **accession_number** — a unique ID used by the museum internally
- A **date** indicating when the art was acquired
- An **ID** which serves as the primary key

We can imagine that the database administrator runs an SQL query to insert each piece of artwork into the table.

### Setting Up

1. Create a database called `mfa.db`
2. Read the schema file `schema.sql` into the database (this creates the `collections` table)
3. Confirm the table has been created:

```sql
SELECT * FROM "collections";
```

This should give an **empty result** because the table doesn't have any data yet.

---

## Inserting Data

The SQL statement **`INSERT INTO`** is used to insert a row of data into a given table:

```sql
INSERT INTO "collections" ("id", "title", "accession_number", "acquired")
VALUES (1, 'Profusion of flowers', '56.257', '1956-04-12');
```

This command requires:

- The **list of columns** that will receive new data
- The **values** to be added to each column, in the same order

Running `INSERT INTO` returns nothing, but we can confirm the row is present:

```sql
SELECT * FROM "collections";
```

### Auto-incrementing Primary Keys

Typing out the primary key manually (1, 2, 3…) might result in errors. SQLite can fill out primary key values **automatically** — just omit the ID column:

```sql
INSERT INTO "collections" ("title", "accession_number", "acquired")
VALUES ('Farmers working at dawn', '11.6152', '1911-08-03');
```

Verify with:

```sql
SELECT * FROM "collections";
```

> SQLite assigns the next primary key by **incrementing** the highest existing value — in this case, `2`.

### Questions

> **If we delete a row with primary key 1, will SQLite assign primary key 1 to the next inserted row?**
>
> No. SQLite selects the **highest** primary key value in the table and increments it.

---

## Other Constraints

The schema file `schema.sql` contains:

```sql
CREATE TABLE "collections" (
    "id" INTEGER,
    "title" TEXT NOT NULL,
    "accession_number" TEXT NOT NULL UNIQUE,
    "acquired" NUMERIC,
    PRIMARY KEY("id")
);
```

### UNIQUE Constraint

Inserting a row with a **repeated** accession number triggers an error:

```
Runtime error: UNIQUE constraint failed: collections.accession_number (19)
```

### NOT NULL Constraint

Inserting a row with a **NULL** title:

```sql
INSERT INTO "collections" ("title", "accession_number", "acquired")
VALUES(NULL, NULL, '1900-01-10');
```

Results in:

```
Runtime error: NOT NULL constraint failed: collections.title (19)
```

> Schema constraints are **guardrails** that protect us from adding rows that do not follow the schema.

---

## Inserting Multiple Rows

We can insert more than one row at a time by separating rows with **commas**:

```sql
INSERT INTO "collections" ("title", "accession_number", "acquired") 
VALUES 
('Imaginative landscape', '56.496', NULL),
('Peonies and butterfly', '06.1899', '1906-01-01');
```

> The museum may not always know when a painting was acquired, hence `acquired` can be `NULL`.

Verify:

```sql
SELECT * FROM "collections";
```

### Importing from CSV

Data can also be stored in CSV format. SQLite can import CSV files directly:

```sql
.import --csv --skip 1 mfa.csv collections
```

| Argument | Meaning |
|----------|---------|
| `--csv` | Indicates we are importing a CSV file |
| `--skip 1` | Skip the first (header) row |

### Importing CSV Without IDs

If the CSV file doesn't contain primary key values, use a **temporary table**:

```sql
.import --csv mfa.csv temp
```

> Without `--skip 1`, SQLite recognizes the first row as the header and uses it for column names.

Verify the temp table:

```sql
SELECT * FROM "temp";
```

Move data from temp to collections (SQLite auto-generates primary keys):

```sql
INSERT INTO "collections" ("title", "accession_number", "acquired") 
SELECT "title", "accession_number", "acquired" FROM "temp";
```

Clean up:

```sql
DROP TABLE "temp";
```

### Questions

> **Can we place columns in specific positions while inserting?**
>
> While we can change the **ordering of values** in the `INSERT INTO` command, the order of column names follows the same order used while **creating** the table.

> **What happens if one of the multiple rows violates a constraint?**
>
> If even **one** row violates a constraint, the entire insertion command will result in an error and **none** of the rows will be inserted.

> **After inserting data from the CSV, one cell was empty and not NULL. Why?**
>
> When imported from CSV, a missing value is interpreted as **empty text**, not `NULL`. You can run queries afterward to convert empty values to `NULL`.

---

## Deleting Data

### Delete All Rows

```sql
DELETE FROM "collections";
```

> ⚠️ This deletes **all** rows! Don't run this unless you intend to.

### Delete Specific Rows

By title:

```sql
DELETE FROM "collections"
WHERE "title" = 'Spring outing';
```

Where acquired is NULL:

```sql
DELETE FROM "collections"
WHERE "acquired" IS NULL;
```

By date range (paintings acquired before 1909):

```sql
DELETE FROM "collections"
WHERE "acquired" < '1909-01-01';
```

### Foreign Key Considerations

Deleting data can impact **database integrity**. Consider an updated schema with `artists`, `collections`, and a junction table `created`:

> **"Three tables: artists, created, collections"**

Trying to delete an artist referenced by a foreign key:

```sql
DELETE FROM "artists"
WHERE "name" = 'Unidentified artist';
```

Results in:

```
Runtime error: FOREIGN KEY constraint failed (19)
```

**Solution 1:** Delete corresponding rows from the junction table first:

```sql
DELETE FROM "created"
WHERE "artist_id" = (
    SELECT "id"
    FROM "artists"
    WHERE "name" = 'Unidentified artist'
);
```

Then delete the artist:

```sql
DELETE FROM "artists"
WHERE "name" = 'Unidentified artist';
```

**Solution 2:** Use `ON DELETE` actions in the schema:

| Action | Behavior |
|--------|----------|
| `ON DELETE RESTRICT` | Prevents deletion when foreign key is violated |
| `ON DELETE NO ACTION` | Allows deletion; nothing happens to references |
| `ON DELETE SET NULL` | Sets foreign key references to `NULL` |
| `ON DELETE SET DEFAULT` | Sets foreign key references to a default value |
| `ON DELETE CASCADE` | Deletes the referencing foreign key rows too |

Example schema with cascade:

```sql
FOREIGN KEY("artist_id") REFERENCES "artists"("id") ON DELETE CASCADE
FOREIGN KEY("collection_id") REFERENCES "collections"("id") ON DELETE CASCADE
```

Now deleting an artist **cascades** to the `created` table:

```sql
DELETE FROM "artists"
WHERE "name" = 'Unidentified artist';
```

Verify:

```sql
SELECT * FROM "created";
```

### Questions

> **We deleted an artist with ID 3. Can we make the next inserted row have ID 3?**
>
> By default, SQLite increments from the largest existing ID. But you can use the `AUTOINCREMENT` keyword to repurpose deleted IDs.

---

## Updating Data

Use the **`UPDATE`** command to modify existing data:

```sql
UPDATE "created"
SET "artist_id" = (
    SELECT "id"
    FROM "artists"
    WHERE "name" = 'Li Yin'
)
WHERE "collection_id" = (
    SELECT "id"
    FROM "collections"
    WHERE "title" = 'Farmers working at dawn'
);
```

**Breakdown:**

1. **Table to update:** `created`
2. **New value:** The ID of Li Yin
3. **Which rows:** Where the collection is "Farmers working at dawn"

---

## Triggers

A **trigger** is a SQL statement that runs automatically in response to another SQL statement (`INSERT`, `UPDATE`, or `DELETE`).

Triggers are useful for maintaining **data consistency** and automating tasks across related tables.

### Creating a "Sell" Trigger

When artwork is sold (deleted from `collections`), log it in `transactions`:

```sql
CREATE TABLE "transactions" (
    "id" INTEGER,
    "title" TEXT,
    "action" TEXT,
    PRIMARY KEY("id")
);
```

```sql
CREATE TRIGGER "sell" 
BEFORE DELETE ON "collections"
BEGIN
    INSERT INTO "transactions" ("title", "action")
    VALUES (OLD."title", 'sold');
END;
```

- Runs **before** a row is deleted from `collections`
- **`OLD`** refers to the row being deleted
- `OLD."title"` accesses the title of the row about to be deleted

### Creating a "Buy" Trigger

When artwork is bought (inserted into `collections`), log it:

```sql
CREATE TRIGGER "buy" 
AFTER INSERT ON "collections"
BEGIN
    INSERT INTO "transactions" ("title", "action")
    VALUES (NEW."title", 'bought');
END;
```

- Runs **after** a new row is inserted
- **`NEW`** refers to the row being inserted

### Questions

> **Can we have multiple SQL statements inside a trigger?**
>
> Yes, you can have multiple statements inside the `BEGIN` and `END` blocks, separated by semicolons.

---

## Soft Deletions

**Soft deletion** means marking data as deleted rather than actually removing it from the database.

### Setup

Add a `deleted` column with a default value of `0`:

```sql
ALTER TABLE "collections"
ADD COLUMN "deleted" INTEGER DEFAULT 0;
```

### Soft Delete a Row

```sql
UPDATE "collections"
SET "deleted" = 1
WHERE "title" = 'Farmers working at dawn';
```

### Query Non-Deleted Rows

```sql
SELECT * FROM "collections"
WHERE "deleted" != 1;
```

> ✅ Data can be **recovered** if needed and maintains a complete historical record.
>
> ⚠️ It's still important to comply with **data privacy regulations** that require data to be truly deleted.

---

## Conclusion

This brings us to the conclusion of **Lecture 3** about Writing in SQL! ✍️