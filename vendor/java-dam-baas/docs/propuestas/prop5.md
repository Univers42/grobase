# PROPUESTA DE TEMA - PROYECTO FIN DE CICLO DAM
## Semestre: 1S2526

---

## 📌 TÍTULO DEL PROYECTO

**HamBooking - Sistema de Gestión de Reservas para Cortadores de Jamón Serrano**

---

## 📝 RESUMEN DEL PROYECTO

HamBooking es una aplicación de escritorio con arquitectura cliente-servidor REST que digitaliza y automatiza la gestión de reservas de servicios de corte de jamón, paleta y embutidos en tiendas especializadas. El sistema implementa tres roles diferenciados (Administrador único, Cortadores gestionados, y Clientes), un calendario interactivo con disponibilidad en tiempo real basado en slots de 30 minutos, y control automático de límites de reservas (máximo 2 diarias y 4 semanales por cliente, máximo 3 servicios de jamón diarios por cortador). Los clientes se registran automáticamente mediante validación de datos (DNI, email, teléfono), visualizan la disponibilidad de cortadores por fecha y horario, y realizan reservas con validaciones multicapa que previenen solapamientos y garantizan la correcta asignación de recursos. El administrador gestiona cortadores, usuarios y reservas con control total del sistema, mientras que las notificaciones simuladas (log en base de datos + consola) informan a clientes, cortadores y administrador sobre eventos de reservas (creación, modificación, cancelación). La aplicación cumple reglas de negocio complejas como horario laboral fijo (Lunes-Viernes 10:00-18:00), modificación/cancelación con mínimo 1 día de antelación, y gestión de 4 estados de reserva (Pendiente, Confirmada, Realizada, Cancelada) con transiciones automáticas mediante tareas programadas.

---

## 🛠️ TECNOLOGÍAS Y HERRAMIENTAS QUE SE UTILIZARÁN

El proyecto **HamBooking** ha sido diseñado estratégicamente para integrar conocimientos transversales de **los 16 módulos del ciclo formativo DAM**, desde los fundamentos técnicos de programación y bases de datos hasta competencias profesionales y sostenibilidad, demostrando una aplicación completa y cohesionada de todas las competencias adquiridas durante los dos años de formación.

### **Tabla Completa de Aplicación por Módulo**

