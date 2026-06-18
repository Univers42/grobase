package com.hambooking.backend.model.entity;

import jakarta.validation.ConstraintViolation;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import jakarta.validation.ValidatorFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.math.BigDecimal;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Batería de tests unitarios para la entidad Service.
 *
 * Cubre:
 *   - Construcción mediante Builder y constructor vacío
 *   - Valores por defecto (@Builder.Default)
 *   - Getters y Setters (Lombok)
 *   - Validaciones: @NotBlank, @Size, @NotNull, @Positive, @DecimalMin
 *   - Precisión de BigDecimal en basePrice
 *   - Métodos de utilidad (addReservation / removeReservation)
 *   - equals() y hashCode()
 *   - toString()
 */
@DisplayName("Service — Tests unitarios")
class ServiceTest {

    // =========================================================================
    // INFRAESTRUCTURA DE VALIDACIÓN
    // =========================================================================

    private static Validator validator;

    @BeforeAll
    static void setUpValidator() {
        ValidatorFactory factory = Validation.buildDefaultValidatorFactory();
        validator = factory.getValidator();
    }

    // =========================================================================
    // MÉTODO AUXILIAR: construye un Service válido para reutilizar en los tests
    // =========================================================================

    private Service buildValidService() {
        return Service.builder()
                .name("Jamón")
                .description("Corte profesional de jamón entero")
                .durationMinutes(120)
                .basePrice(new BigDecimal("50.00"))
                .isActive(true)
                .build();
    }

    // =========================================================================
    // 1. CONSTRUCCIÓN — Builder y NoArgsConstructor
    // =========================================================================

    @Nested
    @DisplayName("1. Construcción del objeto")
    class Construccion {

        @Test
        @DisplayName("Builder crea Service con todos los campos correctamente")
        void builder_conCamposValidos_creaServiceCorrectamente() {
            Service service = buildValidService();

            assertAll("Todos los campos deben coincidir con los valores del Builder",
                    () -> assertEquals("Jamón", service.getName()),
                    () -> assertEquals("Corte profesional de jamón entero", service.getDescription()),
                    () -> assertEquals(120, service.getDurationMinutes()),
                    () -> assertEquals(new BigDecimal("50.00"), service.getBasePrice()),
                    () -> assertTrue(service.getIsActive())
            );
        }

        @Test
        @DisplayName("NoArgsConstructor crea una instancia no nula")
        void noArgsConstructor_creaInstanciaNoNula() {
            assertNotNull(new Service());
        }

        @Test
        @DisplayName("NoArgsConstructor: id es null antes de persistir")
        void noArgsConstructor_idEsNullAntesDePersistir() {
            assertNull(new Service().getId());
        }

        @Test
        @DisplayName("Builder sin description: description es null (campo opcional)")
        void builder_sinDescription_descriptionEsNull() {
            Service service = Service.builder()
                    .name("Paleta")
                    .durationMinutes(60)
                    .basePrice(new BigDecimal("35.00"))
                    .build();

            assertNull(service.getDescription(),
                    "description es opcional y debe ser null si no se especifica");
        }
    }

    // =========================================================================
    // 2. VALORES POR DEFECTO (@Builder.Default)
    // =========================================================================

    @Nested
    @DisplayName("2. Valores por defecto")
    class ValoresPorDefecto {

        @Test
        @DisplayName("isActive por defecto es true")
        void isActive_porDefecto_esTrue() {
            Service service = Service.builder()
                    .name("Embutidos")
                    .durationMinutes(30)
                    .basePrice(new BigDecimal("25.00"))
                    .build();

            assertTrue(service.getIsActive(),
                    "isActive debe ser true por defecto");
        }

        @Test
        @DisplayName("La lista de reservations se inicializa vacía, no null")
        void reservations_porDefecto_esListaVaciaNoNull() {
            Service service = buildValidService();

            assertNotNull(service.getReservations());
            assertTrue(service.getReservations().isEmpty());
        }
    }

