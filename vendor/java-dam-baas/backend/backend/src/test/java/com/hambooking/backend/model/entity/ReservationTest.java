package com.hambooking.backend.model.entity;

import com.hambooking.backend.model.enums.Role;
import com.hambooking.backend.model.enums.Status;
import jakarta.validation.ConstraintViolation;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import jakarta.validation.ValidatorFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.LocalTime;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Batería de tests unitarios para la entidad Reservation.
 *
 * Cubre:
 *   - Construcción mediante Builder y constructor vacío
 *   - Valores por defecto (@Builder.Default)
 *   - Getters y Setters (Lombok)
 *   - Validaciones: @NotNull en client/carver/service/fechas, @Future en reservationDate
 *   - Lógica de negocio: calculateEndTime()
 *   - Métodos de utilidad: addNotification / removeNotification
 *   - Relaciones ManyToOne con User, Carver y Service
 *   - equals() y hashCode()
 *   - toString() (extracción segura de IDs, sin volcar entidades completas)
 */
@DisplayName("Reservation — Tests unitarios")
class ReservationTest {

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
    // MÉTODOS AUXILIARES
    // =========================================================================

    private User buildValidUser() {
        return User.builder()
                .dni("12345678A")
                .firstName("Juan")
                .lastName("García")
                .email("juan@example.com")
                .phone("612345678")
                .passwordHash("$2a$10$hash")
                .role(Role.CLIENT)
                .build();
    }

    private Carver buildValidCarver() {
        return Carver.builder()
                .specialty("Jamón")
                .experienceYears(5)
                .maxHamsPerDay(3)
                .isActive(true)
                .build();
    }

    private Service buildValidService() {
        return Service.builder()
                .name("Jamón")
                .durationMinutes(120)
                .basePrice(new BigDecimal("50.00"))
                .build();
    }

    /** Reserva completamente válida con todas las relaciones y fecha futura */
    private Reservation buildValidReservation() {
        return Reservation.builder()
                .client(buildValidUser())
                .carver(buildValidCarver())
                .service(buildValidService())
                .reservationDate(LocalDate.now().plusDays(3))
                .startTime(LocalTime.of(10, 0))
                .endTime(LocalTime.of(12, 0))
                .status(Status.PENDING)
                .build();
    }

    // =========================================================================
    // 1. CONSTRUCCIÓN — Builder y NoArgsConstructor
    // =========================================================================

    @Nested
    @DisplayName("1. Construcción del objeto")
    class Construccion {

        @Test
        @DisplayName("Builder crea Reservation con todos los campos correctamente")
        void builder_conCamposValidos_creaReservationCorrectamente() {
            Reservation r = buildValidReservation();

            assertAll("Todos los campos deben coincidir con los valores del Builder",
                    () -> assertNotNull(r.getClient()),
                    () -> assertNotNull(r.getCarver()),
                    () -> assertNotNull(r.getService()),
                    () -> assertEquals(LocalDate.now().plusDays(3), r.getReservationDate()),
                    () -> assertEquals(LocalTime.of(10, 0), r.getStartTime()),
                    () -> assertEquals(LocalTime.of(12, 0), r.getEndTime()),
                    () -> assertEquals(Status.PENDING, r.getStatus())
            );
        }

        @Test
        @DisplayName("NoArgsConstructor crea una instancia no nula")
        void noArgsConstructor_creaInstanciaNoNula() {
            assertNotNull(new Reservation());
        }

        @Test
        @DisplayName("NoArgsConstructor: id es null antes de persistir")
        void noArgsConstructor_idEsNullAntesDePersistir() {
            assertNull(new Reservation().getId());
        }

        @Test
        @DisplayName("NoArgsConstructor: client, carver y service son null por defecto")
        void noArgsConstructor_relacionesSonNullPorDefecto() {
            Reservation r = new Reservation();
            assertAll(
                    () -> assertNull(r.getClient()),
                    () -> assertNull(r.getCarver()),
                    () -> assertNull(r.getService())
            );
        }
    }

    // =========================================================================
    // 2. VALORES POR DEFECTO (@Builder.Default)
    // =========================================================================

    @Nested
    @DisplayName("2. Valores por defecto")
    class ValoresPorDefecto {

