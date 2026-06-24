# Lecture 2: Designing a Database Schema

## Table of Contents

- [Introduction](#introduction)
- [Creating a Database Schema](#creating-a-database-schema)
- [Normalizing](#normalizing)
- [Relating](#relating)
- [CREATE TABLE](#create-table)
- [Data Types and Storage Classes](#data-types-and-storage-classes)
- [Type Affinities](#type-affinities)
- [Adding Types to Our Tables](#adding-types-to-our-tables)
- [Table Constraints](#table-constraints)
- [Column Constraints](#column-constraints)
- [Altering Tables](#altering-tables)

---

## Introduction

In this lecture, we will learn how to design our own database schemas.

Thus far, we have primarily worked with a database of books longlisted for the International Booker Prize. Now, we will look underneath the hood and see what commands can be used to create such a database.

First, let us open up `longlist.db` from Week 0. As a reminder, this database contained just one table called `longlist`. To see a snapshot:

```sql
SELECT "author", "title"
FROM "longlist"
LIMIT 5;
```

Here is a SQLite command that can shed more light on how this database was created:

```sql
.schema
```

This shows us the SQL statement used to create the table, including columns and their data types.

Next, let's open up the same database from Week 1 (with multiple related tables). Running `.schema` now shows many commands — one for each table. To see the schema for a specific table:

```sql
.schema books
```

---

## Creating a Database Schema

We are tasked with representing the **subway system of the city of Boston** through a database schema — including subway stations, different train lines, and the people who take the trains.

> **"Boston Subway Map"**

We need to decide:

1. What **tables** we will have
2. What **columns** each table will have
3. What **data types** to put in each column

---

## Normalizing

Observe this initial attempt at creating a table for Boston Subway data:

> **"First attempt at table for Boston subway"**

The table contains rider names, current stations, actions performed (entering/exiting), fares paid, and balance amounts.

### Redundancies

- Rider names are duplicated many times → separate into their own table with a unique ID
- Subway stations are duplicated → separate into their own table with a unique ID

**Normalizing** is the process of separating data this way. When normalizing, we put each entity in its own table. Any information about a specific entity goes into that entity's own table.

---

## Relating

We now need to decide how our entities (**riders** and **stations**) are related:

- A rider will likely visit **multiple** stations
- A station is likely to have **more than one** rider

This is a **many-to-many** relationship.

> **"Many-to-many relationship between riders and stations"**

Every rider must visit at least one station. A station could have no riders (perhaps temporarily out of order), but likely has multiple riders.

### Questions

> **Does the relationship have to be exactly as described here?**
>
> It is up to the database designer. You could add a constraint that says a station must have at least one rider.

---

## CREATE TABLE

Let us open a new database called `mbta.db` (MBTA = Massachusetts Bay Transportation Authority).

Creating the riders table:

```sql
CREATE TABLE "riders" (
    "id",
    "name"
);
```

Creating the stations table:

```sql
CREATE TABLE "stations" (
    "id",
    "name",
    "line"
);
```

Creating a **junction table** to relate the two entities:

```sql
CREATE TABLE "visits" (
    "rider_id",
    "station_id"
);
```

Each row tells us which station was visited by which rider.

### Questions

> **Is it necessary to indent the lines within the CREATE TABLE parentheses?**
>
> Not strictly, but we indent column names to adhere to **style conventions**.

---

## Data Types and Storage Classes

SQLite has **five storage classes**:

| Storage Class | Description |
|--------------|-------------|
| **Null** | Nothing, or empty value |
| **Integer** | Numbers without decimal points |
| **Real** | Decimal or floating point numbers |
| **Text** | Characters or strings |
| **Blob** | Binary Large Object (images, audio, etc.) |

A storage class can hold several data types. For example, the Integer storage class includes multiple integer data types of varying sizes.

> SQLite takes care of storing the input value under the right data type. We only need to choose a **storage class**.

### What Storage Class for Fares?

| Choice | Pros | Cons |
|--------|------|------|
| **Integer** | Store 10¢ as `10` | Unclear if it's cents or dollars |
| **Text** | Store as `"$0.10"` | Hard to do math operations |
| **Real** | Store as `0.10` | Floating point imprecision may cause errors |

---

## Type Affinities

Columns in SQLite don't always store one particular data type. They have **type affinities** — they try to convert an input value into the type they have an affinity for.

The five type affinities in SQLite are:

1. **Text**
2. **Numeric** (integer or real, based on best conversion)
3. **Integer**
4. **Real**
5. **Blob**

**Examples:**

- Inserting `"25"` (text) into an Integer-affinity column → converted to integer `25`
- Inserting `25` (integer) into a Text-affinity column → converted to text `"25"`

---

## Adding Types to Our Tables

First, drop the existing tables:

```sql
DROP TABLE "riders";
DROP TABLE "stations";
DROP TABLE "visits";
```

Then create a `schema.sql` file with type affinities:

```sql
CREATE TABLE "riders" (
    "id" INTEGER,
    "name" TEXT
);

CREATE TABLE "stations" (
    "id" INTEGER,
    "name" TEXT,
    "line" TEXT
);

CREATE TABLE "visits" (
    "rider_id" INTEGER,
    "station_id" INTEGER
);
```

### Questions

> **How do we get results to show up? The tables seem empty.**
>
> We haven't added any data yet. In Lecture 3, we will see how to insert, update, and delete rows.

> **Do we have a type affinity for Boolean?**
>
> Not in SQLite, but a workaround is to use `0` or `1` integer values.

---

## Table Constraints

Table constraints impose restrictions on values in our tables.

| Constraint | Description |
|-----------|-------------|
| **PRIMARY KEY** | Column must have unique values; identifies each row |
| **FOREIGN KEY** | Value must be found in the primary key column of a related table |

Updated `schema.sql` with constraints:

```sql
CREATE TABLE "riders" (
    "id" INTEGER,
    "name" TEXT,
    PRIMARY KEY("id")
);

CREATE TABLE "stations" (
    "id" INTEGER,
    "name" TEXT,
    "line" TEXT,
    PRIMARY KEY("id")
);

CREATE TABLE "visits" (
    "rider_id" INTEGER,
    "station_id" INTEGER,
    FOREIGN KEY("rider_id") REFERENCES "riders"("id"),
    FOREIGN KEY("station_id") REFERENCES "stations"("id")
);
```

> 💡 SQLite gives every table a primary key by default, known as the **row ID**, even if not explicitly defined.

Composite primary key example:

```sql
CREATE TABLE "visits" (
    "rider_id" INTEGER,
    "station_id" INTEGER,
    PRIMARY KEY("rider_id", "station_id")
);
```

> We probably don't want this here, since a rider should be able to visit a station more than once.

### Questions

> **Is it possible to include our own primary key for the visits table?**
>
> Yes! You could create an `id` column and make it the primary key if needed.

---

## Column Constraints

A column constraint applies to a specified column in the table.

| Constraint | Description |
|-----------|-------------|
| **CHECK** | Checks for a condition (e.g., values > 0) |
| **DEFAULT** | Uses a default value if none is supplied |
| **NOT NULL** | A null/empty value cannot be inserted |
| **UNIQUE** | Every value in this column must be unique |

Updated schema:

```sql
CREATE TABLE "riders" (
    "id" INTEGER,
    "name" TEXT,
    PRIMARY KEY("id")
);

CREATE TABLE "stations" (
    "id" INTEGER,
    "name" TEXT NOT NULL UNIQUE,
    "line" TEXT NOT NULL,
    PRIMARY KEY("id")
);

CREATE TABLE "visits" (
    "rider_id" INTEGER,
    "station_id" INTEGER,
    FOREIGN KEY("rider_id") REFERENCES "riders"("id"),
    FOREIGN KEY("station_id") REFERENCES "stations"("id")
);
```

> 💡 Primary key columns inherently include `NOT NULL` and `UNIQUE` — no need to specify them explicitly.

---

## Altering Tables

Consider an updated ER diagram where **"Rider"** is replaced with **"Card"** (CharlieCards) and a new **"Swipe"** entity is added.

### ALTER TABLE Commands

Rename a table:

```sql
ALTER TABLE "visits"
RENAME TO "swipes";
```

Add a column:

```sql
ALTER TABLE "swipes"
ADD COLUMN "swipetype" TEXT;
```

Rename a column:

```sql
ALTER TABLE "swipes"
RENAME COLUMN "swipetype" TO "type";
```

Drop a column:

```sql
ALTER TABLE "swipes"
DROP COLUMN "type";
```

### Final Updated Schema

```sql
CREATE TABLE "cards" (
    "id" INTEGER,
    PRIMARY KEY("id")
);

CREATE TABLE "stations" (
    "id" INTEGER,
    "name" TEXT NOT NULL UNIQUE,
    "line" TEXT NOT NULL,
    PRIMARY KEY("id")
);

CREATE TABLE "swipes" (
    "id" INTEGER,
    "card_id" INTEGER,
    "station_id" INTEGER,
    "type" TEXT NOT NULL CHECK("type" IN ('enter', 'exit', 'deposit')),
    "datetime" NUMERIC NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "amount" NUMERIC NOT NULL CHECK("amount" != 0),
    PRIMARY KEY("id"),
    FOREIGN KEY("station_id") REFERENCES "stations"("id"),
    FOREIGN KEY("card_id") REFERENCES "cards"("id")
);
```

**Key changes:**

- The `"datetime"` column uses the **numeric** type affinity (can store and display date values)
- `CURRENT_TIMESTAMP` is used as a **default** value
- `CHECK` constraints ensure `amount != 0` and `type` is one of `'enter'`, `'exit'`, `'deposit'`
- Foreign keys are properly mapped

### Questions

> **On trying to drop the table riders, an error comes up because the ID is a foreign key. How can the table be dropped?**
>
> Foreign key constraints are checked when dropping a table. Drop the foreign key column first.

> **How different is the syntax for MySQL or PostgreSQL?**
>
> Most SQLite syntax applies, but some minimal changes would be needed when porting.

> **If we don't specify a type affinity, what happens?**
>
> The default type affinity is **numeric**.

---

## Conclusion

This brings us to the conclusion of **Lecture 2** about Designing in SQL! For an interesting story about the origin of the name CharlieCard, read [this article from Celebrate Boston](https://www.celebrateboston.com/mbta/charlie-card). 🎉