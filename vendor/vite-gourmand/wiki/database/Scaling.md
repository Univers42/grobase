# Lecture 6: Scaling

## Table of Contents

- [Introduction](#introduction)
- [MySQL](#mysql)
  - [Creating the cards Table](#creating-the-cards-table)
  - [Creating the stations Table](#creating-the-stations-table)
  - [Creating the swipes Table](#creating-the-swipes-table)
  - [Altering Tables](#altering-tables)
  - [Stored Procedures](#stored-procedures)
  - [Stored Procedures with Parameters](#stored-procedures-with-parameters)
- [PostgreSQL](#postgresql)
  - [Creating PostgreSQL Tables](#creating-postgresql-tables)
- [Scaling with MySQL](#scaling-with-mysql)
- [Access Controls](#access-controls)
- [SQL Injection Attacks](#sql-injection-attacks)

---

## Introduction

Thus far, we have learned how to design and create databases, read and write data, and optimize queries. Now, we will understand how to do all these things at a **larger scale**.

> **Scalability** is the ability to increase or decrease the capacity of an application or database to meet demand.

Social media platforms and banking systems are examples of applications that might need to scale.

### SQLite vs. MySQL vs. PostgreSQL

| Feature | SQLite | MySQL / PostgreSQL |
|---------|--------|-------------------|
| Type | Embedded database | Database servers |
| Hardware | Runs locally | Often run on dedicated hardware |
| Storage | Disk | Can store data on **RAM** for faster queries |
| Connection | Direct file access | Connect over the internet |

---

## MySQL

We will use the **MBTA database** from previous lectures:

> **"ER Diagram for MBTA database with Card, Swipe and Station entities"**

Riders have a CharlieCard they swipe at stations. Cards can be recharged. The MBTA tracks cards, not riders.

### Connecting to MySQL

```bash
mysql -u root -h 127.0.0.1 -P 3306 -p
```

| Flag | Meaning |
|------|---------|
| `-u root` | Connect as the root (admin) user |
| `-h 127.0.0.1` | Localhost address |
| `-P 3306` | Default MySQL port |
| `-p` | Prompt for password |

Show existing databases:

```sql
SHOW DATABASES;
```

Create and use the MBTA database:

```sql
CREATE DATABASE `mbta`;
USE `mbta`;
```

> 💡 In MySQL, use **backticks** (`` ` ``) instead of double quotes for identifiers.

---

### Creating the cards Table

MySQL has more granularity with integer types:

| Type | Size | Range |
|------|------|-------|
| `TINYINT` | 1 byte | -128 to 127 |
| `SMALLINT` | 2 bytes | -32,768 to 32,767 |
| `MEDIUMINT` | 3 bytes | ±8 million |
| `INT` | 4 bytes | ±2 billion |
| `BIGINT` | 8 bytes | ±9 quintillion |

> For **unsigned** integers, the maximum value **doubles**.

```sql
CREATE TABLE `cards` (
    `id` INT AUTO_INCREMENT,
    PRIMARY KEY(`id`)
);
```

> **`AUTO_INCREMENT`** replaces SQLite's automatic ID behavior.

#### Questions

> **Should the ID be unsigned?**
>
> Yes, you can add the `UNSIGNED` keyword to make it unsigned.

---

### Creating the stations Table

Show tables and describe them:

```sql
SHOW TABLES;
DESCRIBE `cards`;
```

#### MySQL Text Types

| Type | Use Case |
|------|----------|
| `CHAR` | Fixed-width string |
| `VARCHAR` | Variable-length string |
| `TEXT` / `TINYTEXT` / `MEDIUMTEXT` / `LONGTEXT` | Longer text (paragraphs, pages) |
| `BLOB` | Binary strings |
| `ENUM` | Single predefined option from a list |
| `SET` | Multiple options in a single cell |

```sql
CREATE TABLE `stations` (
    `id` INT AUTO_INCREMENT,
    `name` VARCHAR(32) NOT NULL UNIQUE,
    `line` ENUM('blue', 'green', 'orange', 'red') NOT NULL,
    PRIMARY KEY(`id`)
);
```

#### Questions

> **Can we use a table as input to ENUM?**
>
> Possibly with a nested SELECT, but this isn't recommended if values change over time. Explicitly state values instead.

> **Is using VARCHAR(300) okay if we don't know the length?**
>
> There's a trade-off — you lose 300 bytes per row. Start smaller, then `ALTER TABLE` to increase if needed.

---

### Creating the swipes Table

#### MySQL Date/Time Types

| Type | Description |
|------|-------------|
| `DATE` | Date only |
| `YEAR` | Year only |
| `TIME` | Time only |
| `DATETIME` | Date and time |
| `TIMESTAMP` | More precise timestamp |

#### MySQL Real Number Types

| Type | Precision |
|------|-----------|
| `FLOAT` | Single precision |
| `DOUBLE PRECISION` | Double precision |
| `DECIMAL(M,D)` | Fixed precision (M digits, D after decimal) |

```sql
CREATE TABLE `swipes` (
    `id` INT AUTO_INCREMENT,
    `card_id` INT,
    `station_id` INT,
    `type` ENUM('enter', 'exit', 'deposit') NOT NULL,
    `datetime` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `amount` DECIMAL(5,2) NOT NULL CHECK(`amount` != 0),
    PRIMARY KEY(`id`),
    FOREIGN KEY(`station_id`) REFERENCES `stations`(`id`),
    FOREIGN KEY(`card_id`) REFERENCES `cards`(`id`)
);
```

> In the `DESCRIBE` output, foreign key columns show `MUL` (multiple) under the Key field.

#### Questions

> **Is there a precedence for constraints?**
>
> No, constraints work together. MySQL allows them in any order.

> **Does MySQL have type affinities?**
>
> No. MySQL has strict data types and will **not** allow entering data of a different type.

---

### Altering Tables

MySQL allows more fundamental alterations than SQLite:

```sql
ALTER TABLE `stations` 
MODIFY `line` ENUM('blue', 'green', 'orange', 'red', 'silver') NOT NULL;
```

> Use `MODIFY` (MySQL-specific) in addition to `ALTER TABLE`.

---

### Stored Procedures

**Stored procedures** automate SQL statements for repeated use.

#### Setup

```sql
USE `mfa`;

ALTER TABLE `collections` 
ADD COLUMN `deleted` TINYINT DEFAULT 0;
```

> `TINYINT` is sufficient since the column only holds `0` or `1`.

#### Changing the Delimiter

MySQL requires changing the delimiter before creating procedures:

```sql
delimiter //
```

#### Creating the Procedure

```sql
CREATE PROCEDURE `current_collection`()
BEGIN
    SELECT `title`, `accession_number`, `acquired` 
    FROM `collections` 
    WHERE `deleted` = 0;
END//
```

Reset the delimiter:

```sql
delimiter ;
```

#### Calling the Procedure

```sql
CALL current_collection();
```

Soft-delete and call again:

```sql
UPDATE `collections` 
SET `deleted` = 1 
WHERE `title` = 'Farmers working at dawn';

CALL current_collection();
```

#### Questions

> **Can we add parameters to stored procedures?**
>
> Yes! See the next section.

> **Can we call one procedure from another?**
>
> Yes. You could put most any SQL statement in a procedure.

---

### Stored Procedures with Parameters

Create a `transactions` table:

```sql
CREATE TABLE `transactions` (
    `id` INT AUTO_INCREMENT,
    `title` VARCHAR(64) NOT NULL,
    `action` ENUM('bought', 'sold') NOT NULL,
    PRIMARY KEY(`id`)
);
```

Create a parameterized procedure:

```sql
delimiter //
CREATE PROCEDURE `sell`(IN `sold_id` INT)
BEGIN
    UPDATE `collections` SET `deleted` = 1 
    WHERE `id` = `sold_id`;
    INSERT INTO `transactions` (`title`, `action`)
    VALUES ((SELECT `title` FROM `collections` WHERE `id` = `sold_id`), 'sold');
END//
delimiter ;
```

Call it:

```sql
CALL `sell`(2);
```

> ⚠️ Calling `sell` on the same ID more than once could add duplicates to `transactions`. Use programming constructs (IF, WHILE, etc.) to add logic.

#### Available Programming Constructs in MySQL

| Construct | Description |
|-----------|-------------|
| `IF...THEN...ELSE` | Conditional logic |
| `CASE` | Multi-branch conditional |
| `WHILE` | Loop |
| `REPEAT` | Loop (runs at least once) |
| `LOOP` | General loop |
| `DECLARE` | Variable declaration |

---

## PostgreSQL

PostgreSQL provides another option for scaling databases.

### Integer Types

| Type | Size | Range |
|------|------|-------|
| `SMALLINT` | 2 bytes | ±32,768 |
| `INTEGER` | 4 bytes | ±2 billion |
| `BIGINT` | 8 bytes | ±9 quintillion |

PostgreSQL also provides **unsigned** integers and a **`SERIAL`** type for auto-incrementing primary keys.

### Connecting to PostgreSQL

```bash
psql postgresql://postgres@127.0.0.1:5432/postgres
```

| Command | Action |
|---------|--------|
| `\l` | List all databases |
| `\c "mbta"` | Connect to a database |
| `\dt` | List tables |
| `\d "table_name"` | Describe a table |
| `\q` | Exit |

Create the database:

```sql
CREATE DATABASE "mbta";
```

#### Questions

> **How do you know if your query has an error in PostgreSQL?**
>
> PostgreSQL will give you helpful error messages. If the server doesn't respond normally, there may be an error.

---

### Creating PostgreSQL Tables

#### cards

```sql
CREATE TABLE "cards" (
    "id" SERIAL,
    PRIMARY KEY("id")
);
```

#### stations

```sql
CREATE TABLE "stations" (
    "id" SERIAL,
    "name" VARCHAR(32) NOT NULL UNIQUE,
    "line" VARCHAR(32) NOT NULL,
    PRIMARY KEY("id")
);
```

#### Custom ENUM Type

```sql
CREATE TYPE "swipe_type" AS ENUM('enter', 'exit', 'deposit');
```

> In PostgreSQL, ENUMs are created as **separate types**, not inline.

#### PostgreSQL Date/Time Types

| Type | Description |
|------|-------------|
| `TIMESTAMP` | Date and time |
| `DATE` | Date only |
| `TIME` | Time only |
| `INTERVAL` | Duration between times |

> The `DECIMAL` type is called **`NUMERIC`** in PostgreSQL.

#### swipes

```sql
CREATE TABLE "swipes" (
    "id" SERIAL,
    "card_id" INT,
    "station_id" INT,
    "type" "swipe_type" NOT NULL,
    "datetime" TIMESTAMP NOT NULL DEFAULT now(),
    "amount" NUMERIC(5,2) NOT NULL CHECK("amount" != 0),
    PRIMARY KEY("id"),
    FOREIGN KEY("station_id") REFERENCES "stations"("id"),
    FOREIGN KEY("card_id") REFERENCES "cards"("id")
);
```

> `now()` is a PostgreSQL function that returns the current timestamp.

---

## Scaling with MySQL

### Vertical Scaling

Increasing capacity by increasing the **computing power** of the database server.

### Horizontal Scaling

Increasing capacity by distributing load across **multiple servers** (replication).

### Replication Models

| Model | Description |
|-------|-------------|
| **Single-leader** | One server handles writes; copies changes to followers |
| **Multi-leader** | Multiple servers receive writes (more complex) |
| **Leaderless** | No designated leader |

#### Single-Leader Details

- **Followers** are **read replicas** (read-only copies)
- **Leader** processes all writes

| Replication Type | Behavior | Best For |
|-----------------|----------|----------|
| **Synchronous** | Leader waits for followers to replicate | Finance, healthcare (data consistency critical) |
| **Asynchronous** | Leader doesn't wait | Social media (speed critical) |

### Sharding

Splitting the database into **shards** across multiple servers.

> ⚠️ **Pitfalls:**
> - **Hotspots** — one server becomes more frequently accessed than others
> - **Single point of failure** — if one server goes down without replication, the database is incomplete

---

## Access Controls

Create a new user:

```sql
CREATE USER 'carter' IDENTIFIED BY 'password';
```

By default, new users have **very few privileges**. The root user has access to most everything.

### Granting Access

```sql
GRANT SELECT ON `rideshare`.`analysis` TO 'carter';
```

Now `carter` can:

- ✅ `USE rideshare;`
- ✅ `SELECT * FROM analysis;`
- ❌ `SELECT * FROM rides;` (access denied!)

> This demonstrates MySQL's **access control**: multiple users can access the database, but only some can see confidential data.

---

## SQL Injection Attacks

A malicious user **injects** SQL phrases to complete an existing query in an undesirable way.

### Example: Login Bypass

Normal query:

```sql
SELECT `id` FROM `users`
WHERE `user` = 'Carter' AND `password` = 'password';
```

Malicious input (`password' OR '1' = '1`):

```sql
SELECT `id` FROM `users`
WHERE `user` = 'Carter' AND `password` = 'password' OR '1' = '1';
```

This returns **all** users! 😱

### Prepared Statements

Use **prepared statements** to prevent injection:

```sql
PREPARE `balance_check`
FROM 'SELECT * FROM `accounts`
WHERE `id` = ?';
```

The `?` acts as a **safeguard** against unintended SQL execution.

Execute it safely:

```sql
SET @id = 1;
EXECUTE `balance_check` USING @id;
```

Even with malicious input:

```sql
SET @id = '1 UNION SELECT * FROM `accounts`';
EXECUTE `balance_check` USING @id;
```

> ✅ Same result — only the balance for user ID 1! The prepared statement **escapes** malicious SQL.

### Questions

> **Does the prepared statement only use the first condition from the variable?**
>
> The prepared statement performs **escaping** — it finds all potentially malicious portions and neutralizes them.

> **Is this similar to why we shouldn't use formatted strings in Python for SQL queries?**
>
> Yes! Format strings in Python are equally susceptible to SQL injection attacks.

---

## Conclusion

This brings us to the conclusion of **Lecture 6** about Scaling in SQL and this course — *CS50's Introduction to Databases with SQL*! 🎓🎉