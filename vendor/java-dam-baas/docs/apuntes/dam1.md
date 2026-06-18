# Sistema de Gestión de Reservas para Cortadores de Jamón

## 📊 Resumen de lo que tenemos definido:

### ✅ **Funcionalidades Core (100% claras)**
- 3 roles bien diferenciados (Admin único, Cortadores, Clientes)
- Sistema de reservas con 4 estados
- Calendario interactivo con slots de 30 min
- Control de límites (2/día, 4/semana cliente; 3 jamones/día cortador)
- Modificación/cancelación con 1 día antelación
- Notificaciones simuladas (log)

### ✅ **Modelo de Datos (5 tablas relacionadas)**
```
Usuario (1) ──► (N) Reserva (N) ◄── (1) Cortador
                      │
                      │ (N)
                      ▼
                  Servicio (1)
                      │
                      │ (1)
                      ▼
                Notificacion (N)
```

### ✅ **Stack Tecnológico Validado**
- Backend: Java + Spring Boot + JPA/Hibernate + MySQL
- Frontend: JavaFX + Scene Builder
- Testing: JUnit 5
- IDE: IntelliJ IDEA

### ✅ **Planificación Temporal (10 semanas) aproximada**
- Semanas 1-2: Diseño
- Semanas 3-4: Backend
- Semanas 5-6: Frontend  
- Semana 7: Integración
- Semanas 8-9: Documentación
- Semana 10: Presentación

---

## 🚀 Próximos Pasos Inmediatos:

### **1. Crear Propuesta para el Tutor**
Necesitas entregar un documento con:
- Título: "Sistema de Gestión de Reservas para Cortadores de Jamón"
- Justificación (2-3 párrafos sobre por qué este tema)
- Objetivos específicos (lista de 8-10 funcionalidades)
- Tecnologías y justificación (especialmente JavaFX)

---

### **2. Diseñar Diagramas (Antes de programar)**
Para la entrega opcional necesitas:
- ✅ Diagrama Entidad-Relación (ya lo tenemos en texto, falta visual)
- ✅ Diagrama de Casos de Uso (falta crear)
- ✅ Diagrama de Clases (falta crear)

---

### **3. Crear Mockups/Wireframes (Para sección Diseño)**
Pantallas principales a diseñar:
- Login
- Dashboard Admin (CRUD Cortadores)
- Dashboard Cliente
- Calendario de disponibilidad
- Formulario de reserva
- Listado de reservas

---

# Sistema de Gestión de Reservas para Cortadores de Jamón
## Especificación Completa del Proyecto

---

## 📋 1. RESUMEN EJECUTIVO

**Nombre del Proyecto:** Sistema de Gestión de Reservas para Cortadores de Jamón

**Descripción:** Aplicación de escritorio que permite gestionar reservas de servicios de corte de jamón, paleta y embutidos en una tienda especializada. Sistema con arquitectura cliente-servidor REST que incluye roles diferenciados (Administrador único, Cortadores, Clientes), gestión de horarios fijos, calendario de disponibilidad y sistema de notificaciones.

**Objetivo Principal:** Optimizar la gestión de citas para servicios de corte de embutidos, automatizando la asignación de cortadores, control de disponibilidad y notificaciones, reduciendo errores humanos y mejorando la experiencia del cliente.

---

## 🎯 2. OBJETIVOS DEL PROYECTO

### Objetivos Generales
1. Desarrollar una aplicación completa con arquitectura cliente-servidor REST
2. Implementar sistema de gestión de usuarios con roles diferenciados
3. Automatizar el proceso de reservas y control de disponibilidad
4. Demostrar dominio de Spring Boot, JavaFX, JPA/Hibernate y MySQL

### Objetivos Específicos (Funcionalidades Concretas)
1. **CRUD de Cortadores**: El administrador puede crear, modificar, consultar y eliminar cortadores de jamón
2. **Sistema de Registro Automático**: Los clientes se registran con validación de datos (DNI, email, teléfono)
3. **Gestión de Horarios Fijos**: Cortadores con horario semanal predefinido (L-V 10:00-18:00)
4. **Calendario de Disponibilidad**: Visualización interactiva de slots disponibles por cortador y fecha
5. **Sistema de Reservas con Estados**: Crear, modificar y cancelar reservas con estados (Pendiente, Confirmada, Realizada, Cancelada)
6. **Control de Límites**: Máximo 2 reservas diarias y 4 semanales por cliente; 3 jamones diarios por cortador
7. **Notificaciones Simuladas**: Log de notificaciones por nueva reserva y cancelaciones
8. **Autenticación y Roles**: Login seguro con BCrypt, control de acceso por rol
9. **Validaciones de Negocio**: Prevención de solapamientos, reservas fuera de horario, slots insuficientes
10. **Historial de Reservas**: Los clientes pueden consultar sus reservas pasadas y futuras

---

## 👥 3. ROLES Y USUARIOS

