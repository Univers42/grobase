### 1. 🚦 Estado del Proyecto (Review)

**Lo que hemos logrado (Sprint 0 - Setup):**

* ✅ **Entorno Local:** Fedora + IntelliJ Ultimate + Java 21 + Maven configurados.
* ✅ **Arquitectura Base:** Proyecto modular (`backend` Spring Boot + `frontend` JavaFX) creado y funcionando.
* ✅ **Control de Versiones:** Repositorio GitHub con ramas `main`/`develop` y normas de contribución claras.
* ✅ **Dependencias:** Jackson (JSON), JPA, MySQL Driver y ControlsFX inyectados.

**Conclusión del Scrum Master:**
El "Andamiaje" es sólido. No hay deuda técnica inicial. Estamos en verde. 🟢

---

### 2. 🔍 Análisis de Riesgos y "Cosas Olvidadas" (Gap Analysis)

He revisado tu Backlog y la arquitectura propuesta. Aquí tienes mis observaciones de lo que **nos falta** o lo que podría salir mal si no lo vigilamos:

#### A. ⚠️ Falta Definición de DTOs (Data Transfer Objects)

En las issues #6 a #9 hablamos de crear "Entidades" (`@Entity`).

* **El Riesgo:** Si expones tus Entidades directamente en la API REST (el controlador devuelve `Usuario`), estás exponiendo tu base de datos al mundo (password, fechas internas, etc.).
* **La Solución:** Necesitaremos crear una carpeta `dto` y clases como `UsuarioDTO` o `ReservaRequestDTO`.
* **Acción:** No crees issues nuevas todavía, pero ten en mente que cuando hagamos los Controladores (Milestone 3), necesitaremos Mappers.

#### B. ⚠️ Validaciones (JSR-380)

En las issues de entidades has puesto "Campos obligatorios", pero no hemos explicitado las validaciones.

* **El Riesgo:** Que entren datos basura en la BD (emails sin `@`, DNIs falsos, fechas pasadas).
* **Acción:** En las issues #6-#10, asegúrate de añadir anotaciones como `@NotNull`, `@Email`, `@Future` (para reservas).

#### C. ⚠️ Cliente de Base de Datos

Vamos a usar Docker para MySQL (Issue #5), perfecto. Pero, ¿cómo vas a ver los datos tú?

* **Pregunta:** ¿Tienes instalado **DBeaver** o vas a usar la herramienta **Database** integrada de IntelliJ Ultimate?
* **Recomendación:** Usa la de IntelliJ, es brutal. Pero asegúrate de saber conectarla al Docker.

#### D. ⚠️ Actualización de la Memoria del TFG

Esto es un TFG, no solo software.

* **El Riesgo:** Que programes mucho y escribas poco. Luego viene el agobio final.
* **Acción:** Sugiero una **Issue Recurrente** o una tarea en cada Milestone llamada "Documentar avances en la Memoria".

---

### 3. 📅 Planificación de la Semana (Sprint Goal)

**Objetivo del Sprint:**
*"Finalizar la capa de persistencia: Tener la base de datos corriendo en Docker y todas las tablas mapeadas en clases Java (Entidades) probadas."*

**Tu Hoja de Ruta Semanal:**

| Día | Tarea Clave | Issue | Estado |
| --- | --- | --- | --- |
| **Lunes (Hoy)** | Diseño del Diagrama E/R final (Papel/Diagrama) | **#4** | 🚀 Ready |
| **Martes** | Configurar `docker-compose.yml` para MySQL | **#5** | ⏳ Pending |
| **Miércoles** | Crear Entidades `Usuario` y `Cortador` | **#6, #7** | 📋 Backlog |
| **Jueves** | Crear Entidades `Servicio` y `Reserva` (La difícil) | **#8, #9** | 📋 Backlog |
| **Viernes** | Revisión, Tests básicos de carga de contexto y Documentación | **#10** | 📋 Backlog |

---

### 4. 🚀 Daily Stand-up: ¿Qué hacemos AHORA?

Si estás de acuerdo con este plan, tu tarea inmediata es mover la **Issue #4 (Diseño E/R)** a **In Progress**.

**Tarea para ahora mismo:**
Necesitamos definir "sobre el papel" (o herramienta digital) cómo son tus tablas exactamente antes de tocar código.

* ¿Un usuario tiene *muchas* reservas? (1:N)
* ¿Una reserva tiene *un* solo cortador? (N:1)
* ¿Qué pasa si borramos un usuario? ¿Se borran sus reservas? (Cascada).
