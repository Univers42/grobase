## Architecture

MVC is widely used because it separates concerns, making the code easier to maintain and scale.
Frameworks like Laravel, Symfony, and CodeIgniter use this pattern. If we're not using a framework, we can still use this structure.

> **Note:** If you encounter a "Sorry" error from MariaDB, it usually means the server is overloaded or a query is not supported. Check your query and server status for more details.

## Custom Library Layout

To simplify development and avoid common issues, consider the following structure:

- `/lib/css/`  
  Place your custom CSS files here. Example: `main.css`, `forms.css`, etc.

- `/lib/php/`  
  Place your reusable PHP libraries here. Example: `db.php`, `auth.php`, `utils.php`.

- `/public/`  
  Publicly accessible files (entry points, assets). Example: `index.php`, `assets/`.

- `/views/`  
  HTML templates or view files.

- `/controllers/`
  PHP files handling requests and logic.

- `/models/`
  PHP files representing data structures and database interactions.

**Benefits:**  
- Easier maintenance and scaling.
- Clear separation between core logic, views, and reusable libraries.
- Avoids duplication and reduces errors.

> **Tip:** Use autoloading for PHP libraries and minify your CSS for production.

## Suggested Directory Structure

To organize your project, follow the structure described in your README. Here’s a visual outline:


# Requirement planning
- list features:
- profiles
- photo
- feeds
- likes
- comments
- authentification

## Tech Stack
- javascript
- css
- index.html
- php
- database (SQL/MARIADB)

## Backend setup
- init backend framework
- Design databse models: User, Posts, Comments, like..
- Implement authentification (sign up, login)
- Create REST API endpoints for posts, likes, comments

## 4. frontend setup
- initialize frontend framework.
- Build UI components: feed, profile, post, comment.
- Comment frontend to backend APIs.

## 5. Testing & Deployment
- Test features
- Deploy to hosting services

# WEBSERVER

apache

## What is a Webserver?

A webserver is software that serves web content (HTML, CSS, JS, images, etc.) to users over the internet. It listens for requests (usually HTTP/HTTPS) from browsers and responds with the requested files or data. It can also run backend code (like PHP) to generate dynamic content.

**Purpose of a Webserver:**
- Hosts your website or web application.
- Handles incoming requests and sends responses.
- Executes server-side scripts (e.g., PHP).
- Manages security, logging, and access control.

## Using Apache as a Webserver

Apache is a popular open-source webserver. To use it:

1. **Install Apache:**  
   - On Ubuntu/Debian: `sudo apt install apache2`
   - On CentOS/Fedora: `sudo yum install httpd`

2. **Configure Apache:**  
   - Place your project files in `/var/www/html/` or set up a custom directory.
   - Edit configuration files (e.g., `/etc/apache2/sites-available/000-default.conf`) to point to your project folder.

3. **Start Apache:**  
   - `sudo systemctl start apache2` (Ubuntu/Debian)
   - `sudo systemctl start httpd` (CentOS/Fedora)

4. **Access your site:**  
   - Open a browser and go to `http://localhost/` or your server’s IP.

5. **Enable PHP:**  
   - Install PHP: `sudo apt install php libapache2-mod-php`
   - Restart Apache: `sudo systemctl restart apache2`

> **Tip:** For development, you can use `localhost`. For production, configure domains and security settings.

# RESSOURCES

https://getcomposer.org/doc/00-intro.md
https://mariadb.com/get-started-with-mariadb/