### 3.1. Administrador (ROL: ADMIN)
- **Cantidad:** 1 único usuario predefinido en la BD
- **Credenciales iniciales:** `admin@jamonbooking.com` / `Admin123!`
- **Permisos:**
  - ✅ CRUD completo de cortadores (crear, modificar, desactivar)
  - ✅ CRUD completo de usuarios (crear, modificar, bloquear)
  - ✅ Gestionar todas las reservas (modificar, cancelar)
  - ✅ Ver dashboard con estadísticas generales
  - ✅ Acceso total a todas las funcionalidades
- **Restricciones:**
  - ⚠️ No puede eliminar el último cortador activo (mínimo 1)
  - ⚠️ Cancelaciones/modificaciones con 1 día de antelación

### 3.2. Cortador de Jamón (ROL: CORTADOR)
- **Naturaleza:** Recurso gestionado, NO usuario activo de la app
- **Representación:** Solo existe como entidad en BD
- **Datos almacenados:**
  - Datos personales: Nombre, apellidos, DNI, email
  - Datos profesionales: Años de experiencia, especialidad (Jamón/Paleta/Embutidos)
  - Estado: Activo / Inactivo
  - Horario fijo: Lunes a Viernes, 10:00-18:00 (predefinido)
- **Interacción:**
  - ❌ NO accede a la aplicación
  - ✅ Recibe notificaciones simuladas por email (log) cuando:
    - Se le asigna una nueva reserva
    - Se cancela una reserva asignada

### 3.3. Usuario / Cliente (ROL: CLIENTE)
- **Registro:** Automático mediante formulario en la aplicación
- **Datos requeridos (validados):**
  - DNI (único, formato español)
  - Nombre
  - Apellidos
  - Email (único, formato válido)
  - Teléfono (formato válido)
  - Contraseña (mínimo 8 caracteres, 1 mayúscula, 1 número)
- **Permisos:**
  - ✅ Ver calendario de disponibilidad general
  - ✅ Crear reservas (máx. 2 diarias, 4 semanales)
  - ✅ Modificar/cancelar sus propias reservas (1 día antelación)
  - ✅ Ver historial completo de sus reservas (pasadas y futuras)
  - ✅ Modificar sus datos de perfil
- **Restricciones:**
  - ❌ No puede ver reservas de otros usuarios
  - ❌ No puede reservar si no hay cortadores activos
  - ⚠️ Máximo 1 trabajo por reserva

---

## 🔧 4. TIPOS DE SERVICIO (FIJOS)

| ID | Nombre Servicio | Duración | Precio (Info) | Descripción |
|----|----------------|----------|---------------|-------------|
| 1  | Corte de Jamón | 2 horas (120 min) | 45.00€ | Corte profesional de jamón serrano o ibérico |
| 2  | Corte de Paleta | 1 hora (60 min) | 25.00€ | Corte profesional de paleta ibérica |
| 3  | Corte de Embutido | 30 minutos | 12.00€ | Corte de embutidos variados (chorizo, salchichón) |

**Características:**
- ✅ Tipos **fijos** en la BD (no modificables por admin en v1.0)
- ✅ Precios **informativos** (sin sistema de pago)
- ✅ Duración determina slots necesarios automáticamente
- 📌 **Vía futura:** Admin puede crear/modificar tipos de servicio

---

## 📅 5. GESTIÓN DE HORARIOS Y DISPONIBILIDAD

### 5.1. Horario de Cortadores
- **Horario fijo semanal:** Lunes a Viernes, 10:00 - 18:00 (8 horas/día)
- **Slots:** Divididos en bloques de **30 minutos**
  ```
  10:00, 10:30, 11:00, 11:30, 12:00, 12:30, 13:00, 13:30,
  14:00, 14:30, 15:00, 15:30, 16:00, 16:30, 17:00, 17:30
  ```
  Total: **16 slots de 30 min** por día

### 5.2. Límites por Cortador
- **Máximo 3 jamones diarios** (equivalente a 6 horas de trabajo efectivo)
- **Control de carga:** Sistema valida que no se excedan:
  - 3 servicios de jamón (2h cada uno = 6h)
  - O combinaciones equivalentes (ej: 2 jamones + 2 paletas = 6h)

### 5.3. Cálculo de Disponibilidad
**Algoritmo de slots:**
1. Servicio de Jamón (2h) requiere 4 slots consecutivos
2. Servicio de Paleta (1h) requiere 2 slots consecutivos
3. Servicio de Embutido (30min) requiere 1 slot

**Ejemplo:**
```
Cortador Juan - Lunes 15/01/2026
10:00 ████ Reserva: Jamón (Cliente A) - 2h
12:00 ░░ LIBRE
13:00 ██ Reserva: Paleta (Cliente B) - 1h
14:00 ░░░░ LIBRE
16:00 █ Reserva: Embutido (Cliente C) - 30min
16:30 ░░░ LIBRE hasta 18:00
```

### 5.4. Prevención de Solapamientos
- **Control en BD:** Constraint de unicidad en `(cortador_id, fecha, hora_inicio, hora_fin)`
- **Validación backend:** Antes de confirmar reserva, verificar:
  ```
  SELECT COUNT(*) FROM Reserva 
  WHERE cortador_id = ? 
    AND fecha = ?
    AND estado IN ('PENDIENTE', 'CONFIRMADA')
    AND (
      (hora_inicio < ? AND hora_fin > ?) OR
      (hora_inicio < ? AND hora_fin > ?)
    )
  ```
