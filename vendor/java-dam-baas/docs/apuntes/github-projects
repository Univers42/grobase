# 🚀 Guía Completa: GitHub Project para JamonBooking

## 📋 ÍNDICE
1. [Configuración Inicial del Repositorio](#1-configuración-inicial-del-repositorio)
2. [Creación del GitHub Project](#2-creación-del-github-project)
3. [Configuración del Board](#3-configuración-del-board)
4. [Estructura de Issues (Backlog)](#4-estructura-de-issues-backlog)
5. [Workflow Recomendado](#5-workflow-recomendado)
6. [Milestones y Sprints](#6-milestones-y-sprints)
7. [Labels (Etiquetas)](#7-labels-etiquetas)
8. [Plantillas de Issues](#8-plantillas-de-issues)
9. [Integración con Commits](#9-integración-con-commits)
10. [Consejos Pro](#10-consejos-pro)

---

## 1. CONFIGURACIÓN INICIAL DEL REPOSITORIO

### Paso 1.1: Crear Repositorio Privado

```bash
# Crear en GitHub.com:
Nombre: jamonbooking
Descripción: Sistema de Gestión de Reservas para Cortadores de Jamón - TFG DAM
Visibilidad: Private
✅ Add README
✅ Add .gitignore (Java)
❌ Choose a license (proyecto académico privado)
```

### Paso 1.2: Estructura de Ramas Recomendada

```
main (producción - código estable)
├── develop (desarrollo - integración)
│   ├── feature/backend-setup
│   ├── feature/entidades-jpa
│   ├── feature/crud-cortadores
│   ├── feature/sistema-reservas
│   ├── feature/frontend-login
│   └── ...
└── hotfix/... (solo para bugs críticos en main)
```

**Configurar protección de main:**
- Settings → Branches → Add rule
- Branch name pattern: `main`
- ✅ Require pull request reviews before merging
- ✅ Require status checks to pass

### Paso 1.3: README Inicial

```markdown
# 🥩 JamonBooking

Sistema de Gestión de Reservas para Cortadores de Jamón Serrano

## 🎯 Proyecto Fin de Ciclo - DAM
**Semestre:** 1S2526  
**Stack:** Java + Spring Boot + JavaFX + MySQL

## 📂 Estructura del Proyecto
```
jamonbooking/
├── backend/          # API REST Spring Boot
├── frontend/         # Aplicación JavaFX
├── docs/             # Documentación del proyecto
│   ├── diagramas/    # ER, Casos de Uso, Clases
│   ├── mockups/      # Diseños de interfaces
│   └── memoria/      # Borradores de memoria
└── database/         # Scripts SQL
```

## 🚀 Estado del Proyecto
En desarrollo - Ver [Project Board](link)

## 📅 Entrega Final
9 de diciembre de 2025, 09:59h
```

---

## 2. CREACIÓN DEL GITHUB PROJECT

### Paso 2.1: Crear Project

1. En tu repositorio → **Projects** (pestaña superior)
2. Click **"New project"**
3. Seleccionar **"Board"** (vista Kanban)
4. Nombre: **"JamonBooking - TFG Sprint Board"**
5. Descripción: "Gestión de tareas para desarrollo del TFG DAM 1S2526"
6. Visibilidad: **Private**

### Paso 2.2: Crear Vista Adicional (Roadmap/Timeline)

1. Dentro del Project → **"+ New view"**
2. Seleccionar **"Roadmap"** (vista Gantt)
3. Nombre: **"Timeline Gantt"**
4. Esta vista mostrará tus issues en formato calendario

### Paso 2.3: Crear Vista de Tabla

1. **"+ New view"** → **"Table"**
2. Nombre: **"Backlog Completo"**
3. Útil para ver todos los issues con detalles en formato tabla

---

## 3. CONFIGURACIÓN DEL BOARD

### Columnas Recomendadas (Kanban)

```
📋 Backlog          → Issues pendientes de priorizar
🎯 To Do            → Tareas priorizadas para esta semana
🔨 In Progress      → Trabajando ahora (máx. 2-3 issues)
🧪 Testing          → En pruebas
✅ Done             → Completadas
❌ Cancelled        → Descartadas o pospuestas
```

### Configuración de Automatizaciones

**Automatizar columna "In Progress":**
- Settings (⚙️) de la columna → Workflows
- ✅ Set status to "In Progress" when issues are assigned
- ✅ Set status to "In Progress" when PR is opened

**Automatizar columna "Done":**
- ✅ Set status to "Done" when issues are closed
- ✅ Set status to "Done" when PR is merged

---

## 4. ESTRUCTURA DE ISSUES (BACKLOG)

### 🗂️ Categorización de Issues

#### **ÉPICAS (Grandes Bloques - usar como Milestones)**
```
📦 Epic: Configuración Inicial
📦 Epic: Backend - Entidades y Base de Datos
📦 Epic: Backend - Servicios y API REST
📦 Epic: Frontend - Autenticación y Navegación
📦 Epic: Frontend - Gestión de Cortadores
📦 Epic: Frontend - Sistema de Reservas
📦 Epic: Testing e Integración
📦 Epic: Documentación
```

#### **ISSUES ESPECÍFICOS (Tareas Atómicas)**

### 📝 BACKLOG COMPLETO - 50+ Issues

---

### **🔧 FASE 1: CONFIGURACIÓN INICIAL (Semana 1)**

#### Issue #1: Setup del proyecto backend Spring Boot
```yaml
Título: [SETUP] Configurar proyecto Spring Boot con Maven
Labels: setup, backend, priority-high
Milestone: Epic: Configuración Inicial
Estimate: 2h

Descripción:
- [ ] Crear proyecto en Spring Initializr (Boot 3.x, Java 17)
- [ ] Dependencies: Web, JPA, MySQL, Security, Validation, Lombok
- [ ] Configurar application.properties (DB connection)
- [ ] Estructura de paquetes: controller, service, repository, model, dto, exception
- [ ] Verificar que corre en localhost:8080

Criterios de Aceptación:
✅ Proyecto compila sin errores
✅ Servidor Tomcat arranca correctamente
✅ Conexión a MySQL funcional
```

#### Issue #2: Setup del proyecto frontend JavaFX
```yaml
Título: [SETUP] Configurar proyecto JavaFX con Maven
Labels: setup, frontend, priority-high
Estimate: 2h

- [ ] Crear proyecto Maven con JavaFX 17
- [ ] Configurar pom.xml con javafx-maven-plugin
- [ ] Estructura: controllers, views, services, models, utils
- [ ] Crear Main.java con Stage principal
- [ ] Scene Builder: Verificar compatibilidad
```

#### Issue #3: Configurar repositorio Git y ramas
```yaml
Título: [SETUP] Configurar Git Flow y protección de ramas
Labels: setup, devops, priority-medium
Estimate: 1h

- [ ] Crear rama develop
- [ ] Proteger rama main (require PR)
- [ ] Configurar .gitignore (target/, .idea/, *.iml)
- [ ] Primer commit con estructura base
```

#### Issue #4: Diseñar modelo Entidad-Relación
```yaml
Título: [DISEÑO] Crear diagrama ER de la base de datos
Labels: diseño, database, priority-high
Milestone: Epic: Backend - Entidades y BD
Estimate: 3h

- [ ] Diseñar 5 tablas: Usuario, Cortador, Servicio, Reserva, Notificacion
- [ ] Definir relaciones: 1:N, N:M
- [ ] Especificar tipos de datos, PKs, FKs, constraints
- [ ] Herramienta: draw.io o dbdiagram.io
- [ ] Exportar PNG para documentación
```

#### Issue #5: Crear script SQL de base de datos
```yaml
Título: [DATABASE] Script de creación de tablas MySQL
Labels: database, backend, priority-high
Estimate: 2h

- [ ] CREATE TABLE de 5 entidades
- [ ] Constraints (PK, FK, UNIQUE, NOT NULL)
- [ ] Índices para optimización
- [ ] INSERT de datos iniciales (admin, servicios)
- [ ] Probar en MySQL Workbench
```

---

### **📊 FASE 2: BACKEND - ENTIDADES (Semana 2)**

#### Issue #6: Crear entidad Usuario con JPA
```yaml
Título: [BACKEND] Entidad Usuario con anotaciones JPA
Labels: backend, entity, priority-high
Estimate: 1.5h

- [ ] Clase Usuario.java con @Entity
- [ ] Campos: id, dni, nombre, apellidos, email, telefono, password, rol, activo
- [ ] Anotaciones: @Id, @GeneratedValue, @Column, @Enumerated
- [ ] Relación @OneToMany con Reserva
- [ ] Validaciones: @NotNull, @Email, @Size
```

#### Issue #7: Crear entidad Cortador con JPA
```yaml
Título: [BACKEND] Entidad Cortador con anotaciones JPA
Labels: backend, entity, priority-high
Estimate: 1h

- [ ] Clase Cortador.java
- [ ] Campos: nombre, apellidos, dni, email, experiencia, especialidad, activo
- [ ] Relación @OneToMany con Reserva
```

#### Issue #8: Crear entidad Servicio con JPA
```yaml
Título: [BACKEND] Entidad Servicio con datos fijos
Labels: backend, entity, priority-medium
Estimate: 1h

- [ ] Clase Servicio.java
- [ ] Campos: nombre, duracionMinutos, precio, descripcion
- [ ] Script SQL con 3 servicios predefinidos (Jamón, Paleta, Embutido)
```

#### Issue #9: Crear entidad Reserva con JPA
```yaml
Título: [BACKEND] Entidad Reserva con relaciones
Labels: backend, entity, priority-high
Estimate: 2h

- [ ] Clase Reserva.java
- [ ] @ManyToOne con Usuario (cliente)
- [ ] @ManyToOne con Cortador
- [ ] @ManyToOne con Servicio
- [ ] Campos: fecha, horaInicio, horaFin, estado (ENUM)
- [ ] @CreationTimestamp, @UpdateTimestamp
- [ ] Constraint unique (cortador_id, fecha, hora_inicio)
```

#### Issue #10: Crear entidad Notificacion
```yaml
Título: [BACKEND] Entidad Notificacion para logs
Labels: backend, entity, priority-low
Estimate: 1h

- [ ] Clase Notificacion.java
- [ ] @ManyToOne nullable con Usuario
- [ ] @ManyToOne con Reserva
- [ ] Campos: tipo (ENUM), mensaje, destinatarioEmail, leida
```

---

### **🔌 FASE 3: BACKEND - REPOSITORIES (Semana 2)**

#### Issue #11: Crear UsuarioRepository con Spring Data
```yaml
Título: [BACKEND] Repository para Usuario con métodos custom
Labels: backend, repository, priority-high
Estimate: 1h

- [ ] Interface UsuarioRepository extends JpaRepository
- [ ] Método: findByEmail(String email)
- [ ] Método: findByDni(String dni)
- [ ] Método: findByRol(Rol rol)
```

#### Issue #12-14: Repositories para Cortador, Servicio, Reserva
```yaml
Similar estructura, métodos específicos:
- ReservaRepository.findByCortadorAndFechaAndEstadoIn(...)
- ReservaRepository.countReservasDiarias(@Query custom)
```

---

### **⚙️ FASE 4: BACKEND - SERVICES (Semana 3-4)**

#### Issue #15: Servicio de Autenticación
```yaml
Título: [BACKEND] AuthService con login y registro
Labels: backend, service, security, priority-high
Estimate: 3h

- [ ] Método login(email, password) → UsuarioDTO
- [ ] Validar credenciales con BCrypt
- [ ] Método registrarCliente(RegistroDTO)
- [ ] Validar DNI/Email únicos
- [ ] Encriptar contraseña
```

#### Issue #16: Servicio de Cortadores (CRUD)
```yaml
Título: [BACKEND] CortadorService con CRUD completo
Labels: backend, service, priority-high
Estimate: 2h

- [ ] Método crearCortador(CortadorDTO)
- [ ] Método actualizarCortador(id, CortadorDTO)
- [ ] Método desactivarCortador(id)
- [ ] Validar: No eliminar último cortador activo
- [ ] listarCortadoresActivos()
```

#### Issue #17: Servicio de Reservas (CRÍTICO)
```yaml
Título: [BACKEND] ReservaService con lógica de disponibilidad
Labels: backend, service, priority-critical
Estimate: 5h

- [ ] Método crearReserva(ReservaDTO)
- [ ] Validar disponibilidad de cortador (no solapamientos)
- [ ] Validar límites cliente (2 diarias, 4 semanales)
- [ ] Validar carga cortador (3 jamones, 6h max)
- [ ] Calcular horaFin automáticamente según servicio
- [ ] Cambiar estado a CONFIRMADA
- [ ] Generar notificación
```

#### Issue #18: Validador de disponibilidad
```yaml
Título: [BACKEND] DisponibilidadService para cálculo de slots
Labels: backend, service, priority-high
Estimate: 4h

- [ ] Método obtenerSlotsDisponibles(cortadorId, fecha, duracion)
- [ ] Verificar horario laboral (10-18h, L-V)
- [ ] Consultar reservas existentes
- [ ] Algoritmo de cálculo de huecos libres
- [ ] Retornar lista de LocalTime disponibles
```

#### Issue #19: Servicio de Notificaciones
```yaml
Título: [BACKEND] NotificacionService para logs simulados
Labels: backend, service, priority-medium
Estimate: 2h

- [ ] Método enviarNotificacion(tipo, reserva)
- [ ] Generar mensaje según evento (Nueva, Cancelación, Modificación)
- [ ] Guardar en BD tabla Notificacion
- [ ] Logger.info() simulando envío email
```

---

### **🌐 FASE 5: BACKEND - CONTROLLERS (Semana 4)**

#### Issue #20: Controller de Autenticación
```yaml
Título: [BACKEND] AuthController con endpoints login y registro
Labels: backend, controller, api, priority-high
Estimate: 2h

- [ ] POST /api/auth/login → UsuarioDTO
- [ ] POST /api/auth/registro → ResponseEntity
- [ ] Validaciones con @Valid
- [ ] Manejo de excepciones (credenciales incorrectas)
```

#### Issue #21-24: Controllers CRUD
```yaml
- UsuarioController: GET, PUT, DELETE /api/usuarios
- CortadorController: CRUD /api/cortadores
- ReservaController: CRUD + /disponibilidad
- ServicioController: GET /api/servicios (solo lectura)
```

#### Issue #25: Endpoint de disponibilidad
```yaml
Título: [BACKEND] Endpoint GET /api/disponibilidad
Labels: backend, controller, api, priority-high
Estimate: 2h

- [ ] GET /api/disponibilidad?cortadorId=&fecha=&servicioId=
- [ ] Retornar List<LocalTime> de slots disponibles
- [ ] Formatear respuesta JSON clara
```

---

### **🎨 FASE 6: FRONTEND - DISEÑO (Semana 3)**

#### Issue #26: Diseñar mockups en Scene Builder
```yaml
Título: [DISEÑO] Mockups de 6 pantallas principales
Labels: diseño, frontend, priority-high
Estimate: 4h

- [ ] Login.fxml
- [ ] Registro.fxml
- [ ] DashboardAdmin.fxml
- [ ] DashboardCliente.fxml
- [ ] Calendario.fxml
- [ ] FormularioReserva.fxml
```

#### Issue #27: Crear estilos CSS globales
```yaml
Título: [FRONTEND] Hoja de estilos CSS para JavaFX
Labels: frontend, ui, priority-medium
Estimate: 2h

- [ ] Definir paleta de colores (primary, secondary, accent)
- [ ] Estilos para botones, tablas, formularios
- [ ] Aplicar a todas las vistas
```

---

### **🖥️ FASE 7: FRONTEND - IMPLEMENTACIÓN (Semana 5-6)**

#### Issue #28: Pantalla de Login
```yaml
Título: [FRONTEND] Vista y Controller de Login
Labels: frontend, controller, priority-high
Estimate: 3h

- [ ] LoginController.java
- [ ] Campos: TextField email, PasswordField password
- [ ] Botón "Iniciar Sesión" → llamar API /auth/login
- [ ] Validar respuesta → Guardar sesión en SessionManager
- [ ] Redirect según rol (Admin/Cliente)
- [ ] Manejo de errores (credenciales incorrectas)
```

#### Issue #29: Pantalla de Registro
```yaml
Título: [FRONTEND] Formulario de registro de cliente
Labels: frontend, controller, priority-high
Estimate: 3h

- [ ] Validaciones en tiempo real (email, DNI, teléfono)
- [ ] PasswordField con confirmación
- [ ] POST /api/auth/registro
- [ ] Mensaje de éxito → Redirect a Login
```

#### Issue #30: Dashboard Admin - CRUD Cortadores
```yaml
Título: [FRONTEND] Panel admin con tabla de cortadores
Labels: frontend, controller, priority-high
Estimate: 4h

- [ ] TableView con columnas: Nombre, DNI, Email, Experiencia, Estado
- [ ] Botones: Nuevo, Editar, Activar/Desactivar
- [ ] Modal para crear/editar cortador
- [ ] Refresh automático tras operaciones
```

#### Issue #31: Dashboard Cliente
```yaml
Título: [FRONTEND] Panel de cliente con próximas reservas
Labels: frontend, controller, priority-high
Estimate: 3h

- [ ] TableView con reservas futuras
- [ ] Botones: Nueva Reserva, Ver Historial
- [ ] Menú superior: Mi Perfil, Notificaciones
```

#### Issue #32: Vista de Calendario (CRÍTICA)
```yaml
Título: [FRONTEND] Calendario interactivo de disponibilidad
Labels: frontend, controller, priority-critical
Estimate: 6h

- [ ] DatePicker para selección de fecha
- [ ] ComboBox: Filtro por tipo de servicio
- [ ] TableView/GridPane: Cortadores x Slots (10:00-18:00)
- [ ] Celda verde (disponible) / roja (ocupado)
- [ ] Click en celda verde → Abrir formulario de reserva
- [ ] GET /api/disponibilidad dinámico
```

#### Issue #33: Formulario de Reserva
```yaml
Título: [FRONTEND] Modal de confirmación de reserva
Labels: frontend, controller, priority-high
Estimate: 2h

- [ ] Resumen: Servicio, Cortador, Fecha, Hora
- [ ] Botón "Confirmar" → POST /api/reservas
- [ ] Mensaje de éxito/error
- [ ] Cerrar modal y refrescar calendario
```

#### Issue #34: Historial de Reservas
```yaml
Título: [FRONTEND] Vista con todas las reservas del cliente
Labels: frontend, controller, priority-medium
Estimate: 2h

- [ ] TableView con filtros: Próximas, Pasadas, Todas
- [ ] Columnas: Fecha, Hora, Servicio, Cortador, Estado
- [ ] Acciones: Modificar, Cancelar (con validación 1 día)
```

---

### **🔗 FASE 8: FRONTEND - INTEGRACIÓN API (Semana 6)**

#### Issue #35: Crear ApiClient genérico
```yaml
Título: [FRONTEND] Clase ApiClient con HttpClient
Labels: frontend, service, priority-high
Estimate: 3h

- [ ] Singleton con HttpClient configurado
- [ ] Métodos: get(), post(), put(), delete()
- [ ] Base URL: http://localhost:8080/api
- [ ] Manejo de errores HTTP (401, 404, 500)
- [ ] Serialización/deserialización JSON (Jackson/Gson)
```

#### Issue #36-40: Services para cada entidad
```yaml
- AuthService.java (llamadas a /auth/*)
- CortadorService.java
- ReservaService.java
- UsuarioService.java
```

---

### **🧪 FASE 9: TESTING (Semana 7)**

#### Issue #41: Tests unitarios de ReservaService
```yaml
Título: [TEST] JUnit para lógica de reservas
Labels: testing, backend, priority-high
Estimate: 3h

- [ ] Test: crearReserva con disponibilidad → éxito
- [ ] Test: crearReserva con solapamiento → excepción
- [ ] Test: exceder límite diario → excepción
- [ ] Test: exceder límite semanal → excepción
- [ ] Mockito para repositorios
```

#### Issue #42: Tests de endpoints críticos
```yaml
Título: [TEST] Integration tests de API REST
Labels: testing, backend, priority-medium
Estimate: 2h

- [ ] Test POST /api/reservas → 201 Created
- [ ] Test GET /api/disponibilidad → 200 OK
- [ ] Test POST /auth/login credenciales incorrectas → 401
```

#### Issue #43: Pruebas manuales end-to-end
```yaml
Título: [TEST] Casos de prueba completos frontend-backend
Labels: testing, integration, priority-high
Estimate: 4h

- [ ] Flujo: Registro → Login → Nueva Reserva → Confirmación
- [ ] Flujo: Admin crea cortador → Cliente ve disponibilidad
- [ ] Flujo: Cancelar reserva → Slot se libera
- [ ] Validar notificaciones en log
```

---

### **📝 FASE 10: DOCUMENTACIÓN (Semana 8-9)**

#### Issue #44: Redactar memoria - Introducción y Objetivos
```yaml
Título: [DOCS] Secciones Introducción, Motivación, Objetivos
Labels: documentación, priority-high
Estimate: 3h

- [ ] Portada con datos
- [ ] Índice automático
- [ ] Introducción (3-4 páginas)
- [ ] Abstract en inglés
- [ ] Objetivos generales y específicos
```

#### Issue #45-50: Redactar resto de secciones
```yaml
- Estado del Arte (4-5 pág)
- Metodología (2-4 pág)
- Tecnologías (2-3 pág)
- Análisis (8-16 pág con diagramas)
- Diseño (6-14 pág con mockups y código)
- Despliegue y Pruebas (4-10 pág)
- Conclusiones (2-3 pág)
- Vías Futuras (2-3 pág)
- Bibliografía/Webgrafía
```

#### Issue #51: Manual de instalación
```yaml
Título: [DOCS] Anexo: Manual de instalación paso a paso
Labels: documentación, priority-high
Estimate: 2h

- [ ] Requisitos previos (Java, MySQL, IntelliJ)
- [ ] Clonar repositorio
- [ ] Configurar BD
- [ ] Ejecutar backend
- [ ] Ejecutar frontend
- [ ] Capturas de pantalla
```

#### Issue #52: Manual de usuario
```yaml
Título: [DOCS] Anexo: Manual de usuario con capturas
Labels: documentación, priority-high
Estimate: 2h

- [ ] Cómo registrarse
- [ ] Cómo hacer una reserva
- [ ] Cómo modificar/cancelar
- [ ] Funciones de administrador
```

---

### **🎥 FASE 11: PRESENTACIÓN (Semana 10)**

#### Issue #53: Crear presentación PowerPoint
```yaml
Título: [PRES] Diapositivas para defensa (20-25 slides)
Labels: presentación, priority-critical
Estimate: 4h

- [ ] Portada
- [ ] Índice
- [ ] Introducción y motivación
- [ ] Objetivos
- [ ] Tecnologías
- [ ] Metodología
- [ ] Análisis (diagramas ER, Casos de Uso)
- [ ] Diseño (mockups, arquitectura)
- [ ] Implementación (capturas de código)
- [ ] Demostración (capturas de app)
- [ ] Pruebas
- [ ] Conclusiones
- [ ] Vías futuras
```

#### Issue #54: Ensayar defensa oral
```yaml
Título: [PRES] Practicar presentación 15-25 min
Labels: presentación, priority-high
Estimate: 3h

- [ ] Cronometrar cada sección
- [ ] Ajustar ritmo (no más de 25 min)
- [ ] Practicar sin leer apuntes
- [ ] Preparar demo en vivo de la app
```

#### Issue #55: Grabar vídeo final
```yaml
Título: [PRES] Grabación de vídeo de defensa
Labels: presentación, priority-critical
Estimate: 2h (+ regrabar si es necesario)

- [ ] Software: OBS Studio o Zoom
- [ ] Sin cortes ni edición
- [ ] Cámara + pantalla visibles
- [ ] Formato .mp4
- [ ] Duración: 15-25 minutos
- [ ] Subir a Google Drive
```

---

### **🚀 FASE 12: ENTREGA (9 Diciembre 2025)**

#### Issue #56: Preparar archivos de entrega
```yaml
Título: [ENTREGA] Empaquetar todos los archivos finales
Labels: entrega, priority-critical
Estimate: 2h

- [ ] Memoria.pdf + Memoria.docx
- [ ] Presentación.pptx + PDF
- [ ] Video.mp4
- [ ] Código backend (ZIP sin /target)
- [ ] Código frontend (ZIP sin /target)
- [ ] Script SQL de BD
- [ ] README con instrucciones
- [ ] Verificar que TODO compila
```

#### Issue #57: Subir a Google Drive y Campus
```yaml
Título: [ENTREGA] Subir archivos antes de 9 dic 09:59h
Labels: entrega, priority-critical
Estimate: 1h

- [ ] Crear carpeta en Google Drive
- [ ] Subir todos los archivos
- [ ] Generar enlace compartido
- [ ] Incluir enlace en portada de memoria
- [ ] Subir memoria.pdf en tarea del campus
- [ ] Añadir enlace Drive como comentario
- [ ] VERIFICAR hora de última modificación
```

---

## 5. WORKFLOW RECOMENDADO

### Ciclo Diario de Trabajo

```
1. MAÑANA (30 min)
   └── Revisar Board → Mover issues a "In Progress"
   └── Priorizar: ¿Qué 1-2 issues termino hoy?

2. DESARROLLO (3-4h)
   └── Crear rama: feature/nombre-issue
   └── Trabajar en código
   └── Commits frecuentes: "feat: descripción" o "fix: bug"

3. CIERRE DE ISSUE (30 min)
   └── Probar que funciona
   └── Commit final: "feat: closes #N - descripción completa"
   └── Push a rama feature
   └── Merge a develop (o PR si quieres práctica)
   └── Mover issue a "Done"
   └── Actualizar documentación si aplica

4. TARDE (2h)
   └── Continuar con siguiente issue o refactorizar

5. NOCHE (15 min)
   └── Revisar progreso en Board
   └── Planificar mañana siguiente
```

---

## 6. MILESTONES Y SPRINTS

### Crear Milestones (Épicas)

```
Milestone 1: Setup e Infraestructura
Fecha: 15 octubre 2025
Issues: #1-5

Milestone 2: Backend - Base de Datos
Fecha: 25 octubre 2025
Issues: #6-14

Milestone 3: Backend - Lógica de Negocio
Fecha: 10 noviembre 2025
Issues: #15-25

Milestone 4: Frontend - UI/UX
Fecha: 25 noviembre 2025
Issues: #26-34

Milestone 5: Integración y Testing
Fecha: 30 noviembre 2025
Issues: #35-43

Milestone 6: Documentación
Fecha: 5 diciembre 2025
Issues: #44-52

Milestone 7: Presentación y Entrega
Fecha: 9 diciembre 2025
Issues: #53-57
```

---

## 7. LABELS (ETIQUETAS)

### Labels Recomendadas

```
🔴 priority-critical   (Bloqueante, urgente)
🟠 priority-high       (Importante, hacer pronto)
🟡 priority-medium     (Normal)
🟢 priority-low        (Puede esperar)

📦 epic                (Épica grande)
🐛 bug                 (Error a corregir)
✨ feature             (Nueva funcionalidad)
📝 documentación       (Tareas de docs)
🧪 testing             (Pruebas)
🎨 frontend            (UI/UX)
⚙️ backend             (API/Servicios)
🗄️ database            (BD y scripts)
🔧 setup               (Configuración)
🚀 entrega             (Relacionado con entrega final)
```

---

## 8. PLANTILLAS DE ISSUES

### Crear Template en `.github/ISSUE_TEMPLATE/`

**feature_template.md:**
```markdown
---
name: Nueva Funcionalidad
about: Implementar una nueva feature
title: '[FEATURE] '
labels: feature
---

## Descripción
¿Qué funcionalidad se implementa?

## Tareas
- [ ] Tarea 1
- [ ] Tarea 2
- [ ] Tarea 3

## Criterios de Aceptación
✅ Criterio 1
✅ Criterio 2

## Estimación
⏱️ X horas

## Notas Técnicas
<!-- Consideraciones, dependencias, etc. -->
```

---

## 9. INTEGRACIÓN CON COMMITS

### Sintaxis para Cerrar Issues Automáticamente

```bash
# Cerrar issue con commit
git commit -m "feat: sistema de login completo - closes #28"

# Referenciar sin cerrar
git commit -m "refactor: mejora validación (#15)"

# Cerrar múltiples
git commit -m "fix: corregir bugs reservas - closes #40, closes #41"
```

### Convención de Mensajes (Conventional Commits)

```
feat: nueva funcionalidad
fix: corrección de bug
docs: cambios en documentación
style: formato (sin cambios de código)
refactor: refactorización
test: añadir tests
chore: tareas de mantenimiento
```

---

## 10. CONSEJOS PRO

### ✅ DO (Hacer)

1. **Atomicidad:** Un issue = Una funcionalidad específica
2. **Estimaciones realistas:** Añade 30% más tiempo del que crees
3. **WIP Limit:** Máximo 2-3 issues en "In Progress" simultáneos
4. **Review semanal:** Cada domingo, revisar qué se completó
5. **Actualizar diariamente:** 5 min/día para mover tarjetas
6. **Screenshots:** Añade capturas en comentarios de issues de frontend
7. **Links cruzados:** Referenciar issues relacionados (#número)

### ❌ DON'T (Evitar)

1. **Issues vagos:** "Hacer frontend" → NO. "Pantalla de login" → SÍ
2. **Acumular en "In Progress":** Termina antes de empezar nuevas
3. **Olvidar cerrar issues:** Al terminar, marca como Done
4. **Estimaciones muy optimistas:** Siempre hay imprevistos
5. **No documentar decisiones:** Usa comentarios en issues
6. **Abandonar el board:** Si no lo usas, no sirve de nada

---

## 🎯 RESUMEN EJECUTIVO

**Setup Completo:**
1. ✅ Crear repo privado con estructura
2. ✅ Crear GitHub Project con 3 vistas (Board, Roadmap, Table)
3. ✅ Configurar columnas Kanban con automatizaciones
4. ✅ Crear 7 Milestones (Épicas)
5. ✅ Crear 57 Issues detallados
6. ✅ Asignar labels y estimaciones
7. ✅ Configurar templates de issues

**Workflow Diario:**
```
Revisar Board → Priorizar → Trabajar → Commit → Cerrar Issue → Repeat
```

**Métricas a Seguir:**
- Issues cerrados por semana (objetivo: 5-8)
- Burndown chart (en vista Roadmap)
- Tiempo real vs estimado

---

**Con este setup, tendrás un proyecto profesional perfectamente organizado, trazable y demostrable en tu memoria. ¡Éxito! 🚀**