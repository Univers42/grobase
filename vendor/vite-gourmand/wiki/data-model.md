# Core
To understand how to manage the data and structure the application I need to understand why the subject ask me to use both non-relational and relational database.

## Purpose of Relational Database
- Stores structured data in tables with relationships (e.g., customers, orders, menu items)
- Ensure data integrity with constraints (foreing keys unique, etc.)
- Good for complex queries and transactions

## Purpose of Non-relational Database:
- Stores unstructured or semi-structured data (e.g, user reviews, logs, menu images, flexible menu formats).
- Scales easily for large or variable data.
- Good for fast reads/writes and flexible schemas

## Polygotte Persistence
- use the best tool for eacht type of data
- Scale and optimize performance
- Handle both structured and unstructured data efficiently

### Draft:
- I'll be using the PostgreSql or MySQl for orders and reservations
- Use MongoDB or Firebase for menu images, customer reviews, or chat messages
