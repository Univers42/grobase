# 🥩 HamBooking - Sistema de Gestión de Reservas

[![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)](https://github.com/DjSurgeon/java-dam/releases/tag/v1.0.0)
[![Java](https://img.shields.io/badge/Java-21-orange.svg)](https://www.oracle.com/java/)
[![Spring Boot](https://img.shields.io/badge/Spring%20Boot-3.x-brightgreen.svg)](https://spring.io/projects/spring-boot)
[![Tests](https://img.shields.io/badge/Tests-496%20passed-success.svg)](#-calidad-y-pruebas)
[![JavaFX](https://img.shields.io/badge/JavaFX-21-blue.svg)](https://openjfx.io/)
[![MySQL](https://img.shields.io/badge/MySQL-8.0-blue.svg)](https://www.mysql.com/)

**HamBooking** es una solución integral para la digitalización y gestión de servicios profesionales de corte de jamón. Este proyecto ha sido desarrollado como **Trabajo de Fin de Grado (TFG)** para el Ciclo Formativo de Grado Superior en **Desarrollo de Aplicaciones Multiplataforma (DAM)**.

---

## 📋 Resumen del Proyecto

La aplicación permite a negocios especializados gestionar su agenda de cortadores profesionales mediante una arquitectura **Cliente-Servidor REST**. El sistema automatiza el control de disponibilidad, los límites de carga de trabajo y las comunicaciones con los clientes, eliminando procesos manuales y errores de solapamiento.

### Actores del Sistema
*   **Administrador:** Gestión total de cortadores, usuarios, servicios y supervisión de reservas.
*   **Cliente:** Registro autónomo, consulta de disponibilidad en tiempo real y autogestión de citas.
*   **Cortador (Recurso):** Profesionales asignados a los servicios con control de capacidad diaria.

---

## 🛠️ Stack Tecnológico

### Backend (Servidor)
*   **Lenguaje:** Java 21 (LTS)
*   **Framework:** Spring Boot 3.x
*   **Persistencia:** Spring Data JPA / Hibernate
*   **Base de Datos:** MySQL 8.0
*   **Seguridad:** Spring Security + BCrypt
*   **Validación:** Jakarta Bean Validation (JSR-380)

### Frontend (Cliente de Escritorio)
*   **Framework:** JavaFX 21
*   **Diseño:** FXML + CSS (Scene Builder)
*   **Comunicación:** HttpClient (JSON/REST)

### Calidad y Herramientas
*   **Gestión de Dependencias:** Maven
*   **Testing:** JUnit 5 + Mockito (Unitarios)
*   **Documentación:** Javadoc profesional + Mermaid para diagramas
*   **Control de Versiones:** Git (GitHub) utilizando Conventional Commits

---

## 🏗️ Arquitectura y Diseño

El proyecto sigue principios de **Clean Architecture** y **Defensa en Profundidad**:

1.  **Modelo de Datos Normalizado:** Diseño en 3FN con 5 entidades interconectadas.
2.  **Doble Escudo de Validación:** Las reglas de negocio se validan tanto en la capa de aplicación (Java) como en la capa de persistencia (MySQL Constraints).
3.  **Carga Perezosa (Lazy Loading):** Optimización de memoria mediante `FetchType.LAZY` en todas las relaciones para evitar el problema de las N+1 consultas.
4.  **Patrón DTO:** Desacoplamiento total entre las entidades de base de datos y la información expuesta a la API REST.

---

## ✅ Calidad y Pruebas

El sistema cuenta con una batería de **496 pruebas unitarias** que garantizan la estabilidad del backend:

*   **Entidades y Enums:** Verificación de constraints, valores por defecto y consistencia.
*   **Repositorios:** Pruebas de consultas personalizadas y métodos derivados con Mockito.
*   **Servicios (Business Logic):** Cobertura del 100% de la lógica de negocio (solapamientos, límites diarios, algoritmos de disponibilidad y autenticación).

---

## 🚀 Instalación y Ejecución

### Requisitos Previos
*   Java JDK 21 o superior.
*   MySQL Server 8.0.
*   Maven 3.9+.

### Configuración
1.  **Base de Datos:** Ejecuta el script `database/schema.sql` en tu servidor MySQL.
2.  **Backend:**
    *   Navega a `backend/backend/`
    *   Configura las credenciales de BD en `src/main/resources/application.properties`.
    *   Ejecuta: `./mvnw spring-boot:run`
3.  **Frontend:**
    *   Navega a `frontend/frontend/`
    *   Ejecuta: `./mvnw javafx:run`

---

## 📊 Integración Curricular (DAM)

Este proyecto integra competencias de los 16 módulos del ciclo, destacando:
*   **Programación & Acceso a Datos:** Desarrollo del core Java y persistencia ORM.
*   **Desarrollo de Interfaces:** Creación de la UI rica en JavaFX.
*   **Servicios y Procesos:** Implementación de la API REST y concurrencia.
*   **Sistemas de Gestión Empresarial:** Lógica de negocio tipo ERP para reservas.

---

## 📄 Documentación Técnica

Toda la documentación de diseño se encuentra en la carpeta `/docs`:
*   [Modelo Entidad-Relación](docs/diagramas/er-diagram.md)
*   [Casos de Uso](docs/diagramas/casos-de-uso.md)
*   [Guía para la Defensa](docs/defensa/02.defensa.md)

---

## ✒️ Autor
*   **Sergio (DjSurgeon)** - *Desarrollo y Diseño* - [GitHub](https://github.com/DjSurgeon)
