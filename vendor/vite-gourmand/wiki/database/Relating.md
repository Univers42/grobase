# Lecture 1: Relating Tables in Databases

## Table of Contents

- [Introduction](#introduction)
- [Entity Relationship Diagrams](#entity-relationship-diagrams)
- [Keys](#keys)
- [Subqueries](#subqueries)
- [IN](#in)
- [JOIN](#join)
- [Sets](#sets)
- [Groups](#groups)

---

## Introduction

Databases can have multiple tables. Last class, we saw a database of books longlisted, or nominated, for the International Booker Prize. We will now see that database has many different tables inside it — for books, authors, publishers and so on.

First, open up the database using SQLite in the terminal of your Codespace.

We can use the following SQLite command to see all the tables in our database:

```sql
.tables
```

This command returns the names of the tables in `longlist.db` — 7 in all.

These tables have some relationships between them, and hence we call the database a **relational database**. Some examples of relationships:

- Authors **write** books.
- Publishers **publish** books.
- Books are **translated** by translators.

Consider our first example. Here is a snapshot of the `authors` and `books` tables with the author name and book title columns:

> ![first](https://cs50.harvard.edu/sql/notes/1/images/p6.jpg)

Just looking at these two columns, how can we tell who wrote which book? Even if we assume that every book is lined up next to its author, just looking at the authors table would give us no information about the books written by that author.

### Possible Ways to Organize Books and Authors

1. **The honor system** — the first row in the authors table will always correspond to the first row in the books table.
   - **Problem:** One may make a mistake (add a book but forget to add its corresponding author, or vice versa). Also, an author may have written more than one book or a book may be co-written by multiple authors.

2. **One-table approach** — This approach could result in **redundancy** (duplication of data) if one author writes multiple books or if a book is co-written by multiple authors.

> **"One-table approach: author with multiple books"**

After considering these ideas, having two different tables is the most efficient approach.

### Types of Relationships

| Relationship | Description |
|-------------|-------------|
| **One-to-one** | Each author writes only one book and each book is written by one author |
| **One-to-many** | An author can write multiple books |
| **Many-to-many** | One author can write multiple books, AND books can be co-written by multiple authors |

---

## Entity Relationship Diagrams

It is possible to visualize relationships using an **entity relationship (ER) diagram**.

Here is an ER diagram for the tables in `longlist.db`:

```
wrote          published       translated       has
Author ───── Book ───── Publisher   Book ───── Translator   Book ───── Rating
```

Each table is an **entity** in our database. The relationships between them are represented by the verbs connecting entities.

### Crow's Foot Notation

Each line in this diagram uses **crow's foot notation**:

| Symbol | Meaning |
|--------|---------|
| Circle (`○`) | Zero relations (optional) |
| Perpendicular line (`│`) | Exactly one (at least one required) |
| Crow's foot (`<`) | Many (related to many rows) |

**Reading the notation left to right:**

- An author writes **one** book → every author can have one book associated with them.
- A book is also written by **one** author → one-to-one.
- Adding the crow's foot → an author could be associated with **one or multiple** books, and a book can be written by **one or multiple** authors.

On observing the lines connecting the **Book** and **Translator** entities: books don't need to have a translator (zero to many translators). However, a translator translates **at least one** book, and possibly many.

### Questions

> **If we have some database, how do we know the relationships among the entities stored inside of it?**
>
> The exact relationships between entities are up to the **designer** of the database. An ER diagram is a tool to communicate these decisions to someone who wants to understand the database.

> **Once we know that a relationship exists between certain entities, how do we implement that in our database?**
>
> We will shortly see how we can use **keys** in SQL to relate tables to one another.

---

## Keys

### Primary Keys

Every book has a unique identifier called an **ISBN**. In database terms, the ISBN is a **primary key** — an identifier that is unique for every item in a table.

> **"Table with ISBNs and book titles"**

We can assign unique IDs to our publishers, authors and translators. Each ID would be the **primary key** of the table it belongs to.

### Foreign Keys

A **foreign key** is a primary key taken from a different table. By referencing the primary key of a different table, it helps relate the tables by forming a link between them.

> **"Relating the books and ratings tables using foreign key"**

The primary key of the `books` table is now a column in the `ratings` table. This forms a **one-to-many** relationship — a book can have multiple ratings.

> 💡 The ISBN is a long identifier (17 bytes). We can construct our own primary keys using simple numbers (1, 2, 3…) as long as each is unique.

For **many-to-many** relationships, we use a junction table:

> **"Relating the authors and books tables using a foreign key and another table"**

The `authored` table maps `book_id` to `author_id`.

### Questions

> **Can the IDs of the author and the book be the same?**
>
> Yes. Tables like `authored` are called "joint" or "junction" tables. We know which column references which primary key, so matching values are fine.

> **If we have a lot of joint tables, wouldn't that take up too much space?**
>
> There is a trade-off. These tables occupy more space but enable many-to-many relationships without redundancies.

> **On changing the ID of a book or author, does the ID get updated in the other tables as well?**
>
> An updated ID still needs to be unique. IDs are often abstracted away and we rarely change them.

---

## Subqueries

A **subquery** is a query inside another query (also called **nested queries**).

### One-to-Many Example

Finding books published by Fitzcarraldo Editions:

```sql
SELECT "title"
FROM "books"
WHERE "publisher_id" = (
    SELECT "id"
    FROM "publishers"
    WHERE "publisher" = 'Fitzcarraldo Editions'
);
```

**Notice that:**

- The subquery is in **parentheses**. The innermost query runs first.
- The inner query is **indented** for readability.

### More Examples

All ratings for *In Memory of Memory*:

```sql
SELECT "rating"
FROM "ratings"
WHERE "book_id" = (
    SELECT "id"
    FROM "books"
    WHERE "title" = 'In Memory of Memory'
);
```

Average rating for that book:

```sql
SELECT AVG("rating")
FROM "ratings"
WHERE "book_id" = (
    SELECT "id"
    FROM "books"
    WHERE "title" = 'In Memory of Memory'
);
```

### Many-to-Many Example

Finding the author(s) of *Flights* (requires three tables):

```sql
SELECT "name"
FROM "authors"
WHERE "id" = (
    SELECT "author_id"
    FROM "authored"
    WHERE "book_id" = (
        SELECT "id"
        FROM "books"
        WHERE "title" = 'Flights'
    )
);
```

---

## IN

The **`IN`** keyword checks whether a value is in a given list or set of values.

Finding all books written by Fernanda Melchor:

```sql
SELECT "title"
FROM "books"
WHERE "id" IN (
    SELECT "book_id"
    FROM "authored"
    WHERE "author_id" = (
        SELECT "id"
        FROM "authors"
        WHERE "name" = 'Fernanda Melchor'
    )
);
```

> The innermost query uses `=` (not `IN`) because we expect to find just **one** author named Fernanda Melchor.

### Questions

> **What if the value of an inner query is not found?**
>
> The inner query would return nothing, prompting the outer query to also return nothing. The outer query depends on the results of the inner query.

> **Is it necessary to use four spaces to indent a subquery?**
>
> No. The central idea is to make queries **readable**.

> **How can we implement a many-to-one relationship between tables?**
>
> The `authored` table would have multiple entries for the same book ID, each with a different author ID. Foreign key values can be repeated; primary key values are always unique.

---

## JOIN

The **`JOIN`** keyword combines two or more tables together.

### Example: Sea Lions Database

> **"Sea Lions database with tables: sea_lions, migrations"**

We join the tables on the sea lion ID (the common factor):

```sql
SELECT *
FROM "sea_lions"
JOIN "migrations" ON "migrations"."id" = "sea_lions"."id";
```

**Key points:**

- The `ON` keyword specifies which values match between tables.
- IDs in one table not present in the other **won't** appear in the result. This is called an **INNER JOIN**.

### Types of Joins

| Join Type | Behavior |
|-----------|----------|
| **`JOIN`** (INNER) | Only matching rows from both tables |
| **`LEFT JOIN`** | All rows from the left table; unmatched right values are `NULL` |
| **`RIGHT JOIN`** | All rows from the right table; unmatched left values are `NULL` |
| **`FULL JOIN`** | All rows from both tables |

**LEFT JOIN** example:

```sql
SELECT *
FROM "sea_lions"
LEFT JOIN "migrations" ON "migrations"."id" = "sea_lions"."id";
```

### NATURAL JOIN

When both tables share a column name for the join condition:

```sql
SELECT *
FROM "sea_lions"
NATURAL JOIN "migrations";
```

> The result does **not** have a duplicate `id` column. This works similarly to an INNER JOIN.

### Questions

> **In the sea lions database, how are the IDs created?**
>
> The IDs likely came from researchers tracking the sea lions — assigned at the source of the data itself.

> **If we are trying to join three tables, how can we know which the left or right tables are?**
>
> For each `JOIN` statement, the first table (before the keyword) is the **left** one. The table in the `JOIN` clause is the **right** one.

> **When we join tables, does the resulting joined table get saved?**
>
> No, the result is a **temporary** table or result set. It can be used only for the duration of the query.

> **Is there a default kind of JOIN?**
>
> Yes — just `JOIN` is actually an `INNER JOIN`, which is the default.

---

## Sets

On running a query, the results are called a **result set**.

### INTERSECT

People who are **both** authors and translators:

```sql
SELECT "name" FROM "translators"
INTERSECT
SELECT "name" FROM "authors";
```

### UNION

People who are **either** an author **or** a translator (or both):

```sql
SELECT "name" FROM "translators"
UNION
SELECT "name" FROM "authors";
```

> Every author and translator is included **only once**.

Adding a profession label:

```sql
SELECT 'author' AS "profession", "name" 
FROM "authors"
UNION
SELECT 'translator' AS "profession", "name" 
FROM "translators";
```

### EXCEPT

People who are authors **only** (not translators):

```sql
SELECT "name" FROM "authors"
EXCEPT
SELECT "name" FROM "translators";
```

### Practical Example

Books translated by **both** Sophie Hughes and Margaret Jull Costa:

```sql
SELECT "book_id" FROM "translated"
WHERE "translator_id" = (
    SELECT "id" FROM "translators"
    WHERE "name" = 'Sophie Hughes'
)
INTERSECT
SELECT "book_id" FROM "translated"
WHERE "translator_id" = (
    SELECT "id" FROM "translators"
    WHERE "name" = 'Margaret Jull Costa'
);
```

### Questions

> **Could we use INTERSECT, UNION etc. to perform operations on 3–4 sets?**
>
> Yes! To intersect 3 sets, use the `INTERSECT` operator twice. Important: ensure the same number and types of columns in all sets.

---

## Groups

### GROUP BY

For each book, find its average rating:

```sql
SELECT "book_id", AVG("rating") AS "average rating"
FROM "ratings"
GROUP BY "book_id";
```

### HAVING

Show only well-rated books (average rating over 4.0):

```sql
SELECT "book_id", ROUND(AVG("rating"), 2) AS "average rating"
FROM "ratings"
GROUP BY "book_id"
HAVING "average rating" > 4.0;
```

> **`HAVING`** specifies conditions for **groups**. **`WHERE`** specifies conditions for **individual rows**.

### Questions

> **Is it possible to see the number of ratings given to each book?**
>
> ```sql
> SELECT "book_id", COUNT("rating")
> FROM "ratings"
> GROUP BY "book_id";
> ```

> **Is it also possible to sort the data obtained here?**
>
> Yes:
>
> ```sql
> SELECT "book_id", ROUND(AVG("rating"), 2) AS "average rating"
> FROM "ratings"
> GROUP BY "book_id"
> HAVING "average rating" > 4.0
> ORDER BY "average rating" DESC;
> ```

---

## Conclusion

This brings us to the conclusion of **Lecture 1** about Relating! 🎉