        @Test
        @DisplayName("status por defecto es PENDING cuando no se especifica")
        void status_porDefecto_esPending() {
            Reservation r = Reservation.builder()
                    .client(buildValidUser())
                    .carver(buildValidCarver())
                    .service(buildValidService())
                    .reservationDate(LocalDate.now().plusDays(1))
                    .startTime(LocalTime.of(10, 0))
                    .endTime(LocalTime.of(12, 0))
                    .build();

            assertEquals(Status.PENDING, r.getStatus(),
                    "El estado por defecto debe ser PENDING");
        }

        @Test
        @DisplayName("La lista de notifications se inicializa vacía, no null")
        void notifications_porDefecto_esListaVaciaNoNull() {
            Reservation r = buildValidReservation();
            assertNotNull(r.getNotifications());
            assertTrue(r.getNotifications().isEmpty());
        }

        @Test
        @DisplayName("notes es null por defecto (campo opcional)")
        void notes_porDefecto_esNull() {
            assertNull(buildValidReservation().getNotes());
        }
    }

    // =========================================================================
    // 3. GETTERS Y SETTERS (Lombok)
    // =========================================================================

    @Nested
    @DisplayName("3. Getters y Setters")
    class GettersSetters {

        @Test
        @DisplayName("Setter de status actualiza el valor correctamente")
        void setStatus_actualizaElValor() {
            Reservation r = buildValidReservation();
            r.setStatus(Status.CONFIRMED);
            assertEquals(Status.CONFIRMED, r.getStatus());
        }

        @Test
        @DisplayName("Setter de reservationDate actualiza el valor correctamente")
        void setReservationDate_actualizaElValor() {
            Reservation r = buildValidReservation();
            LocalDate nuevaFecha = LocalDate.now().plusDays(10);
            r.setReservationDate(nuevaFecha);
            assertEquals(nuevaFecha, r.getReservationDate());
        }

        @Test
        @DisplayName("Setter de startTime actualiza el valor correctamente")
        void setStartTime_actualizaElValor() {
            Reservation r = buildValidReservation();
            r.setStartTime(LocalTime.of(14, 30));
            assertEquals(LocalTime.of(14, 30), r.getStartTime());
        }

        @Test
        @DisplayName("Setter de endTime actualiza el valor correctamente")
        void setEndTime_actualizaElValor() {
            Reservation r = buildValidReservation();
            r.setEndTime(LocalTime.of(16, 0));
            assertEquals(LocalTime.of(16, 0), r.getEndTime());
        }

        @Test
        @DisplayName("Setter de notes actualiza el valor correctamente")
        void setNotes_actualizaElValor() {
            Reservation r = buildValidReservation();
            r.setNotes("Sin gluten por favor");
            assertEquals("Sin gluten por favor", r.getNotes());
        }

        @Test
        @DisplayName("Setter de client actualiza la relación")
        void setClient_actualizaRelacion() {
            Reservation r = buildValidReservation();
            User nuevoCliente = buildValidUser();
            nuevoCliente.setFirstName("Nuevo");
            r.setClient(nuevoCliente);
            assertEquals("Nuevo", r.getClient().getFirstName());
        }
    }

    // =========================================================================
    // 4. VALIDACIONES — Relaciones obligatorias (@NotNull)
    // =========================================================================

    @Nested
    @DisplayName("4. Validaciones — Relaciones ManyToOne obligatorias")
    class ValidacionesRelaciones {

        @Test
        @DisplayName("client nulo genera violación @NotNull")
        void client_nulo_generaViolacion() {
            Reservation r = buildValidReservation();
            r.setClient(null);
            assertFalse(validator.validateProperty(r, "client").isEmpty(),
                    "client nulo debe violar @NotNull");
        }

        @Test
        @DisplayName("carver nulo genera violación @NotNull")
        void carver_nulo_generaViolacion() {
            Reservation r = buildValidReservation();
            r.setCarver(null);
            assertFalse(validator.validateProperty(r, "carver").isEmpty(),
                    "carver nulo debe violar @NotNull");
        }

        @Test
        @DisplayName("service nulo genera violación @NotNull")
        void service_nulo_generaViolacion() {
            Reservation r = buildValidReservation();
            r.setService(null);
            assertFalse(validator.validateProperty(r, "service").isEmpty(),
                    "service nulo debe violar @NotNull");
        }