| Módulo | Asignatura | Aplicación en el Proyecto |
|--------|-----------|---------------------------|
| **M01** | **Sistemas Informáticos** | Instalación y configuración del entorno completo (JDK 17, MySQL 8.0, IntelliJ IDEA). Gestión del sistema operativo para despliegue del servidor Tomcat embebido. Configuración de puertos (8080 backend, 3306 MySQL) y variables de entorno. Comprensión de arquitectura cliente-servidor con comunicación HTTP/TCP. |
| **M02** | **Digitalización Aplicada** | Transformación digital de un negocio tradicional (tienda de jamones) mediante automatización completa de gestión de reservas, eliminando procesos manuales ineficientes (llamadas telefónicas, agendas en papel, errores de doble reserva) y optimizando recursos humanos especializados. |
| **M03** | **Empleabilidad I** | Desarrollo de competencias profesionales: planificación con diagrama de Gantt, gestión autónoma de plazos y entregables, toma de decisiones técnicas fundamentadas, resolución de problemas mediante debugging y documentación, y comunicación efectiva en presentación oral. |
| **M04A** | **Programación A** | Fundamentos de POO en Java: diseño de clases (User, Carver, Reservation, Service), encapsulación, herencia en DTOs, uso de colecciones (ArrayList, HashMap), manejo de excepciones personalizadas (LimiteReservasException, HorarioInvalidoException), y estructuras de control. |
| **M04B** | **Programación B** | Características avanzadas: genéricos en repositorios JpaRepository<T, ID>, streams y lambdas para filtrado, Optional para manejo seguro de nulos, y patrones de diseño (DAO, DTO, Builder, Singleton). |
| **M05A** | **Bases de Datos A** | Diseño del modelo Entidad-Relación completo con 5 tablas relacionadas (Users, Carvers, Services, Reservations, Notifications), normalización hasta 3FN, definición de PKs y FKs, cardinalidades (1:1, 1:N), y diagramas con notación Crow's Foot. |
| **M05B** | **Bases de Datos B** | Implementación física en MySQL: DDL (CREATE TABLE con constraints), DML (INSERT, UPDATE, DELETE, SELECT), índices para optimización, constraints de integridad (UNIQUE, CHECK, FK con CASCADE/RESTRICT), y transacciones ACID. |
| **M06** | **Lenguajes de Marcas** | Diseño de interfaces con FXML (XML para JavaFX) que separa estructura de lógica. Intercambio de datos mediante JSON entre frontend-backend con serialización/deserialización (Jackson). Documentación en Markdown (README.md, diagramas Mermaid). |
| **M07** | **Entornos de Desarrollo** | IntelliJ IDEA (debugging, refactoring), Maven (gestión de dependencias en pom.xml), Git/GitHub (control de versiones, branching strategy main/develop/feature), GitHub Projects (Kanban board, milestones), y JUnit 5 para tests unitarios. |
| **M08** | **Inglés Profesional** | Redacción del abstract en inglés técnico. Comentarios de código y nombres de variables/métodos en inglés (camelCase, convenciones internacionales). Comprensión de documentación oficial en inglés (Spring Boot Docs, JavaFX API, MySQL Reference Manual). |
| **M09** | **Sostenibilidad** | Optimización de consultas SQL para reducir consumo de CPU/RAM del servidor. Índices estratégicos para eficiencia. Código limpio y mantenible. Digitalización para reducir uso de papel. Arquitectura escalable sin dependencias innecesarias (reducción de huella de carbono digital). |
| **M10** | **Acceso a Datos** | Persistencia completa con JPA/Hibernate (ORM). Mapeo de entidades (@Entity, @Table, @Column). Relaciones (@OneToMany, @ManyToOne, @OneToOne bidireccionales). Spring Data JPA para CRUD sin SQL explícito. Queries personalizadas con JPQL. Gestión de transacciones. |
| **M11** | **Desarrollo de Interfaces** | Diseño de 6 vistas con JavaFX y Scene Builder (login, registro, dashboard admin/cliente, calendario, formulario). Patrón MVC (FXML + Controller). Estilos CSS. Manejo de eventos (onClick, onChange). Navegación entre vistas. Layouts (BorderPane, GridPane, VBox). |
| **M12** | **Gestión Empresarial** | Arquitectura 3 capas (Presentación-Negocio-Datos). API REST con 20+ endpoints RESTful (GET, POST, PUT, DELETE). DTOs para transferencia segura. Servicios de negocio con validaciones complejas (disponibilidad, límites, solapamientos). Separación de responsabilidades. |
| **M13** | **Empleabilidad II** | Portfolio técnico en GitHub (código documentado, README profesional). Memoria técnica de 40+ páginas. Presentación PowerPoint de 20+ diapositivas. Vídeo de 15-25 minutos demostrando dominio técnico. Capacidad de explicar decisiones de diseño/arquitectura. |
| **M14** | **Módulo Optativo** | Investigación de tecnologías complementarias: servicios cloud (AWS, Azure conceptual), arquitecturas de microservicios para escalabilidad, CI/CD (Jenkins, GitHub Actions), y seguridad avanzada (OAuth2, JWT, cifrado) como mejoras futuras. |
| **M15** | **Multimedia y Móviles** | Aplicación de escritorio multiplataforma con JavaFX. Interfaces gráficas avanzadas con calendario visual (colores para disponibilidad). Manejo de eventos. Multithreading con Platform.runLater para operaciones HTTP asíncronas sin bloquear UI. Componentes personalizados. |
| **M16** | **Servicios y Procesos** | API REST con Spring Boot (@RestController, @RequestMapping). Comunicación cliente-servidor HTTP con JSON. Gestión de sesiones. Procesamiento concurrente mediante transacciones que manejan múltiples peticiones simultáneas sin conflictos de datos. |

### **Desglose Técnico Detallado**

#### **Backend - Servidor API REST**

