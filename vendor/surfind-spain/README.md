<div align="center">
  <a href="https://surfind-spain-production.up.railway.app/">
    <img src="surfind-spain/public/favicon.svg" alt="Surfind Spain" width="120" height="120">
  </a>

  <h1 align="center">Surfind Spain</h1>

  <p align="center">
    A full-stack web platform to discover surf beaches across Spain.
  </p>

[![Laravel 12](https://img.shields.io/badge/Laravel_12-FF2D20?style=for-the-badge&logo=laravel&logoColor=E3E3E3&labelColor=333333)](https://laravel.com)
[![PHP 8.4+](https://img.shields.io/badge/PHP_8.4+-777BB4?style=for-the-badge&logo=php&logoColor=E3E3E3&labelColor=333333)](https://www.php.net)
[![Livewire 4](https://img.shields.io/badge/Livewire_4-FB70A9?style=for-the-badge&logo=livewire&logoColor=E3E3E3&labelColor=333333)](https://livewire.laravel.com)
[![Flux UI](https://img.shields.io/badge/Flux_UI-18181B?style=for-the-badge&logo=livewire&logoColor=E3E3E3&labelColor=333333)](https://fluxui.dev)
[![Tailwind CSS 4](https://img.shields.io/badge/Tailwind_CSS_4-06B6D4?style=for-the-badge&logo=tailwindcss&logoColor=E3E3E3&labelColor=333333)](https://tailwindcss.com)
[![Vite 7](https://img.shields.io/badge/Vite_7-646CFF?style=for-the-badge&logo=vite&logoColor=E3E3E3&labelColor=333333)](https://vite.dev)
[![Leaflet 1.9](https://img.shields.io/badge/Leaflet_1.9-199900?style=for-the-badge&logo=leaflet&logoColor=E3E3E3&labelColor=333333)](https://leafletjs.com)
[![MySQL 8](https://img.shields.io/badge/MySQL_8-4479A1?style=for-the-badge&logo=mysql&logoColor=E3E3E3&labelColor=333333)](https://www.mysql.com)

  <p align="center">
    <a href="https://surfind-spain-production.up.railway.app/">Live demo</a>
    &middot;
    <a href="#español">Español</a>
    &middot;
    <a href="https://github.com/dsotogc">GitHub</a>
    &middot;
    <a href="https://www.linkedin.com/in/davidsotogarcia/">LinkedIn</a>
  </p>
</div>

## Overview

Surfind Spain is a full-stack Laravel application for discovering surf beaches across Spain. It combines a public browsing experience with an admin backoffice for managing beaches, users and community content.

The project was built as the final project for a Spanish Web Application Development programme, but it is structured as a real product: anonymous visitors can explore published content, verified registered users can interact with beaches, and administrators have a separate backoffice with role-based access control.

## Live Demo

The project is deployed on Railway:

[https://surfind-spain-production.up.railway.app/](https://surfind-spain-production.up.railway.app/)

## Features

- Public home page with an editorial surf-focused design.
- Published beach listing with pagination.
- Search by beach name and editorial descriptions.
- Filters by province, difficulty and available amenities.
- Sorting by recent beaches, comments, favorites or name.
- Beach detail pages with description, difficulty, amenities, comments and favorites.
- Interactive Leaflet map with all published beaches.
- Focused map links using `/mapa?playa={slug}` to center a specific beach.
- Community page showing the most active/loved beaches based on favorites and comments.
- Verified authenticated users can save or remove favorite beaches.
- Verified authenticated users can publish comments on beach detail pages.

## Admin Backoffice

The admin area is intentionally separated from the public site and protected with roles and permissions.

- Internal dashboard with user, beach and comment metrics.
- Annual chart for user registrations and published comments.
- Beach management with search, province, status and difficulty filters.
- Beach creation and editing with editorial fields, coordinates and amenities.
- Automatic slug generation from the beach name.
- Publication status workflow: draft, published and archived.
- Archiving beaches instead of physically deleting them from normal admin flows.
- Cover image management through either local uploads or external image URLs.
- User management with search and active/disabled filters.
- User creation and editing with a single primary role.
- Account disabling/restoring through soft deletes.
- Comment hiding from the admin area.

## Technical Highlights

- Laravel 12 application with Fortify authentication.
- Livewire and Flux UI for authenticated screens and UI components.
- Spatie Laravel Permission for role and permission based authorization.
- Separate public and authenticated/admin layouts.
- Public beach content is scoped to `published` records.
- Beach deletion in the backoffice is modeled as archiving, preserving historical data.
- Disabled users are represented with Laravel `SoftDeletes` instead of an extra status flag.
- Beach cover images use a centralized `beach_images` table with support for uploads and external URLs.
- Favorites use a composite primary key to prevent duplicate user/beach pairs.
- Amenities are attached through a pivot table with a unique beach/amenity constraint.
- Leaflet is loaded through Vite for the interactive public map.
- Seeders provide realistic demo beaches across several Spanish surf regions.

## Tech Stack

| Area | Technologies |
| --- | --- |
| Backend | Laravel 12, PHP, Eloquent ORM |
| Authentication | Laravel Fortify |
| Authorization | Spatie Laravel Permission |
| UI | Blade, Livewire 4, Flux UI |
| Styling | Tailwind CSS 4, local Satoshi font assets |
| Frontend tooling | Vite 7, Laravel Vite Plugin |
| Maps | Leaflet 1.9 |
| Charts | Chart.js |
| Database | MySQL |
| Quality | Pest, Laravel Pint, GitHub Actions |

## Local Setup

The Laravel application lives inside the `surfind-spain/` directory, so project commands should be run from there.

Requirements used by the project and CI:

- PHP 8.4+
- Composer 2
- Node.js 22+
- MySQL

```bash
cd surfind-spain
composer install
cp .env.example .env
php artisan key:generate
```

Configure your MySQL connection in `.env`, then run:

```bash
php artisan migrate:fresh --seed
npm install
npm run build
php artisan storage:link
composer dev
```

## Project Structure

```text
.
├── README.md
└── surfind-spain/
    ├── app/
    ├── database/
    ├── public/
    ├── resources/
    ├── routes/
    ├── tests/
    ├── composer.json
    └── package.json
```

## Project Context

Surfind Spain was developed as the final project for the Higher Vocational Training Programme in Web Application Development (CFGS Desarrollo de Aplicaciones Web).

The goal was to build a realistic full-stack web application with a public browsing experience, authenticated user interactions and an admin backoffice. The current version focuses on delivering a functional and coherent MVP within the available project scope.

The testing setup is configured with Pest and GitHub Actions, but the automated test suite is still minimal. The project should not be described as having extensive test coverage yet.

## Future Improvements

- Public beach image galleries: allow users to upload photos linked to specific beaches, adding visual and community value to each beach profile. This idea was initially explored during development but left out to keep the MVP focused and achievable.
- User profile pictures: let users personalize their accounts with an avatar or profile image, improving identity across comments and future social features.
- Extended admin metrics: expand the current internal dashboard with usage analytics such as visits, most viewed pages, user activity, interactions and activity trends over time.
- Blog or editorial posts: create a publishing area where experienced users could share surf-related recommendations, opinions, tips or personal experiences.
- Lightweight discussion space: add a simple discussion layer around posts or surf topics, without building a complex forum, to strengthen the community side of the platform.
- Advertising space for local surf businesses: allow surf schools, shops or related local businesses to appear in beach profiles if the platform gains enough traffic, adding useful contextual information and a possible monetization path.
- Broader automated tests: add feature tests around public browsing, authentication, comments, favorites and admin workflows.

## Author

Built by **David Soto García**.

- GitHub: [github.com/dsotogc](https://github.com/dsotogc)
- LinkedIn: [linkedin.com/in/davidsotogarcia](https://www.linkedin.com/in/davidsotogarcia/)

---

## Español

Surfind Spain es una aplicación full-stack desarrollada con Laravel para descubrir playas de surf en España. Combina una experiencia pública de navegación con un backoffice de administración para gestionar playas, usuarios y contenido de comunidad.

El proyecto nació como Proyecto de Fin de Ciclo del CFGS Desarrollo de Aplicaciones Web, pero está planteado como una aplicación real: los usuarios anónimos pueden explorar contenido público, los usuarios registrados y verificados pueden interactuar con las playas y los administradores cuentan con una zona privada separada mediante roles y permisos.

### Demo

La aplicación está desplegada en Railway:

[https://surfind-spain-production.up.railway.app/](https://surfind-spain-production.up.railway.app/)

### Funcionalidades

- Página de inicio pública con diseño editorial orientado al surf.
- Listado de playas publicadas con paginación.
- Búsqueda por nombre y descripciones.
- Filtros por provincia, dificultad y servicios disponibles.
- Ordenación por playas recientes, comentarios, favoritos o nombre.
- Fichas de playa con descripción, dificultad, servicios, comentarios y favoritos.
- Mapa interactivo con Leaflet y marcadores de playas publicadas.
- Enlaces al mapa con foco en una playa concreta mediante `/mapa?playa={slug}`.
- Página de comunidad con las playas más destacadas por favoritos y comentarios.
- Usuarios autenticados y verificados pueden guardar o quitar playas favoritas.
- Usuarios autenticados y verificados pueden publicar comentarios en las fichas de playa.

### Backoffice

- Dashboard interno con métricas de usuarios, playas y comentarios.
- Gráfico anual de altas de usuarios y comentarios publicados.
- Gestión de playas con filtros por búsqueda, provincia, estado y dificultad.
- Creación y edición de playas con campos editoriales, coordenadas y servicios.
- Generación automática de slugs desde el nombre de la playa.
- Estados de publicación: borrador, publicada y archivada.
- Archivado de playas en lugar de borrado físico desde el flujo normal de administración.
- Gestión de imagen de portada mediante subida local o URL externa.
- Gestión de usuarios con filtros por estado activo o deshabilitado.
- Creación y edición de usuarios con un único rol principal.
- Deshabilitar y restaurar cuentas mediante `SoftDeletes`.
- Ocultación de comentarios desde el panel de administración.

### Decisiones Técnicas

- Aplicación Laravel 12 con autenticación mediante Fortify.
- Autorización basada en roles y permisos con Spatie Laravel Permission.
- Separación visual y estructural entre sitio público y zona autenticada/admin.
- El contenido público de playas se limita a registros publicados.
- El borrado de playas en backoffice se modela como archivado para preservar datos.
- Las cuentas deshabilitadas usan `SoftDeletes`, evitando flags redundantes.
- Las imágenes de playa se centralizan en `beach_images`, con soporte para subidas locales y URLs externas.
- Los favoritos usan clave primaria compuesta para evitar duplicados.
- Leaflet se integra a través de Vite para el mapa público.
- Los seeders incluyen playas demo realistas de varias zonas surferas de España.

### Stack

| Área | Tecnologías |
| --- | --- |
| Backend | Laravel 12, PHP, Eloquent ORM |
| Autenticación | Laravel Fortify |
| Autorización | Spatie Laravel Permission |
| UI | Blade, Livewire 4, Flux UI |
| Estilos | Tailwind CSS 4, tipografía local Satoshi |
| Frontend tooling | Vite 7, Laravel Vite Plugin |
| Mapas | Leaflet 1.9 |
| Gráficos | Chart.js |
| Base de datos | MySQL |
| Calidad | Pest, Laravel Pint, GitHub Actions |

### Instalación Local

La aplicación Laravel está dentro del directorio `surfind-spain/`, así que los comandos del proyecto deben ejecutarse desde ahí.

Requisitos usados por el proyecto y por CI:

- PHP 8.4+
- Composer 2
- Node.js 22+
- MySQL

```bash
cd surfind-spain
composer install
cp .env.example .env
php artisan key:generate
```

Configura la conexión MySQL en `.env` y después ejecuta:

```bash
php artisan migrate:fresh --seed
npm install
npm run build
php artisan storage:link
composer dev
```

### Contexto Del Proyecto

Surfind Spain ha sido desarrollado como Proyecto de Fin de Ciclo del CFGS Desarrollo de Aplicaciones Web.

El objetivo del proyecto ha sido construir una aplicación web full-stack realista, con una parte pública de navegación, interacciones para usuarios autenticados y un backoffice de administración. La versión actual se centra en entregar un MVP funcional, coherente y acotado al alcance disponible.

La configuración de tests existe con Pest y GitHub Actions, pero la suite automatizada todavía es mínima. No debe considerarse un proyecto con cobertura de tests extensa en su estado actual.

### Mejoras Futuras

- Galería pública de imágenes por playa: permitir que los usuarios suban fotografías asociadas a las playas registradas, aportando valor visual y comunitario a cada ficha. Esta línea llegó a plantearse durante el desarrollo, pero se descartó para acotar el alcance y priorizar un MVP funcional y estable.
- Foto de perfil para usuarios: permitir que cada usuario personalice su cuenta con una imagen de perfil, reforzando su identidad visual en comentarios y futuras interacciones sociales.
- Panel ampliado de métricas para administradores: evolucionar el dashboard actual con datos de uso como visitas, páginas más consultadas, usuarios registrados, interacciones y evolución de la actividad.
- Blog o publicaciones temáticas: crear un espacio donde usuarios con experiencia puedan compartir recomendaciones, opiniones, consejos o experiencias relacionadas con el surf.
- Sistema sencillo de debate: incorporar una capa básica de discusión entre usuarios sobre publicaciones, playas, material, aprendizaje o condiciones, sin llegar a construir un foro complejo.
- Espacio publicitario para escuelas y negocios locales: habilitar zonas dentro de las fichas de playa para escuelas de surf, tiendas u otros negocios vinculados, aportando información contextual al usuario y una posible vía de monetización futura.
- Ampliación de tests automatizados: añadir pruebas de feature sobre navegación pública, autenticación, comentarios, favoritos y flujos de administración.

### Autor

Desarrollado por **David Soto García**.

- GitHub: [github.com/dsotogc](https://github.com/dsotogc)
- LinkedIn: [linkedin.com/in/davidsotogarcia](https://www.linkedin.com/in/davidsotogarcia/)