        @Test
        @DisplayName("Las tres relaciones asignadas no generan violaciones")
        void todasLasRelacionesAsignadas_sinViolaciones() {
            Reservation r = buildValidReservation();
            assertTrue(validator.validateProperty(r, "client").isEmpty());
            assertTrue(validator.validateProperty(r, "carver").isEmpty());
            assertTrue(validator.validateProperty(r, "service").isEmpty());
        }
    }

    // =========================================================================
    // 5. VALIDACIONES — Fechas y horas (@NotNull + @Future)
    // =========================================================================

    @Nested
    @DisplayName("5. Validaciones — Fechas y horas")
    class ValidacionesFechasHoras {

        @Test
        @DisplayName("reservationDate en el futuro es válida")
        void reservationDate_enElFuturo_esValida() {
            Reservation r = buildValidReservation();
            r.setReservationDate(LocalDate.now().plusDays(7));
            assertTrue(validator.validateProperty(r, "reservationDate").isEmpty());
        }

        @Test
        @DisplayName("reservationDate nula genera violación @NotNull")
        void reservationDate_nula_generaViolacion() {
            Reservation r = buildValidReservation();
            r.setReservationDate(null);
            assertFalse(validator.validateProperty(r, "reservationDate").isEmpty());
        }

        @Test
        @DisplayName("reservationDate en el pasado genera violación @Future")
        void reservationDate_enElPasado_generaViolacion() {
            Reservation r = buildValidReservation();
            r.setReservationDate(LocalDate.now().minusDays(1));
            assertFalse(validator.validateProperty(r, "reservationDate").isEmpty(),
                    "Una fecha en el pasado debe violar @Future");
        }

        @Test
        @DisplayName("reservationDate hoy genera violación @Future (debe ser estrictamente futuro)")
        void reservationDate_hoy_generaViolacion() {
            Reservation r = buildValidReservation();
            r.setReservationDate(LocalDate.now());
            assertFalse(validator.validateProperty(r, "reservationDate").isEmpty(),
                    "@Future no acepta la fecha de hoy, debe ser un día posterior");
        }

        @Test
        @DisplayName("startTime nulo genera violación @NotNull")
        void startTime_nulo_generaViolacion() {
            Reservation r = buildValidReservation();
            r.setStartTime(null);
            assertFalse(validator.validateProperty(r, "startTime").isEmpty());
        }

        @Test
        @DisplayName("endTime nulo genera violación @NotNull")
        void endTime_nulo_generaViolacion() {
            Reservation r = buildValidReservation();
            r.setEndTime(null);
            assertFalse(validator.validateProperty(r, "endTime").isEmpty());
        }
    }

    // =========================================================================
    // 6. VALIDACIONES — status (@NotNull)
    // =========================================================================

    @Nested
    @DisplayName("6. Validaciones — status")
    class ValidacionesStatus {

        @Test
        @DisplayName("status nulo genera violación @NotNull")
        void status_nulo_generaViolacion() {
            Reservation r = buildValidReservation();
            r.setStatus(null);
            assertFalse(validator.validateProperty(r, "status").isEmpty());
        }

        @ParameterizedTest(name = "status válido: {0}")
        @EnumSource(Status.class)
        @DisplayName("Todos los valores del enum Status son válidos")
        void status_todosLosValoresEnum_sonValidos(Status status) {
            Reservation r = buildValidReservation();
            r.setStatus(status);
            assertTrue(validator.validateProperty(r, "status").isEmpty(),
                    "El status " + status + " debe ser válido");
        }
    }

    // =========================================================================
    // 7. VALIDACIÓN GLOBAL
    // =========================================================================

    @Nested
    @DisplayName("7. Validación global")
    class ValidacionGlobal {

        @Test
        @DisplayName("Reservation completamente válida: sin ninguna violación")
        void reservation_completamenteValida_sinViolaciones() {
            assertTrue(validator.validate(buildValidReservation()).isEmpty(),
                    "Una Reservation válida no debe tener ninguna violación");
        }

