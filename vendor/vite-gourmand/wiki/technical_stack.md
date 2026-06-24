# Technical Stack

My goal is to create an app that has a modern touch, clean, scalable, and dynamic, and we want to start by modeling data properly before touching the frontend.

## Backend
*Node.js + Typescript + NestJS*
To avoid a spaghetti code, we need structure writing in Java could strongly affect the portability of the code not because it's more generic but because we lack of 
conceptual structure. This project is still pretty little in size and doesn't need all the powerfulness of JAVA. For a beginner Node.js is a suitable choice.
As I have always written in C and C++ (compiled and really typed language). It's more comfortable to me to write in TypeScript direclty as it is less error prone and more good practice. Better models of framework and libraries today are written in TypeScript.

So my idea for the backend is to write an architecture like this:
- `NestJS = MVC + dependency injection + clean architecture out of the box`

### Backend stack

|	layer		|		Technology		|
|---------------|-----------------------|
|Runtime		|Node.js				|
|Language		|Typescript				|
|Framework		|NestJS					|
|ORM			|Prisma					|
|Relational DB	|PostgreSQL				|
|NoSQL DB		|MongoDB				|
|Auth			|JWT + bcrypt			|
|Mail			|Nodemailer				|
|Deployment		|Fly.io/Railway/Render	|

>- **Complex business Rules**: NestJS services
>- **Roles (user /employees/admin)**: Guards + decorators
>- **Strong data modeling**: Prisma + Postgresql
>- **Admin stats in NoSQL**: MongoDB aggregation
>- **Dynamic filters**: REST API or GraphQL(REST is enough)
>- **Security justification**: Typescript + JWT + hashing + VALIDATION

### Aut & Security
- JWT (access + refresh tokens)
- bcrypt for passwords
- Role-based access (User / Employee / Admin)
- RGPD compliant (data ownership, deletion, consent)

## FrontEnd
### Next.js
- Dynamic filters (wihtout page reload)
- SEO friendly
- Accessible (RGAA friendly)
- Easy deployment (vercel)

## Data-model
### MongoDB
Used only for :
- Stats
- Analytics
- Admin graphs (number of orders per menu, revenue per menu)

This matches the requirement perfectly:


## 

