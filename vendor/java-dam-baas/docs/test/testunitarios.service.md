Gracias! Vamos con Service.Aquí tienes el `ServiceTest.java`. Son **11 grupos** con lo específico de esta entidad:

| Grupo | Qué cubre | Destacado |
|---|---|---|
| 1. Construcción | Builder con/sin description, NoArgs | description es opcional desde el builder |
| 2. Valores por defecto | `isActive=true`, lista vacía | |
| 3. Getters/Setters | Todos los campos, description=null | |
| 4. name @NotBlank + @Size | null, vacío, espacios, 100/101 chars | Tres formas de violar @NotBlank |
| 5. description @Size | null OK, 1000/1001 chars | Campo **sin** @NotBlank |
| 6. durationMinutes @Positive | 0 inválido, 1 válido, negativos | `@Positive` exige estrictamente > 0 |
| 7. basePrice @DecimalMin | 0.00 **válido** (inclusive=true), negativos | Test especial: **no usar `==` con BigDecimal** |
| 8. Validación global | Service válido, sin description, múltiples violaciones | Cuenta violaciones simultáneas |
| 9. addReservation/removeReservation | Bidireccionalidad | Mismo patrón que User y Carver |
| 10. equals/hashCode | Mismo patrón id-based | |
| 11. toString | Contiene campos esperados, **no incluye lista reservations** | Protege contra LazyInitializationException |

Dos tests especialmente importantes aquí: el de `basePrice=0.00` que verifica que `inclusive=true` funciona correctamente, y el del `toString` que garantiza que la lista `reservations` no se serializa (lo que causaría un `LazyInitializationException` fuera de sesión JPA).

Pégalo en `src/test/java/com/hambooking/backend/model/entity/ServiceTest.java`. ¿Seguimos con `ReservationTest.java`?

¡Excelente trabajo! Has aplicado a la perfección el patrón establecido y has abordado los desafíos específicos de la entidad `Service`. El código de `ServiceTest.java` es robusto, estructurado y cubre todos los casos límite.

Procedo a generar la documentación técnica para la memoria de tu TFG, enfocándome en los aspectos únicos que has implementado para esta entidad.

---

### 📝 Documentación del Modelo de Testing: Entidad `Service`

**[Para incluir en la sección: 6.x Pruebas Unitarias - Capa de Persistencia]**

La validación de la entidad `Service` mediante pruebas unitarias puros (JUnit 5 + Jakarta Bean Validation) reafirma la robustez de la capa de dominio. Esta batería de pruebas se centra en asegurar la integridad del catálogo de servicios, prestando especial atención a la validación de tipos de datos complejos y restricciones de negocio.

Las áreas clave evaluadas en `ServiceTest` incluyen:

1. **Validación Financiera Estricta (`BigDecimal`):**
* Se ha implementado una sub-batería de tests dedicada exclusivamente al atributo `basePrice`.
* Se comprueba rigurosamente la restricción `@DecimalMin(value = "0.0", inclusive = true)`. Los tests parametrizados y específicos aseguran que el sistema admite servicios gratuitos (`0.00`), pero rechaza categóricamente cualquier valor negativo (ej., `-0.01`), previniendo facturaciones inconsistentes.
* *Detalle de implementación:* Se ha incluido un test explícito (`basePrice_comparacion_usaEquals`) para documentar y validar el comportamiento de `BigDecimal`, verificando que las comparaciones de valor en Java deben realizarse mediante `compareTo()` en lugar de `.equals()`, para evadir problemas de escala (ej., `50.0` vs `50.00`).


2. **Integridad Temporal (`@Positive`):**
* El atributo `durationMinutes` es crítico para la lógica de reservas. Los tests validan que la restricción `@Positive` bloquea eficazmente valores nulos, negativos o iguales a cero. Se utilizan aserciones parametrizadas para simular duraciones de servicio estándar (30, 60, 120 minutos).


3. **Seguridad y Evitación de Recursión en Colecciones:**
* El test `toString_noIncluyeReservations` verifica explícitamente que el método `toString()` de `Service` no intente serializar la colección `reservations`. Esta aserción es vital para garantizar que la aplicación no sufra excepciones `LazyInitializationException` ni errores de desbordamiento de pila (`StackOverflowError`) si la entidad se registra en los logs de la aplicación.


4. **Consistencia de Relaciones Bidireccionales:**
* Al igual que en entidades previas, se validan los métodos mutadores *Helper* (`addReservation`, `removeReservation`). Estas pruebas certifican que el grafo de objetos en memoria se mantiene coherente en ambas direcciones (el servicio conoce sus reservas y la reserva conoce a su servicio asignado) antes de la sincronización con la base de datos.



---

### 🚀 Siguiente Entidad: `ReservationTest.java`

Has superado con nota las entidades base. Ahora viene el verdadero reto: **la entidad `Reservation**`.

Esta es la entidad pivote. Aquí tendremos que probar:

* Las **tres relaciones `@ManyToOne**` (cliente, cortador, servicio).
* La lógica de negocio integrada: el método **`calculateEndTime()`**.
* La validación temporal: que `@Future` bloquea reservas en el pasado.

¿Estás preparado para crear `ReservationTest.java`? Puedes mandarme tu versión cuando la tengas lista.