- **Bloqueo optimista:** Uso de `@Version` en entidad Reserva (JPA)

---

## 🎫 6. SISTEMA DE RESERVAS

### 6.1. Proceso de Reserva
**Flujo del cliente:**
1. Login → Panel principal
2. "Nueva Reserva" → Selecciona tipo de servicio
3. Calendario interactivo → Selecciona fecha
4. Lista de cortadores disponibles con slots libres
5. Selecciona cortador + horario disponible
6. Confirmación → Reserva pasa a estado CONFIRMADA
7. Notificación simulada enviada a cliente, cortador y admin

**Validaciones automáticas:**
- ✅ Cliente tiene menos de 2 reservas ese día
- ✅ Cliente tiene menos de 4 reservas esa semana
- ✅ Cortador tiene slots disponibles para la duración del servicio
- ✅ Cortador no excede límite de 3 jamones diarios
- ✅ Fecha es posterior a mañana (1 día antelación)

### 6.2. Estados de Reserva

| Estado | Descripción | Transiciones Permitidas |
|--------|-------------|------------------------|
| **PENDIENTE** | Reserva en proceso de creación/modificación | → CONFIRMADA, CANCELADA |
| **CONFIRMADA** | Reserva aceptada, cortador asignado | → REALIZADA, CANCELADA |
| **REALIZADA** | Servicio completado (automático después de fecha/hora fin) | (Final) |
| **CANCELADA** | Reserva cancelada por cliente o admin | (Final) |

**Cambios automáticos:**
- `PENDIENTE → CONFIRMADA`: Tras validar y guardar en BD
- `CONFIRMADA → REALIZADA`: Mediante tarea programada (Spring `@Scheduled`) que verifica diariamente reservas pasadas

### 6.3. Modificación de Reservas
**Permitido:**
- ✅ Cambiar fecha/hora (si hay disponibilidad)
- ✅ Cambiar tipo de servicio (recalcula slots)
- ✅ Cambiar cortador

**Proceso:**
1. Reserva pasa temporalmente a `PENDIENTE`
2. Se validan nuevos parámetros
3. Si OK → `CONFIRMADA` con nuevos datos
4. Si KO → Se revierte a datos anteriores

**Restricciones:**
- ⚠️ Solo con **1 día de antelación**
- ⚠️ Solo por el cliente dueño o admin

### 6.4. Cancelación de Reservas
**Quién puede cancelar:**
- Cliente (sus propias reservas)
- Admin (cualquier reserva)

**Condiciones:**
- ⚠️ Mínimo **1 día de antelación**
  - Hoy: Lunes 14/01/2026 → Solo cancelar desde 15/01/2026
- ✅ Libera los slots del cortador inmediatamente
- ✅ Envía notificación simulada a afectados

### 6.5. Límites por Cliente
- **Por día:** Máximo **2 reservas**
- **Por semana:** Máximo **4 reservas**
- **Por reserva:** **1 único servicio** (no combinar jamón + paleta en misma reserva)

---

## 🔔 7. SISTEMA DE NOTIFICACIONES

### 7.1. Notificaciones Simuladas (Log)
**Implementación:**
- Tabla `Notificacion` en BD con campos:
  - `id`, `usuario_id` (nullable para cortadores), `tipo`, `mensaje`, `fecha_creacion`, `leida`
- Log en consola backend con formato:
  ```
  [2026-01-15 10:30:45] EMAIL → cliente@example.com
  Asunto: Reserva Confirmada - Corte de Jamón
  Cuerpo: Su reserva para el 20/01/2026 a las 14:00h con Juan Pérez ha sido confirmada.
  ```

### 7.2. Eventos que Generan Notificaciones

| Evento | Destinatarios | Mensaje |
|--------|---------------|---------|
| **Nueva reserva** | Cliente, Cortador, Admin | "Reserva confirmada: [Servicio] el [Fecha] a las [Hora] con [Cortador]" |
| **Cancelación reserva** | Cliente, Cortador, Admin | "Reserva cancelada: [Servicio] el [Fecha] a las [Hora]" |
| **Modificación reserva** | Cliente, Cortador, Admin | "Reserva modificada: Ahora [Nueva Fecha/Hora]" |

### 7.3. Visualización
- **Clientes:** Panel "Mis Notificaciones" con historial
- **Admin:** Panel con todas las notificaciones del sistema
- **Cortadores:** Solo log en consola (no acceden a la app)

---

## 🔐 8. SEGURIDAD Y AUTENTICACIÓN

### 8.1. Sistema de Login
**Método:** Usuario (email) + Contraseña

**Flujo:**
1. Cliente ingresa email + password en ventana de login
2. Backend verifica con BCrypt contra BD
3. Si OK → Genera sesión con rol del usuario
4. Redirect a dashboard según rol:
   - ADMIN → Panel de administración
   - CLIENTE → Panel de cliente