        @Test
        @DisplayName("Reservation vacía (NoArgs) tiene violaciones en los 6 campos @NotNull nulos")
        void reservation_vacia_tieneMuchasViolaciones() {
            Set<ConstraintViolation<Reservation>> violations = validator.validate(new Reservation());

            // NOTA: Lombok inicializa status=PENDING incluso con NoArgsConstructor
            // gracias a @Builder.Default en esta versión, por lo que status NO genera violación.
            // Verificamos los 6 campos que sí quedan null al usar new Reservation().
            Set<String> camposConViolacion = new java.util.HashSet<>();
            for (ConstraintViolation<Reservation> v : violations) {
                camposConViolacion.add(v.getPropertyPath().toString());
            }

            assertAll("Los 6 campos null deben tener su propia violación",
                    () -> assertTrue(camposConViolacion.contains("client"),          "client debe tener violación"),
                    () -> assertTrue(camposConViolacion.contains("carver"),          "carver debe tener violación"),
                    () -> assertTrue(camposConViolacion.contains("service"),         "service debe tener violación"),
                    () -> assertTrue(camposConViolacion.contains("reservationDate"), "reservationDate debe tener violación"),
                    () -> assertTrue(camposConViolacion.contains("startTime"),       "startTime debe tener violación"),
                    () -> assertTrue(camposConViolacion.contains("endTime"),         "endTime debe tener violación")
            );
        }
    }

    // =========================================================================
    // 8. LÓGICA DE NEGOCIO — calculateEndTime()
    // =========================================================================

    @Nested
    @DisplayName("8. Lógica de negocio — calculateEndTime()")
    class CalculateEndTime {

        @Test
        @DisplayName("Calcula correctamente endTime para servicio de 120 minutos")
        void calculateEndTime_servicio120min_calculaCorrectamente() {
            Reservation r = buildValidReservation(); // service: 120 min
            r.setStartTime(LocalTime.of(10, 0));
            r.setEndTime(null); // Forzamos recálculo

            r.calculateEndTime();

            assertEquals(LocalTime.of(12, 0), r.getEndTime(),
                    "10:00 + 120 min = 12:00");
        }

        @Test
        @DisplayName("Calcula correctamente endTime para servicio de 60 minutos")
        void calculateEndTime_servicio60min_calculaCorrectamente() {
            Service service60 = Service.builder()
                    .name("Paleta")
                    .durationMinutes(60)
                    .basePrice(new BigDecimal("35.00"))
                    .build();

            Reservation r = buildValidReservation();
            r.setService(service60);
            r.setStartTime(LocalTime.of(14, 30));

            r.calculateEndTime();

            assertEquals(LocalTime.of(15, 30), r.getEndTime(),
                    "14:30 + 60 min = 15:30");
        }

        @Test
        @DisplayName("Calcula correctamente endTime para servicio de 30 minutos")
        void calculateEndTime_servicio30min_calculaCorrectamente() {
            Service service30 = Service.builder()
                    .name("Embutidos")
                    .durationMinutes(30)
                    .basePrice(new BigDecimal("25.00"))
                    .build();

            Reservation r = buildValidReservation();
            r.setService(service30);
            r.setStartTime(LocalTime.of(11, 30));

            r.calculateEndTime();

            assertEquals(LocalTime.of(12, 0), r.getEndTime(),
                    "11:30 + 30 min = 12:00");
        }

        @Test
        @DisplayName("No lanza excepción si startTime es null (guarda defensiva)")
        void calculateEndTime_startTimeNull_noLanzaExcepcion() {
            Reservation r = buildValidReservation();
            r.setStartTime(null);
            assertDoesNotThrow(r::calculateEndTime,
                    "calculateEndTime debe tener guarda defensiva para startTime null");
        }

        @Test
        @DisplayName("No lanza excepción si service es null (guarda defensiva)")
        void calculateEndTime_serviceNull_noLanzaExcepcion() {
            Reservation r = buildValidReservation();
            r.setService(null);
            assertDoesNotThrow(r::calculateEndTime,
                    "calculateEndTime debe tener guarda defensiva para service null");
        }

        @Test
        @DisplayName("No lanza excepción si durationMinutes del service es null (guarda defensiva)")
        void calculateEndTime_durationNull_noLanzaExcepcion() {
            Service serviceConDuracionNull = new Service();
            serviceConDuracionNull.setDurationMinutes(null);

            Reservation r = buildValidReservation();
            r.setService(serviceConDuracionNull);
            r.setStartTime(LocalTime.of(10, 0));

            assertDoesNotThrow(r::calculateEndTime,
                    "calculateEndTime debe tener guarda defensiva para durationMinutes null");
        }