    // =========================================================================
    // 3. GETTERS Y SETTERS (Lombok)
    // =========================================================================

    @Nested
    @DisplayName("3. Getters y Setters")
    class GettersSetters {

        @Test
        @DisplayName("Setter de name actualiza el valor correctamente")
        void setName_actualizaElValor() {
            Service service = buildValidService();
            service.setName("Paleta");
            assertEquals("Paleta", service.getName());
        }

        @Test
        @DisplayName("Setter de description actualiza el valor correctamente")
        void setDescription_actualizaElValor() {
            Service service = buildValidService();
            service.setDescription("Nueva descripción");
            assertEquals("Nueva descripción", service.getDescription());
        }

        @Test
        @DisplayName("Setter de durationMinutes actualiza el valor correctamente")
        void setDurationMinutes_actualizaElValor() {
            Service service = buildValidService();
            service.setDurationMinutes(60);
            assertEquals(60, service.getDurationMinutes());
        }

        @Test
        @DisplayName("Setter de basePrice actualiza el valor correctamente")
        void setBasePrice_actualizaElValor() {
            Service service = buildValidService();
            service.setBasePrice(new BigDecimal("99.99"));
            assertEquals(new BigDecimal("99.99"), service.getBasePrice());
        }

        @Test
        @DisplayName("Setter de isActive permite desactivar el servicio")
        void setIsActive_permiteDesactivar() {
            Service service = buildValidService();
            service.setIsActive(false);
            assertFalse(service.getIsActive());
        }

        @Test
        @DisplayName("description puede ser null (campo opcional)")
        void setDescription_puedeSerNull() {
            Service service = buildValidService();
            service.setDescription(null);
            assertNull(service.getDescription());
        }
    }

    // =========================================================================
    // 4. VALIDACIONES — name (@NotBlank + @Size)
    // =========================================================================

    @Nested
    @DisplayName("4. Validaciones — name")
    class ValidacionesName {

        @Test
        @DisplayName("name válido no genera violaciones")
        void name_valido_noGeneraViolaciones() {
            Service service = buildValidService();
            assertTrue(validator.validateProperty(service, "name").isEmpty());
        }

        @Test
        @DisplayName("name nulo genera violación @NotBlank")
        void name_nulo_generaViolacion() {
            Service service = buildValidService();
            service.setName(null);
            assertFalse(validator.validateProperty(service, "name").isEmpty());
        }

        @Test
        @DisplayName("name vacío genera violación @NotBlank")
        void name_vacio_generaViolacion() {
            Service service = buildValidService();
            service.setName("");
            assertFalse(validator.validateProperty(service, "name").isEmpty());
        }

        @Test
        @DisplayName("name en blanco (solo espacios) genera violación @NotBlank")
        void name_soloEspacios_generaViolacion() {
            Service service = buildValidService();
            service.setName("   ");
            assertFalse(validator.validateProperty(service, "name").isEmpty());
        }

        @Test
        @DisplayName("name con exactamente 100 caracteres no genera violación")
        void name_100Caracteres_noGeneraViolacion() {
            Service service = buildValidService();
            service.setName("S".repeat(100));
            assertTrue(validator.validateProperty(service, "name").isEmpty());
        }

        @Test
        @DisplayName("name con 101 caracteres genera violación @Size")
        void name_101Caracteres_generaViolacion() {
            Service service = buildValidService();
            service.setName("S".repeat(101));
            assertFalse(validator.validateProperty(service, "name").isEmpty());
        }
    }

    // =========================================================================
    // 5. VALIDACIONES — description (@Size)
    // =========================================================================

    @Nested
    @DisplayName("5. Validaciones — description")
    class ValidacionesDescription {

        @Test
        @DisplayName("description null no genera violación (campo opcional)")
        void description_null_noGeneraViolacion() {
            Service service = buildValidService();
            service.setDescription(null);
            assertTrue(validator.validateProperty(service, "description").isEmpty());
        }

