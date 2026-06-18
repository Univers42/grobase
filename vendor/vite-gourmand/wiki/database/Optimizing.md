# Lecture 5: Optimizing

## Table of Contents

- [Introduction](#introduction)
- [Index](#index)
- [Index across Multiple Tables](#index-across-multiple-tables)
- [Space Trade-off](#space-trade-off)
- [Time Trade-off](#time-trade-off)
- [Partial Index](#partial-index)
- [Vacuum](#vacuum)
- [Concurrency](#concurrency)
- [Transactions](#transactions)
- [Race Conditions](#race-conditions)

---

## Introduction

This week, we will learn how to **optimize** our SQL queries, both for time and space. We will also learn how to run queries **concurrently**.

We will do all of this in the context of a new database — the **Internet Movies Database** (IMDb). Our SQLite database is compiled from the large online database at [imdb.com](https://imdb.com).

> **"Statistics about the IMDb database"** — It has much more data than any of the databases we've worked with so far!

Here is the ER Diagram:

> **"IMDb ER Diagram — people, movies, and ratings entities"**

---

## Index

Open `movies.db` in SQLite. Running `.schema` shows the tables. The many-to-many relationship between **Person** and **Movie** is implemented via a joint table called `stars`.

Peek into the movies table:

```sql
SELECT * FROM "movies" LIMIT 5;
```

### Searching Without an Index

```sql
SELECT * FROM "movies"
WHERE "title" = 'Cars';
```

Enable timing with `.timer on` to see how long the query takes. Under the hood, this triggers a **scan** of the entire table — row by row, top to bottom.

### Creating an Index

An **index** is a structure used to speed up the retrieval of rows from a table:

```sql
CREATE INDEX "title_index" ON "movies" ("title");
```

Running the same query now is **significantly faster** (in lecture, ~8x faster)!

### Explain Query Plan

Use `EXPLAIN QUERY PLAN` to see what strategy SQLite uses:

```sql
EXPLAIN QUERY PLAN
SELECT * FROM "movies"
WHERE "title" = 'Cars';
```

Drop the index to compare:

```sql
DROP INDEX "title_index";
```

### Questions

> **Do databases not have implicit algorithms to optimize searching?**
>
> Yes, for some columns. If a column is a **primary key**, an index is automatically created. But for regular columns like `"title"`, there is no automatic optimization.

> **Would it be advisable to create an index for every column?**
>
> While it seems useful, there are **trade-offs** with space and insertion time. More on this shortly!

---

## Index across Multiple Tables

Finding all movies Tom Hanks starred in:

```sql
SELECT "title" FROM "movies"
WHERE "id" IN (
    SELECT "movie_id" FROM "stars"
    WHERE "person_id" = (
        SELECT "id" FROM "people"
        WHERE "name" = 'Tom Hanks'
    )
);
```

`EXPLAIN QUERY PLAN` shows two scans needed — `people` and `stars`. The `movies` table is **not** scanned because we search by its primary key (auto-indexed).

### Creating Indexes

```sql
CREATE INDEX "person_index" ON "stars" ("person_id");
CREATE INDEX "name_index" ON "people" ("name");
```

### Covering Indexes

A **covering index** means all information needed can be found **within the index itself** — no need to look up the table separately.

To make the `stars` index a covering index, include both search and lookup columns:

```sql
DROP INDEX "person_index";
CREATE INDEX "person_index" ON "stars" ("person_id", "movie_id");
```

Verify:

```sql
EXPLAIN QUERY PLAN
SELECT "title" FROM "movies" WHERE "id" IN (
    SELECT "movie_id" FROM "stars" WHERE "person_id" = (
        SELECT "id" FROM "people" WHERE "name" = 'Tom Hanks'
    )
);
```

> Result: Two **covering indexes** → much faster search! (In lecture, an order of magnitude faster)

---

## Space Trade-off

Indexes occupy **additional space** — we gain query speed but lose storage.

### How Indexes Are Stored: B-Trees

An index is stored as a **B-Tree** (balanced tree):

```
         [Frozen | Soul]
        /        |       \
   [A-F...]   [G-S...]   [T-Z...]
```

- A **sorted copy** of the indexed column is made
- This copy is linked back to original rows via primary keys
- The data is broken into **nodes** for efficient navigation

---

## Time Trade-off

It takes **longer to insert** data into a column with an index. Each insertion requires traversing the B-tree to find the correct position.

---

## Partial Index

A **partial index** includes only a subset of rows, saving space.

Example — index only movies released in 2023:

```sql
CREATE INDEX "recents" ON "movies" ("title")
WHERE "year" = 2023;
```

Verify:

```sql
EXPLAIN QUERY PLAN
SELECT "title" FROM "movies"
WHERE "year" = 2023;
```

### Questions

> **Are indexes saved in the schema?**
>
> Yes! Run `.schema` to see them listed.

---

## Vacuum

SQLite allows us to **vacuum** data — cleaning up space from deleted data that's only marked as available.

Check database size:

```bash
du -b movies.db
```

Drop an index:

```sql
DROP INDEX "person_index";
```

The size doesn't decrease immediately! Run:

```sql
VACUUM;
```

Now check the size again — it should be **smaller**.

### Questions

> **Is it possible to vacuum faster?**
>
> Each vacuum takes a different amount of time depending on the amount of space to reclaim.

> **If a delete doesn't actually remove data, could we still retrieve deleted rows?**
>
> Forensics experts can sometimes find "deleted" data. But after a `VACUUM`, deleted rows are **not recoverable**.

---

## Concurrency

**Concurrency** is the simultaneous handling of multiple queries or interactions by the database.

### Example: Bank Transfer

> **"Accounts table: Alice sends $10 to Bob"**

To complete this transaction, we need to:

1. Add $10 to Bob's account
2. Subtract $10 from Alice's account

If someone sees the database **between** these two updates, they could get an incorrect view of the total money.

---

## Transactions

A **transaction** is an individual unit of work that cannot be broken into smaller pieces.

### ACID Properties

| Property | Description |
|----------|-------------|
| **Atomicity** | Can't be broken down into smaller pieces |
| **Consistency** | Should not violate a database constraint |
| **Isolation** | Multiple users' transactions cannot interfere with each other |
| **Durability** | Changes persist even after a failure |

### Example: Bank Transfer

```sql
BEGIN TRANSACTION;
UPDATE "accounts" SET "balance" = "balance" + 10 WHERE "id" = 2;
UPDATE "accounts" SET "balance" = "balance" - 10 WHERE "id" = 1;
COMMIT;
```

> Without `COMMIT`, neither `UPDATE` runs! This keeps the transaction **atomic**.

### ROLLBACK

If a statement fails (e.g., Alice's balance goes negative, violating a constraint), use `ROLLBACK` to revert:

```sql
BEGIN TRANSACTION;
UPDATE "accounts" SET "balance" = "balance" + 10 WHERE "id" = 2;
UPDATE "accounts" SET "balance" = "balance" - 10 WHERE "id" = 1; -- Constraint error
ROLLBACK;
```

---

## Race Conditions

A **race condition** occurs when multiple entities simultaneously access and make decisions based on a shared value, potentially causing inconsistencies.

Transactions are processed in **isolation** to prevent this. SQLite uses **locks**:

| Lock State | Description |
|-----------|-------------|
| **UNLOCKED** | Default state; no user accessing the database |
| **SHARED** | Reading data; allows other reads simultaneously |
| **EXCLUSIVE** | Writing/updating; no other transactions allowed (not even reads) |

### Questions

> **How do we decide when a transaction can get an exclusive lock?**
>
> Different algorithms can be used (e.g., first-come-first-served). An exclusive lock blocks all other transactions — a necessary trade-off for consistency.

> **What is the granularity of locking?**
>
> In SQLite, locking is **coarse** — it locks the entire database:
>
> ```sql
> BEGIN EXCLUSIVE TRANSACTION;
> ```
>
> If you don't complete this transaction and try to connect from another terminal, you'll get a "database is locked" error. SQLite has a module for ensuring exclusive locks are held only for the shortest necessary duration.

---

## Conclusion

This brings us to the conclusion of **Lecture 5** about Optimizing in SQL! ⚡