### 8.2. Encriptación de Contraseñas
- **Algoritmo:** BCrypt (Spring Security)
- **Ejemplo:**
  ```java
  BCryptPasswordEncoder encoder = new BCryptPasswordEncoder();
  String hashedPassword = encoder.encode("miPassword123");
  ```

### 8.3. Requisitos de Contraseña
- ✅ Mínimo 8 caracteres
- ✅ Al menos 1 letra mayúscula
- ✅ Al menos 1 número
- ✅ Al menos 1 carácter especial (opcional)

### 8.4. Control de Acceso por Rol
**Restricciones en API REST:**
```java
// Ejemplo: Solo ADMIN puede crear cortadores
@PreAuthorize("hasRole('ADMIN')")
@PostMapping("/api/cortadores")
public ResponseEntity<Cortador> crearCortador(@RequestBody Cortador cortador) {
    // ...
}
```

---

## 🗄️ 9. MODELO DE DATOS (ENTIDADES JPA)

### 9.1. Diagrama Entidad-Relación

```
┌─────────────┐         ┌─────────────┐         ┌─────────────┐
│   Usuario   │         │  Cortador   │         │   Servicio  │
├─────────────┤         ├─────────────┤         ├─────────────┤
│ id (PK)     │         │ id (PK)     │         │ id (PK)     │
│ dni (UK)    │         │ nombre      │         │ nombre      │
│ nombre      │         │ apellidos   │         │ duracion    │
│ apellidos   │         │ dni (UK)    │         │ precio      │
│ email (UK)  │         │ email (UK)  │         │ descripcion │
│ telefono    │         │ telefono    │         └─────────────┘
│ password    │         │ experiencia │                │
│ rol         │         │ especialidad│                │
│ activo      │         │ activo      │                │
└──────┬──────┘         └──────┬──────┘                │
       │                       │                       │
       │ 1                     │ 1                     │ 1
       │                       │                       │
       │   N                   │   N                   │   N
       │                       │                       │
       └───────────────────────┴───────────────────────┘
                               │
                        ┌──────▼───────┐
                        │   Reserva    │
                        ├──────────────┤
                        │ id (PK)      │
                        │ cliente_id   │ FK → Usuario
                        │ cortador_id  │ FK → Cortador
                        │ servicio_id  │ FK → Servicio
                        │ fecha        │
                        │ hora_inicio  │
                        │ hora_fin     │
                        │ estado       │
                        │ created_at   │
                        └──────────────┘
                               │
                               │ 1
                               │
                               │ N
                        ┌──────▼───────┐
                        │ Notificacion │
                        ├──────────────┤
                        │ id (PK)      │
                        │ usuario_id   │ FK → Usuario (nullable)
                        │ reserva_id   │ FK → Reserva
                        │ tipo         │ ENUM
                        │ mensaje      │
                        │ leida        │
                        │ fecha_envio  │
                        └──────────────┘
```

### 9.2. Tablas y Relaciones

#### Tabla: `usuario`
```sql
CREATE TABLE usuario (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    dni VARCHAR(9) UNIQUE NOT NULL,
    nombre VARCHAR(100) NOT NULL,
    apellidos VARCHAR(200) NOT NULL,
    email VARCHAR(150) UNIQUE NOT NULL,
    telefono VARCHAR(15) NOT NULL,
    password VARCHAR(255) NOT NULL,
    rol ENUM('ADMIN', 'CLIENTE') NOT NULL,
    activo BOOLEAN DEFAULT TRUE,
    fecha_registro TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_email (email),
    INDEX idx_dni (dni)
);
```

#### Tabla: `cortador`
```sql
CREATE TABLE cortador (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    nombre VARCHAR(100) NOT NULL,
    apellidos VARCHAR(200) NOT NULL,
    dni VARCHAR(9) UNIQUE NOT NULL,
    email VARCHAR(150) UNIQUE NOT NULL,
    telefono VARCHAR(15),
    experiencia INT, -- Años de experiencia
    especialidad VARCHAR(100), -- "Jamón", "Paleta", "Embutidos", "Todos"
    activo BOOLEAN DEFAULT TRUE,
    fecha_alta TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_activo (activo)
);
```

#### Tabla: `servicio`
```sql
CREATE TABLE servicio (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    nombre VARCHAR(100) NOT NULL,
    duracion_minutos INT NOT NULL,
    precio DECIMAL(10,2),
    descripcion TEXT,
    activo BOOLEAN DEFAULT TRUE
);

-- Datos iniciales
INSERT INTO servicio (nombre, duracion_minutos, precio, descripcion) VALUES
('Corte de Jamón', 120, 45.00, 'Corte profesional de jamón serrano o ibérico'),
('Corte de Paleta', 60, 25.00, 'Corte profesional de paleta ibérica'),
('Corte de Embutido', 30, 12.00, 'Corte de embutidos variados');
```