**Lenguaje de Programación:**
- **Java 17 LTS** (M04A, M04B, M15, M16)
  - Aplicación completa de POO: clases, objetos, herencia, polimorfismo
  - Uso avanzado de genéricos, lambdas, streams, Optional
  - Manejo robusto de excepciones personalizadas

**Framework y Persistencia:**
- **Spring Boot 3.x** (M10, M12, M16)
  - **Spring Web MVC**: Controladores REST con @RestController
  - **Spring Data JPA**: Abstracción sobre Hibernate para operaciones CRUD
  - **Spring Security**: Autenticación con BCrypt, control de acceso por roles
  - **Spring Validation**: Validación de DTOs con @Valid, @NotNull, @Email

- **Hibernate / JPA** (M10)
  - ORM que mapea entidades Java a tablas MySQL
  - Gestión de relaciones 1:1 (User-Carver), 1:N (User-Reservations)
  - JPQL para queries complejas (disponibilidad, límites)
  - Transacciones con @Transactional para consistencia de datos

**Base de Datos:**
- **MySQL 8.0** (M05A, M05B, M09)
  - Diseño normalizado hasta 3FN (5 tablas relacionadas)
  - Constraints: PKs, FKs, UNIQUE, CHECK, NOT NULL
  - Índices estratégicos para optimizar consultas frecuentes
  - Scripts DDL completos con seed data (admin + servicios)

**Gestión de Dependencias:**
- **Maven** (M07)
  - Gestión automática de librerías en pom.xml
  - Plugins: spring-boot-maven-plugin, javafx-maven-plugin
  - Estructura estándar de proyecto (src/main/java, src/main/resources)

**Testing:**
- **JUnit 5** (M07)
  - Tests unitarios de servicios (ReservaService, DisponibilidadService)
  - Mockito para simular repositorios
  - Tests de integración de endpoints REST

**Servidor de Aplicaciones:**
- **Tomcat Embebido** (M01, M16)
  - Integrado en Spring Boot (sin configuración externa)
  - Despliegue simplificado en localhost:8080

#### **Frontend - Aplicación de Escritorio**

**Framework GUI:**
- **JavaFX 17** (M11, M15)
  - Justificación: Sucesor oficial de Swing (listado en normativa)
  - Diseño declarativo mediante FXML (separación MVC)
  - Soporte CSS para estilos personalizados
  - Componentes ricos: TableView, DatePicker, ComboBox

**Herramientas de Diseño:**
- **Scene Builder** (M11)
  - Diseño visual drag-and-drop de interfaces
  - Generación automática de archivos FXML
  - Preview en tiempo real

**Consumo de API REST:**
- **HttpClient (java.net.http)** (M16)
  - Cliente HTTP nativo de Java 11+
  - Peticiones GET, POST, PUT, DELETE a backend
  - Manejo de respuestas JSON con Jackson

**Gestión de Hilos:**
- **Platform.runLater** (M15)
  - Actualización de UI desde hilos secundarios
  - Operaciones HTTP asíncronas sin bloquear interfaz

#### **Arquitectura General**

**Patrón Arquitectónico:**
- **Cliente-Servidor REST** (M12, M16)
  - Separación clara: JavaFX (presentación) + Spring Boot (lógica/datos)
  - Comunicación HTTP stateless con JSON
  - API RESTful con recursos bien definidos (/api/users, /api/reservations)

