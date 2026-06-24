
# Lecture 0: Introduction to Databases

## Table of Contents

- [Introduction](#introduction)
- [What is a Database?](#what-is-a-database)
- [SQL](#sql)
- [Getting Started with SQLite](#getting-started-with-sqlite)
- [Terminal Tips](#terminal-tips)
- [SELECT](#select)
- [LIMIT](#limit)
- [WHERE](#where)
- [NULL](#null)
- [LIKE](#like)
- [Ranges](#ranges)
- [ORDER BY](#order-by)
- [Aggregate Functions](#aggregate-functions)

---

## Introduction

Databases (and SQL) are tools that can be used to interact with, store, and manage information. Although the tools we're using in this course are new, a database is an age-old idea.

Look at this diagram from a few thousand years ago. It has rows and columns, and seems to contain stipends for workers at a temple. One could call this diagram a table, or even a spreadsheet.

> **Table with Temple Workers' Stipends**

Based on what we see in the diagram above, we can conclude that:

- A table stores some set of information (here, worker stipends).
- Every row in a table stores one item in that set (here, one worker).
- Every column has some attribute of that item (here, the stipend for a particular month).

Let us now consider a modern context. Say you are a librarian tasked with organizing information about the book titles and authors in this diagram.

> **"Book Titles and Authors - Unorganized"**

One way of organizing the information would be to have each book title followed by its author, as below.

> **"Table with Book Titles followed by Author"**

Notice that:

- Each book is now a row in this table.
- Every row has two columns — each a different attribute of the book (book title and author).

In today's information age, we can store our tables using software like Google Sheets instead of paper 📝 or stone tablets 🪨. However, in this course we will talk about databases and not spreadsheets.

### Three Reasons to Move Beyond Spreadsheets to Databases

1. **Scale** — Databases can store not just items numbering to tens of thousands but even millions and billions.
2. **Update Capacity** — Databases are able to handle multiple updates of data in a second.
3. **Speed** — Databases allow faster look-up of information. This is because databases provide us with access to different algorithms to retrieve information. In contrast, spreadsheets merely allow the use of `Ctrl+F` or `Cmd+F` to go through hits one at a time.

---

## What is a Database?

A database is a way of organizing data such that you can perform four operations on it:

- **Create**
- **Read**
- **Update**
- **Delete**

A **database management system (DBMS)** is a way to interact with a database using a graphical interface or textual language.

### Examples of DBMS

MySQL, Oracle, PostgreSQL, SQLite, Microsoft Access, MongoDB, etc.

### Factors for Choosing a DBMS

| Factor | Description |
|--------|-------------|
| **Cost** | Proprietary vs. free software |
| **Support** | Free and open source software like MySQL, PostgreSQL and SQLite come with the downside of having to set up the database yourself |
| **Weight** | More fully-featured systems like MySQL or PostgreSQL are heavier and require more computation to run than systems like SQLite |

In this course, we will start with SQLite and then move on to MySQL and PostgreSQL.

---

## SQL

**SQL** stands for **Structured Query Language**. It is a language used to interact with databases, via which you can create, read, update, and delete data in a database.

### Important Notes About SQL

- It is **structured**, as we'll see in this course.
- It has some **keywords** that can be used to interact with the database.
- It is a **query language** — it can be used to ask questions of data inside a database.

In this lesson, we will learn how to write some simple SQL queries.

### Questions

> **Are there subsets of SQL?**
>
> SQL is a standard both of the American National Standards Institute (ANSI) and the International Organization for Standardization (ISO). Most DBMS support some subset of the SQL language. So for SQLite, for example, we're using a subset of SQL that is supported by SQLite. If we wanted to port our code to a different system like MySQL, it is likely we would have to change some of the syntax.

---

## Getting Started with SQLite

It is worth noting that SQLite is not merely something we use for this class, but a database used in plenty of other applications including phones, desktop applications and websites.

Now, consider a database of books that have been longlisted for the International Booker Prize. Each year, there are 13 books on the longlist and our database contains 5 years' worth of such longlists.

### Before You Begin

1. Log in to Visual Studio Code for CS50. This is where we will write code and edit files.
2. The SQLite environment is already set up in your Codespace! Open it up on the terminal.

---

## Terminal Tips

Here are some useful tips for writing SQL code on the terminal:

| Action | Shortcut |
|--------|----------|
| Clear the terminal screen | `Ctrl + L` |
| Get previously executed instruction(s) | **Up Arrow** key |
| Continue a long query on the next line | Hit **Enter** |
| Exit a database or the SQLite environment | `.quit` |

---

## SELECT

What data is actually in our database? To answer this, we will use our first SQL keyword, **`SELECT`**, which allows us to select some (or all) rows from a table inside the database.

In the SQLite environment, run:

```sql
SELECT * 
FROM "longlist";
```

This selects all the rows from the table called `longlist`.

The output we get contains all the columns of all the rows in this table, which is a lot of data. We can simplify it by selecting a particular column, say the title, from the table:

```sql
SELECT "title" 
FROM "longlist";
```

Now, we see a list of the titles in this table. But what if we want to see titles and authors in our search results?

```sql
SELECT "title", "author" 
FROM longlist;
```

### Questions

> **Is it necessary to use the double quotes (`"`) around table and column names?**
>
> It is good practice to use double quotes around table and column names, which are called SQL identifiers. SQL also has strings and we use single quotes around strings to differentiate them from identifiers.

> **Where is the data in this database coming from?**
>
> This database contains data from various sources:
> - Longlists of books (years 2018–2023) come from the Booker Prize website.
> - Ratings and other information about these books come from Goodreads.

> **How do we know what tables and columns are in a database?**
>
> The database schema contains the structure of the database, including table and column names. Later in this course, we will learn how to get the database schema and understand it.

> **Is SQLite 3 case-sensitive? Why are some parts of the query in capital letters and some in small letters?**
>
> SQLite is case-insensitive. However, we do follow some style conventions:
>
> ```sql
> SELECT *
> FROM "longlist";
> ```
>
> SQL keywords are written in capital letters. This is especially useful in improving the readability of longer queries. Table and column names are in lowercase.

---

## LIMIT

If a database had millions of rows, it might not make sense to select all of its rows. Instead, we might want to merely take a peek at the data it contains. We use the SQL keyword **`LIMIT`** to specify the number of rows in the query output.

```sql
SELECT "title" 
FROM "longlist" 
LIMIT 10;
```

This query gives us the first 10 titles in the database. The titles are ordered the same way in the output of this query as they are in the database.

---

## WHERE

The keyword **`WHERE`** is used to select rows based on a condition; it will output the rows for which the specified condition is true.

```sql
SELECT "title", "author" 
FROM "longlist" 
WHERE "year" = 2023;
```

This gives us the titles and authors for the books longlisted in 2023. Note that `2023` is not in quotes because it is an integer, not a string or identifier.

### Comparison Operators

| Operator | Meaning |
|----------|---------|
| `=` | Equal to |
| `!=` | Not equal to |
| `<>` | Not equal to (alternative) |

To select the books that are not hardcovers:

```sql
SELECT "title", "format" 
FROM "longlist" 
WHERE "format" != 'hardcover';
```

> Note that `hardcover` is in **single quotes** because it is an SQL string and not an identifier.

Using `<>`:

```sql
SELECT "title", "format" 
FROM "longlist" 
WHERE "format" <> 'hardcover';
```

Using the `NOT` keyword:

```sql
SELECT "title", "format" 
FROM "longlist" 
WHERE NOT "format" = 'hardcover';
```

### Combining Conditions

To combine conditions, we can use **`AND`** and **`OR`**. We can also use parentheses to indicate how to combine conditions.

Books longlisted in 2022 or 2023:

```sql
SELECT "title", "author" 
FROM "longlist" 
WHERE "year" = 2022 OR "year" = 2023;
```

Books longlisted in 2022 or 2023 that were not hardcovers:

```sql
SELECT "title", "format" 
FROM "longlist" 
WHERE ("year" = 2022 OR "year" = 2023) AND "format" != 'hardcover';
```

Here, the parentheses indicate that the OR clause should be evaluated before the AND clause.

---

## NULL

It is possible that tables may have missing data. **`NULL`** is a type used to indicate that certain data does not have a value, or does not exist in the table.

For example, the books in our database have a translator along with an author. However, only some of the books have been translated to English. For other books, the translator value will be `NULL`.

### NULL Conditions

| Condition | Meaning |
|-----------|---------|
| `IS NULL` | Value does not exist |
| `IS NOT NULL` | Value exists |

Books for which translators don't exist:

```sql
SELECT "title", "translator" 
FROM "longlist"
WHERE "translator" IS NULL;
```

Books for which translators do exist:

```sql
SELECT "title", "translator" 
FROM "longlist"
WHERE "translator" IS NOT NULL;
```

---

## LIKE

This keyword is used to select data that roughly matches the specified string. **`LIKE`** is combined with the operators:

| Operator | Meaning |
|----------|---------|
| `%` | Matches any characters (zero or more) |
| `_` | Matches a single character |

Books with the word "love" in their titles:

```sql
SELECT "title"
FROM "longlist"
WHERE "title" LIKE '%love%';
```

Books whose title begins with "The":

```sql
SELECT "title" 
FROM "longlist" 
WHERE "title" LIKE 'The%';
```

> ⚠️ This may also return books starting with "Their" or "They". To select only the word "The", add a space:

```sql
SELECT "title" 
FROM "longlist" 
WHERE "title" LIKE 'The %';
```

Finding a book named either "Pyre" or "Pire":

```sql
SELECT "title" 
FROM "longlist" 
WHERE "title" LIKE 'P_re';
```

### Questions

> **Can we use multiple `%` or `_` symbols in a query?**
>
> Yes!
>
> Example 1 — titles beginning with "The" and containing "love":
>
> ```sql
> SELECT "title" 
> FROM "longlist" 
> WHERE "title" LIKE 'The%love%';
> ```
>
> Example 2 — a four-letter title starting with "T":
>
> ```sql
> SELECT "title" 
> FROM "longlist" 
> WHERE "title" LIKE 'T____';
> ```

> **Is the comparison of strings case-sensitive in SQL?**
>
> In SQLite, comparison of strings with `LIKE` is by default **case-insensitive**, whereas comparison of strings with `=` is **case-sensitive**. (Note that, in other DBMS's, the configuration of your database can change this!)

---

## Ranges

We can also use the operators `<`, `>`, `<=` and `>=` to match a range of values.

Books longlisted between 2019 and 2022 (inclusive):

```sql
SELECT "title", "author" 
FROM "longlist" 
WHERE "year" >= 2019 AND "year" <= 2022;
```

Using **`BETWEEN`** and **`AND`**:

```sql
SELECT "title", "author" 
FROM "longlist" 
WHERE "year" BETWEEN 2019 AND 2022;
```

Books with a rating of 4.0 or higher:

```sql
SELECT "title", "rating" 
FROM "longlist" 
WHERE "rating" > 4.0;
```

Books with rating above 4.0 and at least 10,000 votes:

```sql
SELECT "title", "rating", "votes" 
FROM "longlist" 
WHERE "rating" > 4.0 AND "votes" > 10000;
```

Books with fewer than 300 pages:

```sql
SELECT "title", "pages" 
FROM "longlist" 
WHERE "pages" < 300;
```

### Questions

> **For range operators like `<` and `>`, do the values have to be integers?**
>
> No, the values can be integers or floating-point (i.e., "decimal" or "real") numbers. While creating a database, there are ways to set these data types for columns.

---

## ORDER BY

The **`ORDER BY`** keyword allows us to organize the returned rows in some specified order.

Bottom 10 books by rating (ascending by default):

```sql
SELECT "title", "rating" 
FROM "longlist" 
ORDER BY "rating" LIMIT 10;
```

Top 10 books by rating:

```sql
SELECT "title", "rating" 
FROM "longlist" 
ORDER BY "rating" DESC LIMIT 10;
```

> **`DESC`** = descending order · **`ASC`** = ascending order

Top 10 books by rating with votes as a tie-break:

```sql
SELECT "title", "rating", "votes" 
FROM "longlist"
ORDER BY "rating" DESC, "votes" DESC 
LIMIT 10;
```

### Questions

> **To sort books by title alphabetically, can we use ORDER BY?**
>
> Yes:
>
> ```sql
> SELECT "title" 
> FROM "longlist" 
> ORDER BY "title";
> ```

---

## Aggregate Functions

**`COUNT`**, **`AVG`**, **`MIN`**, **`MAX`**, and **`SUM`** are called aggregate functions and allow us to perform the corresponding operations over multiple rows of data. Each returns only a single output — the aggregated value.

Average rating of all books:

```sql
SELECT AVG("rating") 
FROM "longlist";
```

Rounded to 2 decimal points:

```sql
SELECT ROUND(AVG("rating"), 2) 
FROM "longlist";
```

Renaming the output column with **`AS`**:

```sql
SELECT ROUND(AVG("rating"), 2) AS "average rating" 
FROM "longlist";
```

Maximum rating:

```sql
SELECT MAX("rating") 
FROM "longlist";
```

Minimum rating:

```sql
SELECT MIN("rating") 
FROM "longlist";
```

Total number of votes:

```sql
SELECT SUM("votes") 
FROM "longlist";
```

Count of all books:

```sql
SELECT COUNT(*) 
FROM "longlist";
```

> We use `*` because we are counting every row in the database.

Count of translators (excludes `NULL` values):

```sql
SELECT COUNT("translator") 
FROM "longlist";
```

Count of **distinct** publishers:

```sql
SELECT COUNT(DISTINCT "publisher") 
FROM "longlist";
```

### Questions

> **Would using MAX with the title column give you the longest book title?**
>
> No, using `MAX` with the title column would give you the "largest" (i.e., last) title **alphabetically**. Similarly, `MIN` will give the first title alphabetically.

---

## Conclusion

This brings us to the conclusion of **Lecture 0** about Querying in SQL! To exit the SQLite prompt, you can type in the SQLite keyword `.quit` and this should take you back to the regular terminal.

Until next time! 👋