#### Tabla: `reserva`
```sql
CREATE TABLE reserva (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    cliente_id BIGINT NOT NULL,
    cortador_id BIGINT NOT NULL,
    servicio_id BIGINT NOT NULL,
    fecha DATE NOT NULL,
    hora_inicio TIME NOT NULL,
    hora_fin TIME NOT NULL,
    estado ENUM('PENDIENTE', 'CONFIRMADA', 'REALIZADA', 'CANCELADA') NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FOREIGN KEY (cliente_id) REFERENCES usuario(id),
    FOREIGN KEY (cortador_id) REFERENCES cortador(id),
    FOREIGN KEY (servicio_id) REFERENCES servicio(id),
    INDEX idx_fecha_estado (fecha, estado),
    INDEX idx_cortador_fecha (cortador_id, fecha),
    INDEX idx_cliente (cliente_id),
    UNIQUE KEY uk_reserva_slot (cortador_id, fecha, hora_inicio, hora_fin)
);
```

#### Tabla: `notificacion`
```sql
CREATE TABLE notificacion (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    usuario_id BIGINT, -- Nullable para cortadores
    reserva_id BIGINT NOT NULL,
    tipo ENUM('NUEVA_RESERVA', 'CANCELACION', 'MODIFICACION') NOT NULL,
    destinatario_email VARCHAR(150) NOT NULL,
    mensaje TEXT NOT NULL,
    leida BOOLEAN DEFAULT FALSE,
    fecha_envio TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (usuario_id) REFERENCES usuario(id) ON DELETE CASCADE,
    FOREIGN KEY (reserva_id) REFERENCES reserva(id) ON DELETE CASCADE,
    INDEX idx_usuario_leida (usuario_id, leida)
);
```

---

## 🖥️ 10. ARQUITECTURA DEL SISTEMA

### 10.1. Arquitectura General (Cliente-Servidor REST)

```
┌─────────────────────────────────────────────────────┐
│              CLIENTE (JavaFX Desktop App)           │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐          │
│  │  Login   │  │ Dashboard│  │ Calendar │          │
│  │  View    │  │   View   │  │   View   │          │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘          │
│       │             │             │                 │
│       └─────────────┴─────────────┘                 │
│                     │                               │
│            ┌────────▼────────┐                      │
│            │  HTTP Client    │                      │
│            │ (RestTemplate)  │                      │
│            └────────┬────────┘                      │
└─────────────────────┼───────────────────────────────┘
                      │ HTTP/JSON (REST)
                      │
┌─────────────────────▼───────────────────────────────┐
│           SERVIDOR (Spring Boot API)                │
│  ┌─────────────────────────────────────────────┐   │
│  │         Controllers (REST Endpoints)        │   │
│  │  /api/auth/login  /api/reservas  /api/...  │   │
│  └───────────────────┬─────────────────────────┘   │
│                      │                             │
│  ┌───────────────────▼─────────────────────────┐   │
│  │            Services (Lógica Negocio)        │   │
│  │  ReservaService  CortadorService  ...       │   │
│  └───────────────────┬─────────────────────────┘   │
│                      │                             │
│  ┌───────────────────▼─────────────────────────┐   │
│  │       Repositories (Spring Data JPA)        │   │
│  │  ReservaRepository  UsuarioRepository  ...  │   │
│  └───────────────────┬─────────────────────────┘   │
│                      │ JPA/Hibernate               │
└──────────────────────┼─────────────────────────────┘
                       │
              ┌────────▼────────┐
              │  MySQL Database │
              └─────────────────┘
```

### 10.2. Capas del Backend (Spring Boot)

**1. Capa de Presentación (Controllers)**
```java
@RestController
@RequestMapping("/api/reservas")
public class ReservaController {
    @PostMapping
    public ResponseEntity<Reserva> crearReserva(@RequestBody ReservaDTO dto) {...}
    
    @GetMapping("/cliente/{clienteId}")
    public List<Reserva> obtenerReservasPorCliente(@PathVariable Long clienteId) {...}
}
```

**2. Capa de Negocio (Services)**
```java
@Service
public class ReservaService {
    public Reserva crearReserva(ReservaDTO dto) {
        // Validar disponibilidad
        // Verificar límites
        // Crear reserva
        // Enviar notificaciones
    }
}
```

**3. Capa de Datos (Repositories)**
```java
public interface ReservaRepository extends JpaRepository<Reserva, Long> {
    List<Reserva> findByClienteIdAndEstado(Long clienteId, EstadoReserva estado);
    
    @Query("SELECT COUNT(r) FROM Reserva r WHERE r.cliente.id = :clienteId " +
           "AND r.fecha = :fecha AND r.estado IN ('CONFIRMADA', 'PENDIENTE')")
    int countReservasDiarias(@Param("clienteId") Long clienteId, 
                             @Param("fecha") LocalDate fecha);
}
```

### 10.3. Estructura Frontend (JavaFX)

```
jamonbooking-frontend/
├── src/main/java/com/jamonbooking/
│   ├── Main.java
│   ├── controllers/
│   │   ├── LoginController.java
│   │   ├── AdminDashboardController.java
│   │   ├── ClienteDashboardController.java
│   │   ├── CalendarioController.java
│   │   └── ReservaFormController.java
│   ├── models/
│   │   ├── Usuario.java
│   │   ├── Reserva.java
│   │   └── DTOs...
│   ├── services/
│   │   ├── ApiClient.java (RestTemplate)
│   │   ├── AuthService.java
│   │   └── ReservaService.java
│   └── utils/
│       ├── SessionManager.java
│       └── Validators.java
└── src/main/resources/
    └── fxml/
        ├── login.fxml
        ├── admin-dashboard.fxml
        ├── calendario.fxml
        └── ...
```

