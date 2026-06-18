# ORM
Databases like PostgreSql or MySQL are relational: they store data in tables with rows and columns. Our code in NestJS/TypeScript, however, works with obejcts

**without ORM**
```js
const result = await db.query("SELECT * FROM users WHERE id = $1", [id]);
```

*we get raw rows, teh we manually map them to objects if needed*

**With ORM**
```js
const user = await prisma.user.findUnique({ where: { id }});
console.log(user.name);
```
*we can directly work with objects like `user.name` without thinking about SQL*
So basically ORM = translator between objects in our code and tables in our database

## Why needs of ORM
1. Type safety / code completion - our editor knows the exact shape of our data (flow is quicker)
2. Less boilerplate - we don't have to write raw SQL for every CRUD operation
3. Migration management - many ORMs, like Prisma, handle schema changes automatically.
4. Consistency - we interact with our database teh same way, no matter which DB we're using

## A little bit of history
Prisma is a modern Typescript ORM:
- Generates a typed client `PrismaClient` so our DB tables becomes objects
- handles migrations (creaeting/updating tables)
- Lets us run queries using Javascript/Typescript syntax, no raw SQL needed most of the time

## Other types of ORM

- sequelize (old,js)
- typeORM (very popular, js)
- Prisma 	(modern workflow, js)
- doctrine (most popular, php)

```php
$user = $entityManager->find(User::class, 1);
echo $user->getName();
```

This snippet above, will automatically run the SQL behind the scenes
```sql
SELECT * FROM users WHERE id = 1;
```

Prisma can do everything PDO does, and even more, but in a Typescript-friendly way. Let me break it down:

| Feature                                         	| PDO	     | Prisma                     		     |
|---------------------------------------------------|------------|---------------------------------------|
| Connects to a database                          	|✅          |	✅                        		  |
| Lets you write SQL queries                      	|✅          |	⚠️ (optional via raw SQL) 		   |
| Executes queries safely with prepared statements	|✅          |	✅                        		  |
| Returns raw results                             	|✅          |	⚠️ (returns objects, raw optional) |
| Handles type-safe queries                         |❌          |	✅       						  |
| Supports raw SQL                                  |✅          |	✅       						  |
| Handles migrations                                |❌          |	✅       						  |
| Auto-generates a client for code use            	|❌          |	✅       						  |
