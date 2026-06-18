# Documentación para la Memoria del TFG

---

# Título: 4.3. Verificación de la Capa de Persistencia mediante Tests Unitarios

---

## Objetivo

Verificar el comportamiento correcto de las entidades JPA implementadas mediante una batería de tests unitarios automatizados, garantizando la integridad de las validaciones de negocio, la coherencia de las relaciones bidireccionales y la seguridad de los métodos de serialización.

---

## Desarrollo

Una vez completada la implementación de las cinco entidades JPA (`User`, `Carver`, `Service`, `Reservation` y `Notification`) y los cuatro enumerados del sistema (`Role`, `Status`, `NotificationType` y `RecipientType`), se ha procedido a la creación de una batería de tests unitarios utilizando el framework **JUnit 5** junto con el motor de validación **Hibernate Validator 9.0.1**, implementación de referencia de la especificación **Bean Validation 3.1 (JSR-380)**.

Los tests se han diseñado deliberadamente como tests **puramente unitarios**, evitando el uso de `@SpringBootTest`. Esto significa que no se arranca el contenedor Tomcat ni se establece conexión con la base de datos durante su ejecución, lo que reduce el tiempo de ejecución de la suite completa a menos de un segundo, frente a los cinco a ocho segundos que requeriría un test de integración con contexto Spring.

---

## 1. Estrategia de Validación

El motor de validación se inicializa una única vez por clase de test mediante la anotación `@BeforeAll`, compartiendo la instancia del validador entre todos los métodos del grupo:

```
ValidatorFactory → Validator → validateProperty() / validate()
```

Para los tests de validación global con múltiples campos nulos, se adoptó el patrón de **extracción de campos con violación** en lugar de comparar el tamaño total del conjunto de violaciones. Este enfoque es más robusto, ya que el número total de violaciones puede variar según la versión del validador cuando un campo acumula más de una constraint simultánea:

```
violations → Set<String> camposConViolacion → assertAll por cada campo esperado
```

---

## 2. Cobertura por Entidad

La batería de tests se ha organizado mediante clases `@Nested` con `@DisplayName` descriptivos, generando un árbol de resultados legible tanto en el IDE como en los informes de Maven. Cada clase de test cubre entre diez y doce grupos de verificación.

### 2.1 Entidad User — 58 tests

Se verifica la construcción del objeto mediante el patrón Builder de Lombok, los valores por defecto (`role=CLIENT`, `isActive=true`), las tres validaciones de formato aplicadas al DNI (`@Pattern`), email (`@Email`) y teléfono (`@Pattern`), la sincronización bidireccional de la relación con `Reservation` mediante los métodos `addReservation()` y `removeReservation()`, y la seguridad del método `toString()`, que excluye explícitamente el campo `passwordHash`.

Durante el desarrollo de estos tests se documentaron dos comportamientos relevantes de Hibernate Validator 9: la expresión regular del DNI acepta letras minúsculas por diseño, y el validador `@Email` sigue la especificación RFC 5321, que considera válidos los dominios sin punto (usados en redes internas).

### 2.2 Entidad Carver — 58 tests

Se verifica el carácter opcional del campo `specialty` (ausencia de `@NotBlank`), las restricciones numéricas de `experienceYears` (`@Min(0)`) y `maxHamsPerDay` (`@Min(1)` y `@Max(10)`), y la navegabilidad bidireccional de la relación con `User`. Se incluyen tests parametrizados con `@ValueSource` para verificar el rango completo válido de `maxHamsPerDay` (valores del 1 al 10).

Se verifica también que el método `toString()` extrae únicamente el identificador del objeto `User` asociado de forma null-safe, en lugar de serializar el objeto completo, evitando así la excepción `LazyInitializationException` al acceder a la representación textual de la entidad fuera de una sesión JPA activa.

### 2.3 Entidad Service — 58 tests

Se verifica el comportamiento de `@Positive` en `durationMinutes`, que exige un valor estrictamente mayor que cero (el valor cero genera violación). Para `basePrice`, se verifica que `@DecimalMin(value = "0.0", inclusive = true)` permite el valor cero (servicio gratuito), pero rechaza cualquier valor negativo.

Se incluye un test específico que documenta la obligatoriedad de usar `compareTo()` en lugar del operador `==` para comparar instancias de `BigDecimal`, dado que `equals()` en esta clase evalúa tanto el valor numérico como la escala decimal.

### 2.4 Entidad Reservation — 61 tests