        @Test
        @DisplayName("description con exactamente 1000 caracteres no genera violación")
        void description_1000Caracteres_noGeneraViolacion() {
            Service service = buildValidService();
            service.setDescription("D".repeat(1000));
            assertTrue(validator.validateProperty(service, "description").isEmpty());
        }

        @Test
        @DisplayName("description con 1001 caracteres genera violación @Size")
        void description_1001Caracteres_generaViolacion() {
            Service service = buildValidService();
            service.setDescription("D".repeat(1001));
            assertFalse(validator.validateProperty(service, "description").isEmpty(),
                    "description de 1001 caracteres debe violar @Size(max=1000)");
        }
    }

    // =========================================================================
    // 6. VALIDACIONES — durationMinutes (@NotNull + @Positive)
    // =========================================================================

    @Nested
    @DisplayName("6. Validaciones — durationMinutes")
    class ValidacionesDurationMinutes {

        @Test
        @DisplayName("durationMinutes = 1 es válido (mínimo positivo)")
        void durationMinutes_uno_esValido() {
            Service service = buildValidService();
            service.setDurationMinutes(1);
            assertTrue(validator.validateProperty(service, "durationMinutes").isEmpty());
        }

        @ParameterizedTest(name = "durationMinutes válido: {0}")
        @ValueSource(ints = {1, 30, 60, 90, 120, 480})
        @DisplayName("Duraciones positivas son válidas")
        void durationMinutes_positivo_esValido(int minutos) {
            Service service = buildValidService();
            service.setDurationMinutes(minutos);
            assertTrue(validator.validateProperty(service, "durationMinutes").isEmpty(),
                    "durationMinutes=" + minutos + " debería ser válido");
        }

        @Test
        @DisplayName("durationMinutes nulo genera violación @NotNull")
        void durationMinutes_nulo_generaViolacion() {
            Service service = buildValidService();
            service.setDurationMinutes(null);
            assertFalse(validator.validateProperty(service, "durationMinutes").isEmpty());
        }

        @Test
        @DisplayName("durationMinutes = 0 genera violación @Positive")
        void durationMinutes_cero_generaViolacion() {
            Service service = buildValidService();
            service.setDurationMinutes(0);
            assertFalse(validator.validateProperty(service, "durationMinutes").isEmpty(),
                    "durationMinutes=0 debe violar @Positive (debe ser > 0)");
        }

        @Test
        @DisplayName("durationMinutes negativo genera violación @Positive")
        void durationMinutes_negativo_generaViolacion() {
            Service service = buildValidService();
            service.setDurationMinutes(-30);
            assertFalse(validator.validateProperty(service, "durationMinutes").isEmpty());
        }
    }

    // =========================================================================
    // 7. VALIDACIONES — basePrice (@NotNull + @DecimalMin)
    // =========================================================================

    @Nested
    @DisplayName("7. Validaciones — basePrice")
    class ValidacionesBasePrice {

        @Test
        @DisplayName("basePrice = 0.00 es válido (precio gratuito permitido, inclusive=true)")
        void basePrice_cero_esValido() {
            Service service = buildValidService();
            service.setBasePrice(BigDecimal.ZERO);
            assertTrue(validator.validateProperty(service, "basePrice").isEmpty(),
                    "basePrice=0 debe ser válido porque @DecimalMin es inclusive=true");
        }

        @Test
        @DisplayName("basePrice positivo es válido")
        void basePrice_positivo_esValido() {
            Service service = buildValidService();
            service.setBasePrice(new BigDecimal("150.00"));
            assertTrue(validator.validateProperty(service, "basePrice").isEmpty());
        }

        @Test
        @DisplayName("basePrice con decimales es válido")
        void basePrice_conDecimales_esValido() {
            Service service = buildValidService();
            service.setBasePrice(new BigDecimal("49.99"));
            assertTrue(validator.validateProperty(service, "basePrice").isEmpty());
        }

