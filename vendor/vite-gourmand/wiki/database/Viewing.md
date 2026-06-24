# Lecture 4: Viewing Data

## Table of Contents

- [Introduction](#introduction)
- [Views](#views)
- [Simplifying](#simplifying)
- [Aggregating](#aggregating)
- [Common Table Expressions (CTEs)](#common-table-expressions-ctes)
- [Partitioning](#partitioning)
- [Securing](#securing)
- [Soft Deletions](#soft-deletions)

---

## Introduction

Thus far, we have learned about concepts that allow us to design complex databases and write data into them. Now, we will explore ways in which to obtain **views** from these databases.

Let's go back to the database containing books longlisted for the International Booker Prize:

> **"Tables containing books and authors with a many-to-many relationship"**

To find a book written by the author **Han Kang**, we would need to go through three tables — first finding the author's ID, then the corresponding book IDs, then the book titles. Instead, is there a way to put together related information in a **single view**?

Yes! We can use **`JOIN`** to combine rows from two or more tables based on a related column:

> **"Table joining books, authored and authors"**

This makes it simple to observe that Han Kang authored *The White Book*.

We can also remove the ID columns for a cleaner view:

> **"Table joining books, authored and authors with the ID columns removed"**

---

## Views

A **view** is a virtual table defined by a query.

The new table created by a `JOIN` query can be saved as a view, to be further queried later on.

### Views Are Useful For

| Purpose | Description |
|---------|-------------|
| **Simplifying** | Putting together data from different tables to be queried more simply |
| **Aggregating** | Running aggregate functions and storing the results |
| **Partitioning** | Dividing data into logical pieces |
| **Securing** | Hiding columns that should be kept secure |

---

## Simplifying

Open `longlist.db` and run `.schema` to verify the three tables: `authors`, `authored`, and `books`.

### The Complex Way

To find books written by Fernanda Melchor:

```sql
SELECT "title" FROM "books"
WHERE "id" IN (
    SELECT "book_id" FROM "authored"
    WHERE "author_id" = (
        SELECT "id" FROM "authors"
        WHERE "name" = 'Fernanda Melchor'
    )
);
```

Three nested `SELECT` queries! 😰

### The Simplified Way — Using JOIN

```sql
SELECT "name", "title" FROM "authors"
JOIN "authored" ON "authors"."id" = "authored"."author_id"
JOIN "books" ON "books"."id" = "authored"."book_id";
```

> 💡 **Tip:** The primary key column of one table is usually joined to the corresponding foreign key column of the other table!

### Saving as a View

```sql
CREATE VIEW "longlist" AS
SELECT "name", "title" FROM "authors"
JOIN "authored" ON "authors"."id" = "authored"."author_id"
JOIN "books" ON "books"."id" = "authored"."book_id";
```

Now query it like a table:

```sql
SELECT * FROM "longlist";
```

And the simplified query becomes:

```sql
SELECT "title" FROM "longlist" WHERE "name" = 'Fernanda Melchor';
```

> A view is a **virtual table** — it does not consume much more disk space. Data is still stored in the underlying tables.

### Questions

> **Can we manipulate views to be ordered or displayed differently?**
>
> Yes! Example:
>
> ```sql
> SELECT "name", "title"
> FROM "longlist"
> ORDER BY "title";
> ```
>
> You could also include an `ORDER BY` clause in the query used to **create** the view.

---

## Aggregating

Finding the average rating of every book, rounded to 2 decimal places:

```sql
SELECT "book_id", ROUND(AVG("rating"), 2) AS "rating" 
FROM "ratings"
GROUP BY "book_id";
```

Adding the title and year using a `JOIN`:

```sql
SELECT "book_id", "title", "year", ROUND(AVG("rating"), 2) AS "rating" 
FROM "ratings"
JOIN "books" ON "ratings"."book_id" = "books"."id"
GROUP BY "book_id";
```

> Note the order of operations — `GROUP BY` comes **after** the `JOIN`.

### Saving as a View

```sql
CREATE VIEW "average_book_ratings" AS
SELECT "book_id" AS "id", "title", "year", ROUND(AVG("rating"), 2) AS "rating" 
FROM "ratings"
JOIN "books" ON "ratings"."book_id" = "books"."id"
GROUP BY "book_id";
```

Query the view:

```sql
SELECT * FROM "average_book_ratings";
```

> When more data is added to `ratings`, simply **requery** the view for updated aggregates!

### Temporary Views

To create views that exist **only** for the duration of your connection:

```sql
CREATE TEMPORARY VIEW "average_ratings_by_year" AS
SELECT "year", ROUND(AVG("rating"), 2) AS "rating" 
FROM "average_book_ratings" 
GROUP BY "year";
```

### Questions

> **Can temporary views be used to test whether a query works?**
>
> Yes! Temporary views are great for organizing data without storing that organization long-term.

---

## Common Table Expressions (CTEs)

| Scope | Lifetime |
|-------|----------|
| **Regular view** | Forever (stored in schema) |
| **Temporary view** | Duration of connection |
| **CTE** | Single query only |

Drop the existing view to reuse the name:

```sql
DROP VIEW "average_book_ratings";
```

Create a CTE:

```sql
WITH "average_book_ratings" AS (
    SELECT "book_id", "title", "year", ROUND(AVG("rating"), 2) AS "rating" 
    FROM "ratings"
    JOIN "books" ON "ratings"."book_id" = "books"."id"
    GROUP BY "book_id"
)
SELECT "year", ROUND(AVG("rating"), 2) AS "rating" 
FROM "average_book_ratings"
GROUP BY "year";
```

---

## Partitioning

Views can **partition** data — breaking it into smaller, useful pieces.

For example, a view for books longlisted in **2022**:

```sql
CREATE VIEW "2022" AS
SELECT "id", "title" FROM "books"
WHERE "year" = 2022;
```

Query it:

```sql
SELECT * FROM "2022";
```

### Questions

> **Can views be updated?**
>
> No, because views don't contain data directly. They **pull data** from the underlying tables each time they are queried. When an underlying table is updated, the view reflects those changes on the next query.

---

## Securing

Views can enhance database security by **limiting access** to certain data.

Consider a rideshare company's `rides` table with rider names (**PII** — Personally Identifiable Information). We can create a view that **anonymizes** the names:

```sql
CREATE VIEW "analysis" AS
SELECT "id", "origin", "destination", 'Anonymous' AS "rider" 
FROM "rides";
```

Query it:

```sql
SELECT * FROM "analysis";
```

> ⚠️ Although we can create an anonymized view, **SQLite does not allow access control**. An analyst could simply query the original `rides` table directly.

---

## Soft Deletions

A **soft deletion** involves marking a row as deleted instead of removing it.

### Setup

Add a `deleted` column:

```sql
ALTER TABLE "collections" 
ADD COLUMN "deleted" INTEGER DEFAULT 0;
```

Soft delete a row:

```sql
UPDATE "collections" 
SET "deleted" = 1 
WHERE "title" = 'Farmers working at dawn';
```

### Create a View for Current Collections

```sql
CREATE VIEW "current_collections" AS
SELECT "id", "title", "accession_number", "acquired" 
FROM "collections" 
WHERE "deleted" = 0;
```

Verify:

```sql
SELECT * FROM "current_collections";
```

### INSTEAD OF Triggers

Since you can't insert/delete directly from a view, use **`INSTEAD OF`** triggers.

#### Delete Trigger

```sql
CREATE TRIGGER "delete"
INSTEAD OF DELETE ON "current_collections"
FOR EACH ROW
BEGIN
    UPDATE "collections" SET "deleted" = 1 
    WHERE "id" = OLD."id";
END;
```

Now soft-delete through the view:

```sql
DELETE FROM "current_collections" 
WHERE "title" = 'Imaginative landscape';
```

#### Insert Trigger — Row Already Exists

```sql
CREATE TRIGGER "insert_when_exists"
INSTEAD OF INSERT ON "current_collections"
FOR EACH ROW 
WHEN NEW."accession_number" IN (
    SELECT "accession_number" FROM "collections"
)
BEGIN
    UPDATE "collections" 
    SET "deleted" = 0 
    WHERE "accession_number" = NEW."accession_number";
END;
```

#### Insert Trigger — Brand New Row

```sql
CREATE TRIGGER "insert_when_new"
INSTEAD OF INSERT ON "current_collections"
FOR EACH ROW
WHEN NEW."accession_number" NOT IN (
    SELECT "accession_number" FROM "collections"
)
BEGIN
    INSERT INTO "collections" ("title", "accession_number", "acquired")
    VALUES (NEW."title", NEW."accession_number", NEW."acquired");
END;
```

---

## Conclusion

This brings us to the conclusion of **Lecture 4** about Viewing in SQL! 👁️