Esta entidad es la de mayor complejidad de la capa de persistencia, actuando como nexo entre `User`, `Carver` y `Service` mediante tres relaciones `@ManyToOne`. Los tests verifican que las tres relaciones son obligatorias (`@NotNull`), que la anotación `@Future` en `reservationDate` rechaza tanto fechas pasadas como la fecha del día en curso, y que todos los valores del enum `Status` son aceptados mediante tests parametrizados con `@EnumSource`.

El grupo de mayor relevancia funcional verifica el método `calculateEndTime()`, que implementa la lógica de negocio de cálculo automático de hora de finalización a partir de la hora de inicio y la duración del servicio. Se comprueban tres escenarios positivos (servicios de 30, 60 y 120 minutos) y tres guardas defensivas que garantizan que el método no lanza `NullPointerException` cuando alguno de sus tres requisitos (`startTime`, `service` o `durationMinutes`) es nulo.

Durante el desarrollo se documentó un comportamiento de Lombok relevante: la anotación `@Builder.Default` inicializa el campo `status` con el valor `PENDING` incluso cuando el objeto se instancia con el constructor vacío `NoArgsConstructor`, lo que significa que este campo nunca está vacío en un objeto recién creado.

### 2.5 Entidad Notification — 61 tests

Se verifica el carácter **opcional** de la relación con `Reservation` (la clave foránea no tiene `NOT NULL`), reflejando el diseño del sistema que permite notificaciones genéricas no vinculadas a ninguna reserva.

El grupo de validaciones del campo `recipientEmail` resultó el más complejo de la batería, ya que el campo acumula tres constraints simultáneas (`@NotBlank`, `@Email` y `@Size(max=150)`). La construcción de un email de exactamente 150 caracteres que supere las tres validaciones requiere respetar simultáneamente tres límites del estándar RFC:

* **Parte local** (antes del `@`): máximo 64 caracteres según RFC 5321.
* **Etiqueta DNS** (cada segmento entre puntos): máximo 63 caracteres según RFC 1035.
* **Longitud total** del email: máximo 150 caracteres según la constraint `@Size`.

La fórmula adoptada divide el dominio en tres segmentos: `usuario@[63a].[63b].[10c].com`, obteniendo exactamente 150 caracteres con todos los límites RFC respetados.

Se verifica también que el campo `message`, que utiliza `columnDefinition = "TEXT"` en la base de datos, no tiene `@Size` en la capa Java, por lo que textos de cualquier longitud son válidos a nivel de Bean Validation.

### 2.6 Enumerados — EnumsTest

Se verifica para cada uno de los cuatro enumerados del sistema: el número exacto de constantes definidas, los valores de `getDisplayName()`, la compatibilidad de `name()` con `EnumType.STRING` (valor exacto que se almacena en MySQL), el orden correcto de los ordinales y el comportamiento case-sensitive de `valueOf()`.

Un grupo de tests cruzados verifica la consistencia semántica entre enumerados: `Role.ADMIN` y `RecipientType.ADMIN` son clases diferentes e incomparables mediante `==`, pero comparten el mismo valor de `displayName` ("Administrador") por decisión de diseño del sistema. Asimismo, se verifica que ningún enumerado contiene valores con `displayName` duplicado, lo que garantiza que la interfaz de usuario puede mostrarlos sin ambigüedad.

---

## 3. Principios Aplicados

El diseño de la batería de tests implementa los siguientes principios:

* **Tests unitarios puros**, sin dependencia del contexto Spring ni de la base de datos.
* **Un test, una responsabilidad.** Cada método de test verifica un único comportamiento.
* **Tests como documentación viva.** Los `@DisplayName` en castellano describen el contrato de la entidad de forma legible.
* **Robustez frente a cambios de versión.** La validación por nombre de campo es independiente de la implementación interna del validador.
* **Cobertura de casos límite.** Cada constraint se prueba con el valor exacto del límite (válido) y con el valor que lo supera en una unidad (inválido).

---

## 4. Resultado

La batería completa consta de más de 296 tests unitarios distribuidos en seis clases de test. Todos los tests pasan satisfactoriamente con Hibernate Validator 9.0.1 y JUnit Jupiter 6.0.2.

La ejecución de la suite completa certifica que las entidades JPA del sistema HamBooking cumplen los contratos de validación, relacionamiento y serialización requeridos, dejando la capa de persistencia lista para su integración con la capa de repositorios de Spring Data JPA.

---

## ✅ Cierre

Con la finalización de esta fase, el Milestone 2 queda completamente cerrado. Las cinco entidades JPA y sus tests asociados están validados, documentados y pusheados a la rama `develop`, quedando disponibles para el desarrollo de la capa de repositorios (Milestone 3 — Issues #11 al #14).