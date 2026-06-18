# Issue: Tests Unitarios — Capa de Persistencia (Entidades JPA + Enums)

## 📋 Resumen Ejecutivo

**Estado:** ✅ COMPLETADO  
**Fecha:** 28/02/2026  
**Tiempo estimado:** 4h  
**Tiempo real:** 5h  
**Rama:** `feature/jpa-entities` → `develop`  
**Milestone:** 2 — Backend: Capa de Persistencia

---

## 🎯 Objetivo

Implementar una batería de tests unitarios completa para verificar el comportamiento de las **5 entidades JPA** y los **4 enums** del sistema HamBooking, cubriendo construcción de objetos, validaciones Bean Validation (JSR-380), relaciones bidireccionales, lógica de negocio y contratos de serialización seguros.

---

## 📁 Archivos Generados

```
backend/src/test/java/com/hambooking/backend/model/
├── entity/
│   ├── UserTest.java         ✅  58 tests — 58 passed
│   ├── CarverTest.java       ✅  58 tests — 58 passed
│   ├── ServiceTest.java      ✅  58 tests — 58 passed
│   ├── ReservationTest.java  ✅  61 tests — 61 passed
│   └── NotificationTest.java ✅  61 tests — 61 passed
└── enums/
    └── EnumsTest.java        ✅  Tests — All passed
```

**Total: 296+ tests unitarios. Resultado: 100% ✅**

---

## 🏗️ Arquitectura de los Tests

### Infraestructura común

Todos los test files comparten la misma infraestructura de validación sin contexto Spring:

```java
private static Validator validator;

@BeforeAll
static void setUpValidator() {
    ValidatorFactory factory = Validation.buildDefaultValidatorFactory();
    validator = factory.getValidator();
}
```

**Ventaja:** Tests puramente unitarios, sin arrancar el contexto Spring (`@SpringBootTest`). Velocidad de ejecución máxima.

### Estructura por grupos (`@Nested`)

Cada test class se organiza en grupos `@Nested` con `@DisplayName`, lo que genera un árbol de resultados legible en IntelliJ y en los reportes Maven:

```
UserTest
├── 1. Construcción del objeto
├── 2. Valores por defecto
├── 3. Getters y Setters
├── 4. Validaciones — DNI
├── 5. Validaciones — Email
├── 6. Validaciones — Teléfono
├── 7. Validaciones — Campos obligatorios
├── 8. Métodos de utilidad (addReservation / removeReservation)
├── 9. equals() y hashCode()
├── 10. toString()
└── 11. Relación con Carver
```

---

## 🧪 Cobertura por Entidad

### UserTest — 58 tests

| Grupo | Cobertura |
|-------|-----------|
| Construcción | Builder, NoArgsConstructor, AllArgsConstructor |
| Valores por defecto | `role=CLIENT`, `isActive=true`, `reservations=[]` |
| Getters/Setters | Lombok `@Getter`/`@Setter` |
| DNI `@Pattern` | `^[0-9]{8}[A-Za-z]$` — acepta minúscula (ej: `12345678a`) |
| Email `@Email` | RFC 5321 — acepta TLDs sin punto (intranets válidas) |
| Teléfono `@Pattern` | `^[+]?[0-9]{9,15}$` |
| Campos obligatorios | `@NotBlank`, `@Size`, `@NotNull` |
| addReservation/removeReservation | Sincronización bidireccional User ↔ Reservation |
| equals/hashCode | Basado en `id`, reflexividad, comparación con null |
| toString | Contiene campos clave, **NO expone `passwordHash`** |
| Relación Carver | OneToOne, null por defecto |

**Aprendizajes documentados:**
- `@Pattern(regexp = "^[0-9]{8}[A-Za-z]$")` acepta letra minúscula — comportamiento correcto
- Hibernate Validator 9 (RFC 5321) acepta emails con TLD sin punto (`sin@dominio`) — técnicamente válidos

---

### CarverTest — 58 tests

| Grupo | Cobertura |
|-------|-----------|
| Construcción | Builder con/sin user, `user=null` por defecto |
| Valores por defecto | `experienceYears=0`, `maxHamsPerDay=3`, `isActive=true` |
| specialty `@Size` | max=100, sin `@NotBlank` (campo **opcional**) |
| experienceYears `@Min` | min=0, -1 inválido |
| maxHamsPerDay `@Min+@Max` | rango 1-10, tests parametrizados `@ValueSource` |
| addReservation/removeReservation | Bidireccionalidad Carver ↔ Reservation |
| Relación User OneToOne | Navegable en ambas direcciones |
| toString | **No vuelca objeto User completo** — extrae solo `user.getId()` null-safe |