---

## 📱 11. INTERFACES Y VISTAS (JavaFX)

### 11.1. Vistas Principales

#### **V1. Pantalla de Login**
- Campos: Email, Contraseña
- Botones: "Iniciar Sesión", "Registrarse"
- Validación: Credenciales incorrectas → Mensaje de error

#### **V2. Registro de Cliente**
- Campos: DNI, Nombre, Apellidos, Email, Teléfono, Contraseña, Confirmar Contraseña
- Validaciones en tiempo real
- Botón: "Registrarse" → Confirmación → Redirect a Login

#### **V3. Dashboard Admin**
- Menú lateral:
  - Gestión de Cortadores
  - Gestión de Usuarios
  - Todas las Reservas
  - Notificaciones
- Panel central: KPIs (Total cortadores, Reservas hoy, Clientes activos)

#### **V4. Dashboard Cliente**
- Menú superior: Nueva Reserva, Mis Reservas, Mi Perfil, Notificaciones
- Panel central: Próximas reservas (tabla)
- Botones: Ver calendario, Historial completo

#### **V5. Calendario de Disponibilidad** ⭐ CRÍTICA
- DatePicker: Selección de fecha
- ComboBox: Filtro por tipo de servicio
- Tabla/Grid: Muestra cortadores disponibles con slots libres
  ```
  | Cortador   | 10:00 | 10:30 | 11:00 | ... | 17:30 |
  |------------|-------|-------|-------|-----|-------|
  | Juan Pérez | 🟢    | 🔴    | 🔴    | ... | 🟢    |
  | Ana García | 🔴    | 🔴    | 🟢    | ... | 🟢    |
  ```
  🟢 Disponible | 🔴 Ocupado
- Clic en slot verde → Formulario de confirmación

#### **V6. Formulario de Reserva**
- Resumen: Servicio, Cortador, Fecha, Hora
- Botón: "Confirmar Reserva"
- Confirmación → Mensaje éxito + Redirect a Mis Reservas

#### **V7. Mis Reservas (Cliente)**
- Tabla con: Fecha, Hora, Servicio, Cortador, Estado
- Acciones: Modificar, Cancelar (solo futuras con 1 día antelación)
- Filtros: Próximas, Pasadas, Todas

#### **V8. CRUD Cortadores (Admin)**
- Tabla: Lista de cortadores con estado (Activo/Inactivo)
- Botones: Nuevo, Editar, Activar/Desactivar
- Formulario: Nombre, Apellidos, DNI, Email, Teléfono, Experiencia, Especialidad

---

## ⚙️ 12. LÓGICA DE NEGOCIO CRÍTICA

### 12.1. Validación de Disponibilidad
```java
public boolean verificarDisponibilidad(Long cortadorId, LocalDate fecha, 
                                       LocalTime horaInicio, int duracionMinutos) {
    LocalTime horaFin = horaInicio.plusMinutes(duracionMinutos);
    
    // 1. Verificar horario laboral (10:00-18:00)
    if (horaInicio.isBefore(LocalTime.of(10, 0)) || 
        horaFin.isAfter(LocalTime.of(18, 0))) {
        throw new HorarioInvalidoException("Fuera del horario laboral");
    }
    
    // 2. Verificar día laboral (L-V)
    if (fecha.getDayOfWeek() == DayOfWeek.SATURDAY || 
        fecha.getDayOfWeek() == DayOfWeek.SUNDAY) {
        throw new DiaNoLaboralException("No se trabaja fines de semana");
    }
    
    // 3. Verificar solapamientos en BD
    List<Reserva> reservasExistentes = reservaRepository
        .findByCortadorAndFechaAndEstadoIn(cortadorId, fecha, 
            Arrays.asList(EstadoReserva.CONFIRMADA, EstadoReserva.PENDIENTE));
    
    for (Reserva r : reservasExistentes) {
        if (!(horaFin.isBefore(r.getHoraInicio()) || 
              horaInicio.isAfter(r.getHoraFin()))) {
            return false; // Hay solapamiento
        }
    }
    
    return true;
}
```

### 12.2. Control de Límites de Cliente
```java
public void validarLimitesCliente(Long clienteId, LocalDate fecha) {
    // Límite diario: 2 reservas
    int reservasDiarias = reservaRepository.countReservasDiarias(clienteId, fecha);
    if (reservasDiarias >= 2) {
        throw new LimiteReservasException("Máximo 2 reservas por día");
    }
    
    // Límite semanal: 4 reservas
    LocalDate inicioSemana = fecha.with(DayOfWeek.MONDAY);
    LocalDate finSemana = fecha.with(DayOfWeek.FRIDAY);
    int reservasSemanales = reservaRepository
        .countReservasEntreFechas(clienteId, inicioSemana, finSemana);
    if (reservasSemanales >= 4) {
        throw new LimiteReservasException("Máximo 4 reservas por semana");
    }
}
```