        @Test
        @DisplayName("endTime no cambia si startTime es null (sin efecto secundario)")
        void calculateEndTime_startTimeNull_endTimeNoCambia() {
            Reservation r = buildValidReservation();
            LocalTime endTimeOriginal = r.getEndTime();
            r.setStartTime(null);

            r.calculateEndTime();

            assertEquals(endTimeOriginal, r.getEndTime(),
                    "Si startTime es null, endTime no debe modificarse");
        }
    }

    // =========================================================================
    // 9. MÉTODOS DE UTILIDAD — addNotification / removeNotification
    // =========================================================================

    @Nested
    @DisplayName("9. Métodos de utilidad — addNotification / removeNotification")
    class MetodosUtilidad {

        @Test
        @DisplayName("addNotification: añade la notificación a la lista")
        void addNotification_anadeNotificacionALista() {
            Reservation r = buildValidReservation();
            Notification notification = new Notification();

            r.addNotification(notification);

            assertEquals(1, r.getNotifications().size());
        }

        @Test
        @DisplayName("addNotification: establece la reservation en la notificación (bidireccional)")
        void addNotification_estableceReservationEnNotificacion() {
            Reservation r = buildValidReservation();
            Notification notification = new Notification();

            r.addNotification(notification);

            assertEquals(r, notification.getReservation(),
                    "La notificación debe apuntar a la reserva (relación bidireccional)");
        }

        @Test
        @DisplayName("removeNotification: elimina la notificación de la lista")
        void removeNotification_eliminaNotificacionDeLista() {
            Reservation r = buildValidReservation();
            Notification notification = new Notification();
            r.addNotification(notification);

            r.removeNotification(notification);

            assertTrue(r.getNotifications().isEmpty());
        }

        @Test
        @DisplayName("removeNotification: pone la reservation de la notificación a null")
        void removeNotification_poneReservationANull() {
            Reservation r = buildValidReservation();
            Notification notification = new Notification();
            r.addNotification(notification);

            r.removeNotification(notification);

            assertNull(notification.getReservation());
        }

        @Test
        @DisplayName("addNotification: se pueden añadir múltiples notificaciones")
        void addNotification_variasNotificaciones_listaCreceCorrectamente() {
            Reservation r = buildValidReservation();

            r.addNotification(new Notification());
            r.addNotification(new Notification());
            r.addNotification(new Notification());

            assertEquals(3, r.getNotifications().size());
        }
    }

    // =========================================================================
    // 10. RELACIONES MANYTOONE CON USER, CARVER Y SERVICE
    // =========================================================================

    @Nested
    @DisplayName("10. Relaciones ManyToOne")
    class RelacionesManyToOne {

        @Test
        @DisplayName("La reserva navega correctamente hasta el firstName del cliente")
        void relacion_client_navegaHastaFirstName() {
            Reservation r = buildValidReservation();
            assertEquals("Juan", r.getClient().getFirstName());
        }

        @Test
        @DisplayName("La reserva navega correctamente hasta la specialty del carver")
        void relacion_carver_navegaHastaSpecialty() {
            Reservation r = buildValidReservation();
            assertEquals("Jamón", r.getCarver().getSpecialty());
        }

        @Test
        @DisplayName("La reserva navega correctamente hasta el name del service")
        void relacion_service_navegaHastaName() {
            Reservation r = buildValidReservation();
            assertEquals("Jamón", r.getService().getName());
        }

        @Test
        @DisplayName("Cambiar el client de una reserva actualiza la referencia")
        void setClient_nuevoCliente_actualizaReferencia() {
            Reservation r = buildValidReservation();
            User nuevoCliente = buildValidUser();
            nuevoCliente.setFirstName("María");

            r.setClient(nuevoCliente);

            assertEquals("María", r.getClient().getFirstName());
        }

        @Test
        @DisplayName("calculateEndTime usa la duración del service de la relación")
        void calculateEndTime_usaDuracionDelServiceRelacionado() {
            // Verifica que calculateEndTime lee correctamente la relación @ManyToOne service
            Reservation r = buildValidReservation(); // service tiene 120 min
            r.setStartTime(LocalTime.of(10, 0));
            r.calculateEndTime();

            assertEquals(LocalTime.of(12, 0), r.getEndTime(),
                    "calculateEndTime debe usar la duración del service asociado por ManyToOne");
        }
    }