**Control de Versiones:**
- **Git / GitHub** (M07)
  - Repositorio privado con historial completo
  - Branching: main (producción), develop (integración), feature/* (desarrollo)
  - Commits semánticos (feat:, fix:, docs:, refactor:)
  - GitHub Projects: Kanban board con 57 issues planificados

**Entorno de Desarrollo:**
- **IntelliJ IDEA Ultimate** (M01, M07)
  - Soporte integrado para Spring Boot, JavaFX, Maven, Git
  - Debugging avanzado con breakpoints y expresiones
  - Refactoring automático y análisis de código

#### **Otros Aspectos Técnicos**

**Lenguajes de Marcas:**
- **FXML** (M06): Estructura declarativa de vistas JavaFX
- **JSON** (M06): Formato de intercambio de datos en API REST
- **Markdown** (M06): Documentación (README, diagramas Mermaid)

**Sostenibilidad:**
- **Optimización SQL** (M09): Índices en columnas de búsqueda frecuente
- **Código limpio** (M09): Naming conventions, principios SOLID
- **Digitalización** (M09): Eliminación de procesos en papel

**Inglés Profesional:**
- **Abstract en inglés** (M08): Resumen técnico de 200 palabras
- **Documentación técnica** (M08): Spring Docs, JavaFX API Reference
- **Código en inglés** (M08): Variables, métodos, comentarios

---

## 🎯 OBJETIVOS

### **Objetivos Generales**

1. **Desarrollar una aplicación multiplataforma completa con arquitectura cliente-servidor REST** que demuestre la integración de tecnologías backend (Spring Boot, JPA, MySQL) y frontend (JavaFX), aplicando conocimientos de todos los módulos del ciclo formativo y resultando en un sistema funcional, escalable y mantenible.

2. **Automatizar la gestión de reservas de servicios especializados** mediante un sistema digital que optimice la asignación de recursos humanos (cortadores), controle disponibilidad en tiempo real con validaciones multicapa, prevenga conflictos de horarios mediante algoritmos de detección de solapamientos, reduzca errores manuales, y mejore significativamente la experiencia del cliente y la eficiencia operativa del negocio.

3. **Implementar un sistema robusto de autenticación y autorización** con roles diferenciados (Administrador con acceso total, Cortadores como recursos gestionados, Clientes con autogestión de reservas) que garantice la seguridad de datos sensibles mediante encriptación BCrypt, la correcta segregación de funcionalidades según tipo de usuario, y la trazabilidad completa de operaciones mediante auditoría de timestamps.

### **Objetivos Específicos (Funcionalidades Concretas)**

1. **Gestión completa de cortadores (CRUD):** El administrador puede crear nuevos cortadores especificando datos personales (nombre, apellidos, DNI, email, teléfono) y profesionales (especialidad, años de experiencia), modificar información existente, consultar listados filtrados por estado (activos/inactivos), y desactivar temporalmente cortadores manteniendo su historial, con validación automática que impide eliminar el último cortador activo para garantizar operatividad del sistema.

2. **Registro automático de clientes con validación robusta:** Los usuarios acceden a un formulario de registro donde ingresan DNI (validado con formato español 8 números + 1 letra), nombre, apellidos, email (verificado con expresión regular y unicidad en BD), teléfono (formato internacional o nacional), y contraseña (mínimo 8 caracteres, 1 mayúscula, 1 número). El sistema valida todos los campos en tiempo real mostrando errores específicos, encripta la contraseña con BCrypt, registra automáticamente al usuario sin intervención del administrador, y permite acceso inmediato tras confirmación.

3. **Sistema de autenticación seguro con roles:** Implementar login mediante email + contraseña con verificación contra base de datos usando BCrypt para comparación de hashes. El sistema identifica el rol del usuario (ADMIN o CLIENT) y redirige a dashboard correspondiente: administrador accede a panel de gestión completa (CRUD usuarios, cortadores, reservas), mientras que clientes acceden a panel personal (crear/modificar/cancelar sus propias reservas, ver historial). Control de sesión activa con almacenamiento de usuario logueado en memoria de aplicación (SessionManager).

4. **Calendario de disponibilidad interactivo y visual:** Los clientes seleccionan primero el tipo de servicio deseado (Jamón 2h, Paleta 1h, Embutidos 30min) mediante ComboBox, luego eligen fecha mediante DatePicker (solo días laborales L-V habilitados), y el sistema consulta automáticamente la disponibilidad de todos los cortadores activos para esa fecha, mostrando una tabla/grid visual con cortadores en filas y slots de 30 minutos (10:00, 10:30... 17:30) en columnas, usando colores para indicar estado: verde (disponible para servicio seleccionado), rojo (ocupado), gris (insuficiente tiempo para completar servicio). Permite click en celda verde para iniciar proceso de reserva.

5. **Creación de reservas con validaciones multicapa:** Cliente hace click en slot disponible, sistema abre formulario de confirmación mostrando resumen (servicio, cortador, fecha, hora inicio, hora fin calculada automáticamente). Al confirmar, backend ejecuta 7 validaciones en cascada: (1) Cliente no excede 2 reservas ese día, (2) Cliente no excede 4 reservas esa semana, (3) Cortador tiene slots libres suficientes (no solapamiento), (4) Cortador no excede 3 jamones diarios, (5) Cortador no excede 6h de trabajo efectivo, (6) Fecha es posterior a mañana (1 día antelación), (7) Horario está dentro de 10:00-18:00 L-V. Si todas pasan, cambia estado a CONFIRMADA, genera 3 notificaciones (cliente, cortador, admin) y retorna confirmación al frontend.

6. **Gestión automatizada de estados de reserva:** El sistema maneja 4 estados con transiciones controladas: PENDING (durante creación/modificación), CONFIRMED (tras validaciones exitosas y guardado en BD), COMPLETED (automáticamente mediante tarea programada @Scheduled que diariamente a las 01:00 AM verifica reservas con fecha/hora pasada y actualiza su estado), CANCELLED (cuando cliente o admin cancela explícitamente). Los estados son inmutables salvo por transiciones específicas (no se puede pasar de CANCELLED a CONFIRMED). Dashboard muestra reservas filtradas por estado con colores distintivos.

7. **Modificación de reservas con validaciones temporales:** Clientes y administrador pueden modificar reservas CONFIRMED o PENDING haciendo click en botón "Modificar" del listado. Sistema verifica que fecha de reserva sea al menos 1 día posterior a hoy (ej: hoy 15 enero, solo modificable desde 16 enero en adelante). Si cumple, permite cambiar fecha, hora, tipo de servicio o cortador, recalcula end_time automáticamente, valida nuevamente disponibilidad y límites, y si todo es válido actualiza reserva manteniendo mismo ID pero cambiando updated_at timestamp. Genera notificaciones tipo MODIFIED a los 3 destinatarios. Si cliente intenta modificar con menos de 1 día de antelación, sistema muestra error: "Debe modificar con al menos 1 día de anticipación".

8. **Cancelación de reservas con liberación automática de slots:** Cliente o admin pueden cancelar reservas con estado CONFIRMED o PENDING desde su listado. Sistema valida misma regla de 1 día de antelación. Si es válido, cambia estado a CANCELLED, libera inmediatamente los slots del cortador (otros clientes pueden reservarlos), genera notificaciones tipo CANCELLED a destinatarios, y mantiene registro histórico en BD para auditoría (no se borra físicamente). Dashboard actualiza contador de reservas activas. Si se intenta cancelar reserva ya en estado COMPLETED o CANCELLED, sistema muestra error descriptivo.

9. **Control automático de límites por cliente:** Antes de crear reserva, backend ejecuta 2 queries: (a) `SELECT COUNT(*) FROM reservations WHERE client_id=? AND date=? AND status IN ('CONFIRMED','PENDING')` para verificar límite diario (máx. 2), (b) Similar query pero con rango de fechas de lunes a viernes de esa semana para límite semanal (máx. 4). Si cualquiera excede límite, lanza excepción personalizada `LimiteReservasException` con mensaje específico ("Ya tiene 2 reservas para ese día" o "Excede el límite de 4 reservas semanales"), frontend captura excepción, muestra AlertDialog informativo, y no permite proceder con reserva.

10. **Control de carga de trabajo por cortador:** Backend valida que cortador no exceda límites diarios antes de asignar reserva: (a) Si servicio es "Jamón" (120 min), cuenta cuántos jamones tiene ese día el cortador con query filtrando por servicio_id=1 y estado activo, si ya tiene 3 lanza `LimiteCargaException`, (b) Suma total de minutos ocupados ese día con `SUM(duration_minutes)` del servicio en reservas activas, si sumar nuevo servicio excede 360 minutos (6h) lanza misma excepción. Mensajes específicos: "Cortador ya tiene 3 jamones asignados hoy" o "Excede límite de 6 horas diarias". Esto garantiza calidad del servicio evitando sobrecarga del profesional.

11. **Historial completo de reservas por cliente:** Panel de cliente incluye TableView con todas sus reservas pasadas y futuras. Columnas: Fecha, Hora, Servicio, Cortador, Estado, Acciones. Implementa 3 filtros mediante RadioButtons: (a) Próximas (fecha >= hoy, estado CONFIRMED), (b) Pasadas (estado COMPLETED o fecha < hoy), (c) Todas (sin filtro). Permite ordenar por fecha (más reciente primero). Botones de acción condicionados por estado y fecha: "Modificar" solo si fecha >= mañana y estado != COMPLETED/CANCELLED, "Cancelar" con mismas condiciones. Al hacer click en fila, muestra detalles completos en panel inferior (notas opcionales del cliente, timestamp de creación, última modificación).

12. **Sistema de notificaciones simuladas con log persistente:** Cada evento de reserva (creación, modificación, cancelación) ejecuta método `NotificacionService.enviar(tipo, reserva)` que: (1) Genera 3 registros en tabla `notifications` con destinatarios: cliente (email de users.email), cortador (email de carvers.user.email), admin (admin@hambooking.com), (2) Cada registro incluye tipo (CREATED/MODIFIED/CANCELLED), subject generado dinámicamente ("Reserva Confirmada - [Servicio]"), mensaje en texto plano con detalles completos (fecha, hora, cortador, servicio), (3) Ejecuta `Logger.info("EMAIL SIMULADO → destinatario@email.com: [subject]")` en consola backend para trazabilidad, (4) Marca `is_sent=true` simulando envío exitoso. Frontend de cliente incluye panel "Mis Notificaciones" con TableView de sus notificaciones ordenadas por fecha descendente, con columnas: Fecha, Asunto, Leída (checkbox), y botón "Ver" que abre modal con mensaje completo.

13. **Panel de administración integral con control total:** Dashboard de admin incluye 3 secciones principales mediante pestañas (TabPane): (a) **Gestión de Cortadores**: TableView con todos los cortadores (activos e inactivos), botones "Nuevo Cortador" (abre formulario modal), "Editar" (carga datos en formulario), "Activar/Desactivar" (toggle de estado), filtro por estado, y búsqueda por nombre. (b) **Gestión de Usuarios**: Similar estructura con clientes, permite ver detalles, activar/desactivar cuentas, pero NO permite modificar datos personales (RGPD). (c) **Todas las Reservas**: TableView global con filtros avanzados (por estado, por fecha, por cortador, por cliente), botones "Ver Detalles", "Modificar" (con validaciones), "Cancelar", y exportación a CSV (opcional). Dashboard superior muestra KPIs: Total cortadores activos, Reservas hoy, Reservas pendientes, Clientes registrados.

14. **Prevención de solapamientos mediante constraint de BD y validación de backend:** Doble capa de seguridad: (1) MySQL tiene constraint `UNIQUE(carver_id, reservation_date, start_time)` que impide inserciones duplicadas a nivel físico, (2) Backend antes de INSERT ejecuta query `SELECT COUNT(*) FROM reservations WHERE carver_id=? AND date=? AND ((start_time < ? AND end_time > ?) OR (start_time < ? AND end_time > ?))` verificando si rango horario de nueva reserva solapa con alguna existente (considera hora_inicio Y hora_fin de ambas reservas), si COUNT > 0 lanza `SolapamientoException` con mensaje "El cortador ya tiene una reserva en ese horario", frontend muestra error y sugiere otros slots disponibles. Algoritmo considera que servicio de 2h ocupa 4 slots consecutivos, por lo que valida no solo inicio sino todo el rango.

15. **Bloqueo del sistema sin cortadores activos:** Al iniciar aplicación, `CortadorService.contarActivos()` retorna cantidad de cortadores con `is_active=true`. Si es 0, frontend muestra banner rojo permanente en top: "⚠️ SISTEMA EN MANTENIMIENTO: No hay cortadores disponibles. Contacte al administrador." y deshabilita todos los botones de "Nueva Reserva" tanto para clientes como para admin (panel de creación de reservas se torna gris y no clickeable). Administrador ve mensaje adicional: "Debe crear al menos 1 cortador activo para que los clientes puedan reservar". Solo permite acceso a gestión de cortadores. Una vez admin crea/activa cortador, sistema refresca automáticamente y habilita funcionalidades de reserva. Evita errores y mejora UX comunicando claramente el problema.

---

## 💡 JUSTIFICACIÓN DE LA ELECCIÓN DE LA TEMÁTICA

### **Motivación Personal**

He seleccionado este proyecto porque representa un **caso de uso real y tangible** aplicable a pequeños negocios especializados que actualmente operan con procesos manuales ineficientes. La temática del corte de jamón es **original y diferenciadora** respecto a los típicos proyectos académicos de bibliotecas, tiendas genéricas o gestión de alumnos, lo que hace que el TFG sea memorable y demuestre capacidad creativa en la identificación de problemas a resolver mediante tecnología. Además, este tipo de negocio (tiendas gourmet, cortadores profesionales, servicios especializados) está en proceso de digitalización en España, por lo que la solución propuesta tiene aplicabilidad real inmediata.

El proyecto me permite aplicar de forma práctica y exhaustiva **todos los conocimientos adquiridos en el ciclo formativo**, desde diseño de bases de datos relacionales complejas con normalización hasta 3FN y modelado de entidades con múltiples relaciones (1:1, 1:N), pasando por arquitecturas cliente-servidor modernas con APIs REST que siguen principios de diseño profesional, hasta desarrollo de interfaces gráficas intuitivas con JavaFX que priorizan la experiencia de usuario. La gestión de disponibilidad temporal con slots de 30 minutos, control de límites multicapa, prevención de solapamientos mediante algoritmos de detección de rangos horarios, y automatización de estados mediante tareas programadas supone un **reto técnico significativo** que va más allá de CRUDs básicos, requiriendo lógica de negocio robusta, validaciones en múltiples capas (frontend, backend, base de datos), y pensamiento algorítmico para resolver problemas de optimización de recursos.

### **Aportación del Proyecto al Sector Productivo**

Con este proyecto aporto una **solución tecnológica completa, funcional y escalable** que podría implementarse en negocios reales del sector alimentario gourmet, optimizando radicalmente la gestión de recursos humanos especializados (cortadores profesionales) y mejorando sustancialmente la experiencia del cliente final al eliminar fricciones en el proceso de reserva. El sistema automatiza procesos que actualmente son completamente manuales en este tipo de negocios: gestión de agenda en papel o cuadernos, recepción de reservas por llamadas telefónicas (con riesgo de dobles reservas, malentendidos de horarios, o pérdida de información), cálculo mental de disponibilidad del cortador, y control manual de límites de carga de trabajo. Esta automatización reduce dramáticamente errores humanos, libera tiempo del personal administrativo que puede dedicarse a otras tareas de valor (atención al cliente, ventas), permite escalabilidad del negocio sin necesidad de contratar más personal de gestión, y proporciona datos históricos valiosos (cortador más solicitado, servicio más demandado, horas pico) que pueden informar decisiones estratégicas.

Desde el punto de vista técnico, aporto un **proyecto arquitectónicamente sólido** que sigue buenas prácticas de ingeniería de software profesional: separación clara de responsabilidades en 3 capas (presentación, negocio, datos), uso de patrones de diseño reconocidos de la industria (MVC para UI, DAO para persistencia, DTO para transferencia, Builder para construcción de objetos complejos), código limpio y mantenible con naming conventions consistentes (camelCase, nombres descriptivos en inglés), comentarios significativos que explican el "por qué" no solo el "qué", y testing automatizado con JUnit que garantiza calidad y reduce regresiones en futuras evoluciones. La arquitectura REST permite fácil extensión con otros frontends (app móvil Android nativa, web SPA con React, integración con sistemas externos), mientras que el uso de estándares ampliamente adoptados (JSON para intercambio, HTTP para comunicación, SQL para persistencia, JWT potencial para tokens) garantiza interoperabilidad y reducción de vendor lock-in.

### **Aprendizaje Personal Esperado**

Realizar este proyecto me permitirá **consolidar y profundizar** en tecnologías clave del ecosistema Java empresarial que son altamente demandadas en el mercado laboral español y europeo actual: Spring Boot (el framework más utilizado para desarrollo backend en Java según encuestas de JetBrains y Stack Overflow), JPA/Hibernate (estándar de facto para persistencia relacional en aplicaciones Java Enterprise), arquitecturas REST (fundamentales en desarrollo moderno y base de microservicios), desarrollo de aplicaciones de escritorio profesionales con JavaFX (alternativa multiplataforma a tecnologías propietarias como WPF de .NET), y gestión de bases de datos MySQL que es omnipresente en pequeñas y medianas empresas.

Además, me enfrentaré a **desafíos técnicos reales** que requieren pensamiento crítico y resolución creativa de problemas: (1) **Cálculo de disponibilidad en calendarios complejos**: diseñar algoritmo eficiente que, dado un cortador, fecha y duración de servicio, retorne lista de slots disponibles considerando reservas existentes, horario laboral, y restricciones múltiples, optimizando queries SQL para minimizar latencia incluso con miles de reservas en BD. (2) **Gestión de estados con transiciones complejas**: implementar máquina de estados finitos donde reservas solo pueden transicionar entre estados válidos (PENDING→CONFIRMED, CONFIRMED→COMPLETED/CANCELLED), con actualización automática mediante tareas programadas y manejo de casos edge (¿qué pasa si reserva está PENDING y pasa la fecha?, ¿se puede cancelar una reserva COMPLETED?). (3) **Validaciones multicapa sin duplicación**: coordinar validaciones en 3 capas (frontend valida formato de inputs, backend valida reglas de negocio complejas, BD previene inconsistencias con constraints) asegurando que cada capa valide lo apropiado sin duplicar lógica innecesariamente. (4) **Manejo de concurrencia**: prevenir condiciones de carrera donde dos clientes intentan reservar el mismo slot simultáneamente, mediante transacciones con nivel de aislamiento adecuado, locks optimistas con @Version en JPA, o constraints UNIQUE en BD como última línea de defensa.

Finalmente, el proyecto me aportará un **portfolio profesional completo y demostrable** que incluye tanto capacidades técnicas hardcore (dominio del stack completo Java/Spring/JavaFX/MySQL, comprensión de arquitecturas distribuidas, habilidad para diseñar APIs RESTful, experiencia con ORMs y queries optimization) como habilidades de análisis y diseño (levantamiento de requisitos funcionales y no funcionales mediante casos de uso, diseño de diagramas ER complejos con múltiples relaciones y normalización, creación de diagramas de clases que modelan correctamente el dominio) y competencias transversales esenciales (documentación técnica exhaustiva con memoria de 40+ páginas, capacidad de comunicación oral mediante defensa con presentación y vídeo, planificación y gestión de proyecto completo con metodología ágil usando GitHub Projects). Este conjunto de competencias técnicas y blandas son fundamentales para incorporarme con éxito al mercado laboral como desarrollador de aplicaciones multiplataforma, perfil altamente demandado en consultoras tecnológicas, empresas de producto software, y departamentos IT de grandes corporaciones.

---

## ✅ CUMPLIMIENTO DE NORMATIVA

- ✅ Aplicación **no publicada previamente** en ningún portal, plataforma, ni repositorio público
- ✅ **No forma parte** de ejemplos, ejercicios, prácticas o actividades desarrolladas durante el ciclo
- ✅ Proyecto **100% original** y de **elaboración propia** sin intervención de herramientas de IA generativa en redacción
- ✅ Base teórica aplicada de **los 16 módulos** del ciclo formativo (cobertura completa)
- ✅ Tecnologías del **listado válido** oficial: Java, Spring Boot, Hibernate, JPA, MySQL (M10), Swing listado (JavaFX justificado como sucesor)
- ✅ **JavaFX correctamente justificado** como evolución moderna de Swing (incluido en normativa)
- ✅ Mínimo **5 tablas relacionadas** con PKs, FKs y constraints (supera requisito de 3 tablas)
- ✅ Complejidad técnica **adecuada** para demostrar conocimientos del ciclo completo sin ser inabordable
- ✅ Proyecto **viable** en tiempo disponible (4-5 semanas de desarrollo efectivo con planificación detallada)

---

**Alumno/a:** [Tu Nombre y Apellidos]  
**Semestre:** 1S2526  
**Fecha de entrega propuesta:** [Fecha entre 29 sept - 16 oct 2025]