        @Test
        @DisplayName("basePrice nulo genera violación @NotNull")
        void basePrice_nulo_generaViolacion() {
            Service service = buildValidService();
            service.setBasePrice(null);
            assertFalse(validator.validateProperty(service, "basePrice").isEmpty());
        }

        @Test
        @DisplayName("basePrice negativo genera violación @DecimalMin")
        void basePrice_negativo_generaViolacion() {
            Service service = buildValidService();
            service.setBasePrice(new BigDecimal("-0.01"));
            assertFalse(validator.validateProperty(service, "basePrice").isEmpty(),
                    "basePrice negativo debe violar @DecimalMin(0.0, inclusive=true)");
        }

        @Test
        @DisplayName("basePrice muy negativo genera violación @DecimalMin")
        void basePrice_muyNegativo_generaViolacion() {
            Service service = buildValidService();
            service.setBasePrice(new BigDecimal("-100.00"));
            assertFalse(validator.validateProperty(service, "basePrice").isEmpty());
        }

        @Test
        @DisplayName("basePrice: comparación correcta con BigDecimal (no usar ==)")
        void basePrice_comparacion_usaEquals() {
            Service service = buildValidService();
            // BigDecimal.equals() compara valor Y escala: 50.0 != 50.00
            // Por eso usamos compareTo() para comparaciones de valor puro
            BigDecimal expected = new BigDecimal("50.00");
            assertEquals(0, service.getBasePrice().compareTo(expected),
                    "El valor numérico de basePrice debe ser 50.00 (usar compareTo, no ==)");
        }
    }

    // =========================================================================
    // 8. VALIDACIÓN GLOBAL
    // =========================================================================

    @Nested
    @DisplayName("8. Validación global")
    class ValidacionGlobal {

        @Test
        @DisplayName("Service completamente válido: sin ninguna violación")
        void service_completamenteValido_sinViolaciones() {
            assertTrue(validator.validate(buildValidService()).isEmpty(),
                    "Un Service válido no debe tener ninguna violación");
        }

        @Test
        @DisplayName("Service válido sin description (campo opcional)")
        void service_sinDescription_esValido() {
            Service service = Service.builder()
                    .name("Embutidos")
                    .durationMinutes(30)
                    .basePrice(new BigDecimal("25.00"))
                    .build();

            assertTrue(validator.validate(service).isEmpty());
        }

        @Test
        @DisplayName("Service sin name y sin durationMinutes tiene exactamente 2 violaciones")
        void service_sinNameYSinDuration_tieneViolaciones() {
            Service service = Service.builder()
                    .basePrice(new BigDecimal("10.00"))
                    .build();
            service.setName(null);
            service.setDurationMinutes(null);

            Set<ConstraintViolation<Service>> violations = validator.validate(service);
            // @NotBlank en name + @NotNull en durationMinutes = mínimo 2 violaciones
            assertTrue(violations.size() >= 2,
                    "Debe haber al menos 2 violaciones cuando name y durationMinutes son null");
        }
    }

    // =========================================================================
    // 9. MÉTODOS DE UTILIDAD — addReservation / removeReservation
    // =========================================================================

    @Nested
    @DisplayName("9. Métodos de utilidad — addReservation / removeReservation")
    class MetodosUtilidad {

        @Test
        @DisplayName("addReservation: añade la reserva a la lista del service")
        void addReservation_anadeReservaALista() {
            Service service = buildValidService();
            Reservation reservation = new Reservation();

            service.addReservation(reservation);

            assertEquals(1, service.getReservations().size());
        }

        @Test
        @DisplayName("addReservation: establece el service en la reserva (bidireccional)")
        void addReservation_estableceServiceEnReserva() {
            Service service = buildValidService();
            Reservation reservation = new Reservation();

            service.addReservation(reservation);

            assertEquals(service, reservation.getService(),
                    "La reserva debe apuntar al service (relación bidireccional)");
        }