    // =========================================================================
    // 11. EQUALS Y HASHCODE
    // =========================================================================

    @Nested
    @DisplayName("11. equals() y hashCode()")
    class EqualsHashCode {

        @Test
        @DisplayName("Una Reservation es igual a sí misma (reflexividad)")
        void equals_mismoObjeto_esIgual() {
            Reservation r = buildValidReservation();
            assertEquals(r, r);
        }

        @Test
        @DisplayName("Dos Reservations con el mismo id son iguales")
        void equals_mismoId_sonIguales() {
            Reservation r1 = buildValidReservation();
            Reservation r2 = buildValidReservation();
            r1.setId(1L);
            r2.setId(1L);
            assertEquals(r1, r2);
        }

        @Test
        @DisplayName("Dos Reservations con distinto id no son iguales")
        void equals_diferenteId_noSonIguales() {
            Reservation r1 = buildValidReservation();
            Reservation r2 = buildValidReservation();
            r1.setId(1L);
            r2.setId(2L);
            assertNotEquals(r1, r2);
        }

        @Test
        @DisplayName("Dos Reservations sin id (sin persistir) no son iguales")
        void equals_ambosIdNull_noSonIguales() {
            assertNotEquals(buildValidReservation(), buildValidReservation());
        }

        @Test
        @DisplayName("Reservation no es igual a null")
        void equals_vsNull_noEsIgual() {
            assertNotEquals(null, buildValidReservation());
        }

        @Test
        @DisplayName("Reservation no es igual a un objeto de otra clase")
        void equals_otraClase_noEsIgual() {
            assertNotEquals("reserva", buildValidReservation());
        }

        @Test
        @DisplayName("hashCode es consistente para el mismo objeto")
        void hashCode_esConsistente() {
            Reservation r = buildValidReservation();
            assertEquals(r.hashCode(), r.hashCode());
        }
    }

    // =========================================================================
    // 12. TOSTRING
    // =========================================================================

    @Nested
    @DisplayName("12. toString()")
    class ToStringTest {

        @Test
        @DisplayName("toString() no retorna null")
        void toString_noRetornaNull() {
            assertNotNull(buildValidReservation().toString());
        }

        @Test
        @DisplayName("toString() contiene el status")
        void toString_contieneStatus() {
            assertTrue(buildValidReservation().toString().contains("PENDING"));
        }

        @Test
        @DisplayName("toString() contiene reservationDate")
        void toString_contieneFecha() {
            Reservation r = buildValidReservation();
            assertTrue(r.toString().contains(r.getReservationDate().toString()));
        }

        @Test
        @DisplayName("toString() con client asignado muestra clientId, no el objeto User completo")
        void toString_conClient_muestraClientIdNoObjetoCompleto() {
            User client = buildValidUser();
            client.setId(5L);
            Reservation r = buildValidReservation();
            r.setClient(client);

            String result = r.toString();

            assertTrue(result.contains("5"),
                    "toString debe incluir el clientId");
            assertFalse(result.contains("password"),
                    "toString NO debe exponer datos del User");
        }

        @Test
        @DisplayName("toString() sin client (null) no lanza NullPointerException")
        void toString_clientNull_noLanzaExcepcion() {
            Reservation r = buildValidReservation();
            r.setClient(null);
            assertDoesNotThrow(r::toString,
                    "toString no debe lanzar NPE cuando client es null");
            assertTrue(r.toString().contains("clientId=null"));
        }

        @Test
        @DisplayName("toString() sin carver (null) no lanza NullPointerException")
        void toString_carverNull_noLanzaExcepcion() {
            Reservation r = buildValidReservation();
            r.setCarver(null);
            assertDoesNotThrow(r::toString);
            assertTrue(r.toString().contains("carverId=null"));
        }

        @Test
        @DisplayName("toString() sin service (null) no lanza NullPointerException")
        void toString_serviceNull_noLanzaExcepcion() {
            Reservation r = buildValidReservation();
            r.setService(null);
            assertDoesNotThrow(r::toString);
            assertTrue(r.toString().contains("serviceId=null"));
        }
    }
}