### 12.3. Control de Carga de Cortador
```java
public void validarCargaCortador(Long cortadorId, LocalDate fecha, Long servicioId) {
    // Si es jamón (120 min), verificar límite de 3 jamones/día
    Servicio servicio = servicioRepository.findById(servicioId).orElseThrow();
    
    if (servicio.getDuracionMinutos() == 120) { // Jamón
        long jamonesHoy = reservaRepository.countJamonesPorDia(cortadorId, fecha);
        if (jamonesHoy >= 3) {
            throw new LimiteCargaException("El cortador ya tiene 3 jamones asignados hoy");
        }
    }
    
    // Verificar que no exceda 6h de trabajo efectivo
    int minutosOcupados = reservaRepository.sumMinutosReservasDia(cortadorId, fecha);
    if (minutosOcupados + servicio.getDuracionMinutos() > 360) { // 360 min = 6h
        throw new LimiteCargaException("Excede el límite de 6 horas diarias");
    }
}
```

### 12.4. Tarea Programada: Actualizar Reservas Pasadas
```java
@Scheduled(cron = "0 0 1 * * ?") // Diariamente a la 1:00 AM
public void actualizarReservasRealizadas() {
    LocalDateTime ahora = LocalDateTime.now();
    
    List<Reserva> reservasConfirmadas = reservaRepository
        .findByEstado(EstadoReserva.CONFIRMADA);
    
    for (Reserva r : reservasConfirmadas) {
        LocalDateTime fechaHoraFin = LocalDateTime.of(r.getFecha(), r.getHoraFin());
        if (fechaHoraFin.isBefore(ahora)) {
            r.setEstado(EstadoReserva.REALIZADA);
            reservaRepository.save(r);
        }
    }
}
```

---

## 🧪 13. TESTING

### 13.1. Tests Unitarios (JUnit 5)
**Ejemplos de casos de prueba:**

```java
@SpringBootTest
class ReservaServiceTest {
    
    @Test
    void crearReserva_CuandoDisponible_DeberiaTenerExito() {
        // Given
        ReservaDTO dto = new ReservaDTO(clienteId, cortadorId, servicioId, 
                                        LocalDate.now().plusDays(2), 
                                        LocalTime.of(10, 0));
        // When
        Reserva reserva = reservaService.crearReserva(dto);
        
        // Then
        assertNotNull(reserva.getId());
        assertEquals(EstadoReserva.CONFIRMADA, reserva.getEstado());
    }
    
    @Test
    void crearReserva_CuandoExcedeLimiteDiario_DeberiaLanzarExcepcion() {
        // Given: Cliente ya tiene 2 reservas ese día
        // When & Then
        assertThrows(LimiteReservasException.class, () -> {
            reservaService.crearReserva(dto);
        });
    }
    
    @Test
    void verificarDisponibilidad_CuandoHaySolapamiento_DeberiaRetornarFalse() {
        // Test solapamiento de slots
    }
}
```

### 13.2. Tests de Integración
- Probar endpoints completos: `POST /api/reservas`
- Verificar persistencia en BD
- Validar respuestas HTTP correctas

---

## 📄 14. REQUISITOS NO FUNCIONALES

| ID | Requisito | Descripción |
|----|-----------|-------------|
| RNF-01 | **Rendimiento** | Respuesta de API < 2 segundos en operaciones CRUD |
| RNF-02 | **Disponibilidad** | Aplicación disponible 99% del tiempo (sin caídas) |
| RNF-03 | **Seguridad** | Contraseñas encriptadas con BCrypt, sesiones con JWT |
| RNF-04 | **Usabilidad** | Interfaz intuitiva, máximo 3 clics para completar reserva |
| RNF-05 | **Mantenibilidad** | Código con comentarios, arquitectura en capas clara |
| RNF-06 | **Escalabilidad** | Base de datos preparada para > 1000 registros |
| RNF-07 | **Integridad Datos** | Constraints FK en BD, validaciones en backend y frontend |
| RNF-08 | **Idioma** | Solo español (interfaz y mensajes) |
| RNF-09 | **Compatibilidad** | Java 17+, MySQL 8+, JavaFX 17+ |
| RNF-10 | **Manejo Errores** | Excepciones personalizadas, mensajes claros al usuario |

---

## 🚀 15. PLANIFICACIÓN DEL DESARROLLO

### Semana 1-2: Setup y Diseño
- ✅ Configurar proyectos (Spring Boot + JavaFX)
- ✅ Diseñar BD completa + Script SQL
- ✅ Crear diagramas (ER, Casos de Uso, Clases)
- ✅ Mockups con Scene Builder

### Semana 3-4: Backend Core
- 🔧 Entidades JPA + Repositorios
- 🔧 Servicios de negocio (Usuario, Cortador, Reserva)
- 🔧 Controladores REST
- 🔧 Validaciones y excepciones
- 🔧 Tests JUnit básicos