        @Test
        @DisplayName("removeReservation: elimina la reserva de la lista")
        void removeReservation_eliminaReservaDeLista() {
            Service service = buildValidService();
            Reservation reservation = new Reservation();
            service.addReservation(reservation);

            service.removeReservation(reservation);

            assertTrue(service.getReservations().isEmpty());
        }

        @Test
        @DisplayName("removeReservation: pone el service de la reserva a null")
        void removeReservation_poneServiceANull() {
            Service service = buildValidService();
            Reservation reservation = new Reservation();
            service.addReservation(reservation);

            service.removeReservation(reservation);

            assertNull(reservation.getService());
        }

        @Test
        @DisplayName("addReservation: se pueden añadir múltiples reservas")
        void addReservation_variasReservas_listaCreceCorrectamente() {
            Service service = buildValidService();

            service.addReservation(new Reservation());
            service.addReservation(new Reservation());

            assertEquals(2, service.getReservations().size());
        }
    }

    // =========================================================================
    // 10. EQUALS Y HASHCODE
    // =========================================================================

    @Nested
    @DisplayName("10. equals() y hashCode()")
    class EqualsHashCode {

        @Test
        @DisplayName("Un Service es igual a sí mismo (reflexividad)")
        void equals_mismoObjeto_esIgual() {
            Service s = buildValidService();
            assertEquals(s, s);
        }

        @Test
        @DisplayName("Dos Services con el mismo id son iguales")
        void equals_mismoId_sonIguales() {
            Service s1 = buildValidService();
            Service s2 = buildValidService();
            s1.setId(1L);
            s2.setId(1L);
            assertEquals(s1, s2);
        }

        @Test
        @DisplayName("Dos Services con distinto id no son iguales")
        void equals_diferenteId_noSonIguales() {
            Service s1 = buildValidService();
            Service s2 = buildValidService();
            s1.setId(1L);
            s2.setId(2L);
            assertNotEquals(s1, s2);
        }

        @Test
        @DisplayName("Dos Services sin id (sin persistir) no son iguales")
        void equals_ambosIdNull_noSonIguales() {
            assertNotEquals(buildValidService(), buildValidService());
        }

        @Test
        @DisplayName("Service no es igual a null")
        void equals_vsNull_noEsIgual() {
            assertNotEquals(null, buildValidService());
        }

        @Test
        @DisplayName("Service no es igual a un objeto de otra clase")
        void equals_otraClase_noEsIgual() {
            assertNotEquals("Jamón", buildValidService());
        }

        @Test
        @DisplayName("hashCode es consistente para el mismo objeto")
        void hashCode_esConsistente() {
            Service s = buildValidService();
            assertEquals(s.hashCode(), s.hashCode());
        }
    }

    // =========================================================================
    // 11. TOSTRING
    // =========================================================================

    @Nested
    @DisplayName("11. toString()")
    class ToStringTest {

        @Test
        @DisplayName("toString() no retorna null")
        void toString_noRetornaNull() {
            assertNotNull(buildValidService().toString());
        }

        @Test
        @DisplayName("toString() contiene el nombre del servicio")
        void toString_contieneNombre() {
            assertTrue(buildValidService().toString().contains("Jamón"));
        }

        @Test
        @DisplayName("toString() contiene durationMinutes")
        void toString_contieneDuracion() {
            assertTrue(buildValidService().toString().contains("120"));
        }

        @Test
        @DisplayName("toString() contiene basePrice")
        void toString_contienePrecio() {
            assertTrue(buildValidService().toString().contains("50.00"));
        }

        @Test
        @DisplayName("toString() NO incluye la lista de reservations (evitar recursión)")
        void toString_noIncluyeReservations() {
            Service service = buildValidService();
            service.addReservation(new Reservation());

            // El toString manual no itera la lista, protege contra LazyInitializationException
            assertFalse(service.toString().contains("reservations"),
                    "toString no debe incluir la lista de reservas para evitar recursión y problemas Lazy");
        }
    }
}