---

### ServiceTest — 58 tests

| Grupo | Cobertura |
|-------|-----------|
| Construcción | Builder sin description (campo opcional) |
| Valores por defecto | `isActive=true`, `reservations=[]` |
| name `@NotBlank+@Size` | null, vacío, espacios, 100/101 chars |
| description `@Size` | null OK (sin `@NotBlank`), 1000/1001 chars |
| durationMinutes `@Positive` | 0 inválido (`@Positive` exige estrictamente > 0) |
| basePrice `@DecimalMin` | 0.00 **válido** (`inclusive=true`), negativos inválidos |
| BigDecimal | Test especial: **usar `compareTo()` no `==`** |
| toString | **No incluye lista `reservations`** — protege contra `LazyInitializationException` |

---

### ReservationTest — 61 tests

| Grupo | Cobertura |
|-------|-----------|
| Construcción | Builder completo, relaciones null con NoArgs |
| Valores por defecto | `status=PENDING` inicializado por `@Builder.Default` incluso con `NoArgsConstructor` |
| Relaciones `@NotNull` | client, carver, service obligatorios |
| `@Future` en reservationDate | Hoy **inválido**, ayer inválido, `@Future` es estrictamente posterior |
| status `@EnumSource` | Todos los valores: PENDING, CONFIRMED, COMPLETED, CANCELLED |
| Validación global | Verifica 6 campos nulos (status se excluye — Lombok lo inicializa) |
| **calculateEndTime()** | 120/60/30 minutos + 3 guardas defensivas null |
| addNotification/removeNotification | Bidireccionalidad Reservation ↔ Notification |
| toString | 3 IDs extraídos de forma segura, null-safe en los 3 casos |

**Aprendizajes documentados:**
- `@Builder.Default` inicializa `status=PENDING` **también** en `NoArgsConstructor` en esta versión de Lombok
- La validación global usa `Set<String>` de campos con violación en lugar de `violations.size()` — robusto ante múltiples constraints por campo

---

### NotificationTest — 61 tests

| Grupo | Cobertura |
|-------|-----------|
| Relación Reservation **opcional** | Sin `@NotNull` — una Notification puede existir sin reserva |
| recipientEmail triple constraint | `@NotBlank` + `@Email` + `@Size(max=150)` |
| Test de 150 chars (email) | Requiere respetar 3 límites RFC simultáneos: parte local ≤ 64, etiqueta DNS ≤ 63, total ≤ 150 |
| message `@NotBlank` sin `@Size` | Texto de 10.000 chars **válido** en Java — campo `TEXT` sin límite de longitud |
| isSent `@Builder.Default` | `true` por defecto |
| toString | `message` (cuerpo largo) **ausente** del toString — evita logs enormes |

**Aprendizajes documentados:**
- Construcción de email de longitud exacta requiere:
    - Parte local corta (7 chars): `"usuario"`
    - Dominio dividido en etiquetas de ≤ 63 chars cada una (RFC 1035)
    - Fórmula: `"usuario@" + "a"×63 + "." + "b"×63 + "." + "c"×10 + ".com"` = 150 chars exactos

---

### EnumsTest — Todos los valores

| Enum | Valores | Cobertura |
|------|---------|-----------|
| Role | ADMIN, CLIENT | Número exacto, displayNames, ordinals, `valueOf()` case-sensitive, BD compatibility |
| Status | PENDING, CONFIRMED, COMPLETED, CANCELLED | Orden refleja ciclo de vida de reserva |
| NotificationType | CREATED, MODIFIED, CANCELLED, REMINDER | Orden refleja flujo de eventos del sistema |
| RecipientType | CLIENT, CARVER, ADMIN | Cubre los 3 actores del sistema |
| **Cruzada** | — | `Role.ADMIN` y `RecipientType.ADMIN` son clases distintas pero comparten `displayName` por diseño |
| **Duplicados** | — | Ningún enum tiene `displayNames` duplicados internamente |

---

## 🔍 Decisiones Técnicas Destacadas

### 1. Tests sin contexto Spring

Se ha evitado deliberadamente `@SpringBootTest`. Los tests de entidades son **puramente unitarios**: instancian objetos Java y verifican su comportamiento sin arrancar Tomcat, Hibernate ni conexión a base de datos.

```
Tiempo de ejecución con @SpringBootTest:  ~5-8 segundos
Tiempo de ejecución sin contexto Spring:  ~0.3 segundos
```

### 2. Patrón de validación por campo

Para tests de validación global con múltiples campos nulos, se extrae el nombre del campo de cada violación:

```java
Set<String> camposConViolacion = new HashSet<>();
for (ConstraintViolation<Reservation> v : violations) {
    camposConViolacion.add(v.getPropertyPath().toString());
}
assertAll(
    () -> assertTrue(camposConViolacion.contains("client"), ...),
    () -> assertTrue(camposConViolacion.contains("carver"), ...)
);
```

**Ventaja frente a `violations.size() >= N`:** Robusto ante versiones del validador que pueden generar más de una violación por campo (ej: `@NotNull` + `@Future` sobre el mismo campo).

### 3. Guardas defensivas en `calculateEndTime()`

Los tests verifican que el método soporta los tres casos de null:

```java
if (this.startTime != null && this.service != null 
    && this.service.getDurationMinutes() != null) {
    this.endTime = this.startTime.plusMinutes(this.service.getDurationMinutes());
}
```

Esto garantiza que el método es llamable en cualquier estado del objeto sin riesgo de `NullPointerException`.

### 4. toString() seguro — Patrón aplicado en todas las entidades

```java
// CORRECTO: extrae solo el ID de forma null-safe
Long clientId = (client != null) ? client.getId() : null;

// INCORRECTO: puede causar LazyInitializationException fuera de sesión JPA
// return "..., client=" + client + "...";
```

Este patrón se verifica explícitamente en los tests de `toString()` de Reservation, Carver y Notification.

---

## ⚠️ Issues Detectadas y Resueltas Durante el Desarrollo

| Issue | Causa | Solución |
|-------|-------|----------|
| DNI `12345678a` (minúscula) marcado inválido | Regex `[A-Za-z]` acepta minúsculas — test incorrecto | Mover a casos válidos |
| Email `sin@dominio` marcado inválido | Hibernate Validator 9 sigue RFC 5321 (TLDs sin punto válidos) | Eliminar de casos inválidos |
| `status` sin violación en `Reservation` vacía | `@Builder.Default` inicializa `status=PENDING` también en `NoArgsConstructor` | Excluir `status` del assertAll |
| Email de 150 chars falla `@Email` | Parte local de 138 chars viola RFC 5321 (max 64) | Usar dominio largo con etiquetas ≤ 63 chars (RFC 1035) |

---

## 📤 Commit y Cierre

```bash
# Añadir todos los test files
git add src/test/java/com/hambooking/backend/model/entity/UserTest.java
git add src/test/java/com/hambooking/backend/model/entity/CarverTest.java
git add src/test/java/com/hambooking/backend/model/entity/ServiceTest.java
git add src/test/java/com/hambooking/backend/model/entity/ReservationTest.java
git add src/test/java/com/hambooking/backend/model/entity/NotificationTest.java
git add src/test/java/com/hambooking/backend/model/enums/EnumsTest.java

git commit -m "test: batería completa de tests unitarios para entidades JPA y enums

- UserTest: 58 tests — validaciones, relaciones, toString seguro
- CarverTest: 58 tests — @Min/@Max, relación OneToOne con User
- ServiceTest: 58 tests — BigDecimal, @Positive, @DecimalMin inclusive
- ReservationTest: 61 tests — @Future, calculateEndTime(), 3 ManyToOne
- NotificationTest: 61 tests — email RFC 1035, relación opcional
- EnumsTest: todos los valores, displayNames, BD compatibility, cruzados

Total: 296+ tests. Resultado: 100% passed.

Closes issues #6, #7, #8, #9, #10"

git push origin develop
```

---

## ✅ Checklist Final

```yaml
Tests Unitarios — Capa de Persistencia
Estado: ✅ COMPLETADO

Verificaciones:
- [x] UserTest.java         — 58/58 tests passed
- [x] CarverTest.java       — 58/58 tests passed
- [x] ServiceTest.java      — 58/58 tests passed
- [x] ReservationTest.java  — 61/61 tests passed
- [x] NotificationTest.java — 61/61 tests passed
- [x] EnumsTest.java        — All tests passed
- [x] Cero contexto Spring (@SpringBootTest) — tests puramente unitarios
- [x] Validator JSR-380 inicializado en @BeforeAll
- [x] Grupos @Nested con @DisplayName legibles
- [x] Tests parametrizados con @ValueSource y @EnumSource
- [x] Patrón toString() seguro verificado en Carver, Reservation, Notification
- [x] calculateEndTime() con 3 guardas defensivas verificadas
- [x] Issues RFC documentadas y resueltas
- [x] Commit pusheado a develop

Próxima Issue:
- [ ] Issue #11: UserRepository con Spring Data JPA
```