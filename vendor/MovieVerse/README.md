# 🎬 MovieVerse

> Plataforma web para descubrir contenido audiovisual y conectar con una comunidad cinéfila.

MovieVerse es una aplicación web desarrollada como Trabajo de Fin de Grado del ciclo superior de **Desarrollo de Aplicaciones Multiplataforma (DAM)**. Nace de la necesidad de contar con una plataforma gratuita, independiente de cualquier servicio de streaming, donde explorar tanto películas como series en un mismo lugar.

La plataforma consume la API pública de **The Movie Database (TMDB)** para mostrar información actualizada sobre tendencias, cartelera, series en emisión y próximos estrenos, con datos filtrados por región española.

---

## ✨ Funcionalidades principales

- 🔍 Exploración de películas y series con filtros por género, año, valoración y popularidad
- 📄 Ficha de detalle con sinopsis, reparto, datos técnicos, tráiler y plataformas de streaming disponibles
- ⭐ Sistema de reseñas híbrido: reseñas de usuarios de MovieVerse + reseñas externas de TMDB
- 👁️ Seguimiento de visionado: marcar contenido como visto o pendiente
- ❤️ Sistema de "me gusta" con historial en el perfil de usuario
- 🔐 Autenticación con Spring Security, roles (ADMIN, MODERATOR, STANDARD) y sesiones persistentes
- 🛡️ Panel de moderación con gestión de reportes y auditoría automática mediante trigger SQL
- 🚀 Desplegada en servidor real (Ubuntu 22.04 + NGINX + systemd)

---

## 🛠️ Stack tecnológico

| Capa | Tecnología |
|------|------------|
| Backend | Java 17 + Spring Boot 3.4 |
| Templating | Thymeleaf |
| Frontend | Bootstrap 5.3 + CSS propio + JavaScript |
| Base de datos | MySQL |
| API externa | TMDB |
| Seguridad | Spring Security + BCrypt |
| Servidor | Ubuntu 22.04 + NGINX + systemd (IONOS) |
| Build | Maven |

---

## 🚀 Acceso rápido — App en producción

La aplicación está desplegada y accesible directamente en:

**http://217.154.102.155/**

No requiere instalación. Se puede usar para probar todas las funcionalidades sin configurar nada en local.

---

## 🗄️ Base de datos (solo si se quiere ejecutar en local)

Requisitos previos:
- MySQL instalado y en ejecución.
- Crear la base de datos antes de importar el script:

```sql
CREATE DATABASE movieverse;
```

Importar el script SQL incluido en el proyecto (`movieverse.sql`):

```bash
# Desde terminal:
mysql -u root -p < movieverse.sql
```

O desde **MySQL Workbench**: `File > Run SQL Script > seleccionar movieverse.sql`

El script crea todas las tablas, el trigger de auditoría e inserta los datos de prueba.

---

## ⚙️ Variables de entorno (solo si se quiere ejecutar en local)

Define las siguientes variables antes de arrancar la aplicación:

```
TMDB_API_KEY=tu_api_key_de_tmdb
DB_URL=jdbc:mysql://localhost:3306/movieverse
DB_USER=tu_usuario_mysql
DB_PASSWORD=tu_password_mysql
REMEMBER_ME_KEY=una_clave_secreta_cualquiera
```

Puedes obtener una API key gratuita de TMDB en: https://www.themoviedb.org/settings/api

**En IntelliJ IDEA:**
1. `Run > Edit Configurations`
2. Selecciona la configuración de tu aplicación Spring Boot
3. En el campo **Environment variables**, pega las variables en formato:

```
TMDB_API_KEY=...;DB_URL=...;DB_USER=...;DB_PASSWORD=...;REMEMBER_ME_KEY=...
```

**En terminal (Linux/macOS):**
```bash
export TMDB_API_KEY=tu_api_key_de_tmdb
export DB_URL=jdbc:mysql://localhost:3306/movieverse
export DB_USER=tu_usuario_mysql
export DB_PASSWORD=tu_password_mysql
export REMEMBER_ME_KEY=una_clave_secreta_cualquiera
```

**En terminal (Windows CMD):**
```cmd
set TMDB_API_KEY=tu_api_key_de_tmdb
set DB_URL=jdbc:mysql://localhost:3306/movieverse
set DB_USER=tu_usuario_mysql
set DB_PASSWORD=tu_password_mysql
set REMEMBER_ME_KEY=una_clave_secreta_cualquiera
```

**En terminal (Windows PowerShell):**
```powershell
$env:TMDB_API_KEY="tu_api_key_de_tmdb"
$env:DB_URL="jdbc:mysql://localhost:3306/movieverse"
$env:DB_USER="tu_usuario_mysql"
$env:DB_PASSWORD="tu_password_mysql"
$env:REMEMBER_ME_KEY="una_clave_secreta_cualquiera"
```

---

## ▶️ Arrancar la aplicación

```bash
mvn spring-boot:run
```

O desde IntelliJ: botón **Run** sobre `TfgcineApplication`.

La aplicación estará disponible en: **http://localhost:8080**

---

<p align="center">
  Desarrollado por <strong>Tamara Martínez Vargas</strong> · TFG DAM 2025/2026
</p>