### Semana 5-6: Frontend
- 🎨 Login + Registro (FXML + Controllers)
- 🎨 Dashboard Admin (CRUD Cortadores)
- 🎨 Dashboard Cliente
- 🎨 Calendario interactivo (TableView)
- 🎨 Formulario de reservas
- 🎨 Integración con API (RestTemplate)

### Semana 7: Integración y Testing
- 🔗 Pruebas end-to-end
- 🔗 Corrección de bugs
- 🔗 Sistema de notificaciones (log)
- 🔗 Tarea programada para actualizar estados
- 🔗 Preparar ejecutables

### Semana 8-9: Documentación
- 📝 Memoria completa (30-60 páginas)
- 📝 Manual de instalación
- 📝 Manual de usuario
- 📝 Bibliografía/Webgrafía

### Semana 10: Presentación
- 🎥 PowerPoint (20-25 diapositivas)
- 🎥 Ensayar defensa
- 🎥 Grabar vídeo (15-25 minutos)
- 🎥 Revisión final

**Entrega:** 9 diciembre 2025, 09:59h

---

## 🎯 16. CRITERIOS DE ÉXITO

### Funcionalidades Obligatorias (MVP)
- [x] CRUD de cortadores (Admin)
- [x] Registro automático de clientes
- [x] Login con roles (Admin, Cliente)
- [x] Sistema de reservas con validaciones
- [x] Calendario de disponibilidad visual
- [x] Control de límites (2 diarias, 4 semanales)
- [x] Estados de reserva (4 estados)
- [x] Modificación/cancelación con antelación
- [x] Historial de reservas
- [x] Notificaciones simuladas (log)
- [x] Mínimo 1 cortador activo
- [x] 3 relaciones de BD (Usuario-Reserva-Cortador-Servicio)

### Indicadores de Calidad
- ✅ 0 errores de compilación/ejecución
- ✅ Código limpio (nombres descriptivos, comentarios)
- ✅ API REST funcional (Postman)
- ✅ Interfaz JavaFX navegable sin crashes
- ✅ BD normalizada (3FN)
- ✅ Documentación >= 30 páginas (sin anexos)
- ✅ Vídeo 15-25 minutos sin cortes

---

## 📌 17. VÍAS FUTURAS (Para Memoria)

**Funcionalidades para v2.0:**
1. Sistema de pagos online (Stripe/PayPal)
2. Envío real de emails con plantillas HTML
3. App móvil Android nativa
4. Valoraciones y reseñas de cortadores
5. Chat en tiempo real Admin-Cliente
6. Multi-tienda (varias sucursales)
7. Gestión de inventario de productos
8. Reportes avanzados (PDF/Excel)
9. Panel de estadísticas con gráficos
10. Recordatorios automáticos por email/SMS
11. API pública para integraciones externas
12. Sistema de descuentos y promociones

---

## 📚 18. TECNOLOGÍAS Y JUSTIFICACIÓN (Para Propuesta)

### Backend
- **Java 17**: Lenguaje principal del ciclo, versión LTS con mejoras de rendimiento
- **Spring Boot 3.x**: Framework empresarial líder, simplifica desarrollo de APIs REST
- **Spring Data JPA**: Abstracción sobre Hibernate, reduce código boilerplate
- **Hibernate**: ORM estándar de facto, visto en módulo Acceso a Datos
- **MySQL 8**: SGBD relacional robusto, visto en módulo Bases de Datos
- **Maven**: Gestión de dependencias estándar del ecosistema Java

### Frontend
- **JavaFX 17**: Framework moderno para aplicaciones de escritorio, sucesor de Swing
- **Scene Builder**: Herramienta drag-and-drop para diseñar interfaces FXML
- **RestTemplate**: Cliente HTTP sencillo para consumir APIs REST

### Testing y Herramientas
- **JUnit 5**: Framework estándar para testing en Java
- **IntelliJ IDEA**: IDE profesional con soporte completo para Spring y JavaFX
- **Git/GitHub**: Control de versiones distribuido
- **Postman**: Testing manual de API REST

**Justificación JavaFX:**
> JavaFX se ha seleccionado como framework frontend por ser el sucesor oficial de Swing (incluido en la normativa). Ofrece capacidades modernas de UI (CSS styling, FXML declarativo, animaciones) manteniendo la coherencia tecnológica al usar Java en toda la stack. Scene Builder facilita el diseño visual, acelerando el desarrollo sin sacrificar calidad.

---

## ✅ RESUMEN EJECUTIVO FINAL

**JamonBooking** es un sistema completo de gestión de reservas que demuestra:
- ✅ Dominio de arquitectura Cliente-Servidor REST
- ✅ Uso profesional de Spring Boot + JPA/Hibernate
- ✅ Desarrollo de interfaces modernas con JavaFX
- ✅ Lógica de negocio compleja (validaciones, límites, disponibilidad)
- ✅ Diseño de BD normalizado con 5 entidades y relaciones claras
- ✅ Seguridad (BCrypt, roles, validaciones)
- ✅ Testing automatizado con JUnit

**Complejidad:** Media (perfecta para 1 mes + 15 días)
**Originalidad:** Alta (temática única)
**Demostración:** Excelente (calendario visual, flujo completo funcional)