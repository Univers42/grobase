package com.hambooking.backend.model.entity;

import com.hambooking.backend.model.enums.NotificationType;
import com.hambooking.backend.model.enums.RecipientType;
import jakarta.validation.ConstraintViolation;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import jakarta.validation.ValidatorFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.junit.jupiter.params.provider.ValueSource;

import java.math.BigDecimal;
import java.util.HashSet;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Batería de tests unitarios para la entidad Notification.
 *
 * Cubre:
 *   - Construcción mediante Builder y constructor vacío
 *   - Valores por defecto (@Builder.Default: isSent=true)
 *   - Getters y Setters (Lombok)
 *   - Validaciones: @NotNull en enums, @NotBlank + @Email + @Size en recipientEmail,
 *                   @NotBlank + @Size en subject y message
 *   - Relación opcional ManyToOne con Reservation (sin @NotNull)
 *   - equals() y hashCode()
 *   - toString() (extracción segura de reservationId, null-safe)
 */
@DisplayName("Notification — Tests unitarios")
class NotificationTest {

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
    // MÉTODO AUXILIAR: construye una Notification válida para reutilizar
    // =========================================================================

    private Notification buildValidNotification() {
        return Notification.builder()
                .recipientType(RecipientType.CLIENT)
                .recipientEmail("cliente@example.com")
                .notificationType(NotificationType.CREATED)
                .subject("Tu reserva ha sido confirmada")
                .message("Hola, tu reserva para el servicio de Jamón ha sido creada correctamente.")
                .isSent(true)
                .build();
    }

    private Reservation buildValidReservation() {
        return Reservation.builder()
                .client(User.builder()
                        .dni("12345678A")
                        .firstName("Juan")
                        .lastName("García")
                        .email("juan@example.com")
                        .phone("612345678")
                        .passwordHash("$2a$10$hash")
                        .build())
                .carver(Carver.builder()
                        .specialty("Jamón")
                        .experienceYears(3)
                        .maxHamsPerDay(3)
                        .build())
                .service(Service.builder()
                        .name("Jamón")
                        .durationMinutes(120)
                        .basePrice(new BigDecimal("50.00"))
                        .build())
                .reservationDate(java.time.LocalDate.now().plusDays(3))
                .startTime(java.time.LocalTime.of(10, 0))
                .endTime(java.time.LocalTime.of(12, 0))
                .build();
    }

    // =========================================================================
    // 1. CONSTRUCCIÓN — Builder y NoArgsConstructor
    // =========================================================================

    @Nested
    @DisplayName("1. Construcción del objeto")
    class Construccion {

        @Test
        @DisplayName("Builder crea Notification con todos los campos correctamente")
        void builder_conCamposValidos_creaNotificationCorrectamente() {
            Notification n = buildValidNotification();

            assertAll("Todos los campos deben coincidir con los valores del Builder",
                    () -> assertEquals(RecipientType.CLIENT, n.getRecipientType()),
                    () -> assertEquals("cliente@example.com", n.getRecipientEmail()),
                    () -> assertEquals(NotificationType.CREATED, n.getNotificationType()),
                    () -> assertEquals("Tu reserva ha sido confirmada", n.getSubject()),
                    () -> assertNotNull(n.getMessage()),
                    () -> assertTrue(n.getIsSent())
            );
        }

        @Test
        @DisplayName("NoArgsConstructor crea una instancia no nula")
        void noArgsConstructor_creaInstanciaNoNula() {
            assertNotNull(new Notification());
        }

        @Test
        @DisplayName("NoArgsConstructor: id es null antes de persistir")
        void noArgsConstructor_idEsNullAntesDePersistir() {
            assertNull(new Notification().getId());
        }

        @Test
        @DisplayName("Builder sin reservation: reservation es null (relación opcional)")
        void builder_sinReservation_reservationEsNull() {
            assertNull(buildValidNotification().getReservation(),
                    "reservation es opcional y debe ser null si no se asigna");
        }

        @Test
        @DisplayName("Builder con reservation: reservation queda correctamente referenciada")
        void builder_conReservation_reservationEsReferenciada() {
            Reservation reservation = buildValidReservation();
            Notification n = Notification.builder()
                    .reservation(reservation)
                    .recipientType(RecipientType.CLIENT)
                    .recipientEmail("test@example.com")
                    .notificationType(NotificationType.CREATED)
                    .subject("Asunto")
                    .message("Mensaje")
                    .build();

            assertEquals(reservation, n.getReservation());
        }
    }

    // =========================================================================
    // 2. VALORES POR DEFECTO (@Builder.Default)
    // =========================================================================

    @Nested
    @DisplayName("2. Valores por defecto")
    class ValoresPorDefecto {

        @Test
        @DisplayName("isSent por defecto es true")
        void isSent_porDefecto_esTrue() {
            Notification n = Notification.builder()
                    .recipientType(RecipientType.ADMIN)
                    .recipientEmail("admin@example.com")
                    .notificationType(NotificationType.REMINDER)
                    .subject("Recordatorio")
                    .message("Tienes una reserva mañana.")
                    .build();

            assertTrue(n.getIsSent(),
                    "isSent debe ser true por defecto");
        }

        @Test
        @DisplayName("sentAt es null antes de persistir (lo asigna @CreationTimestamp)")
        void sentAt_porDefecto_esNull() {
            assertNull(buildValidNotification().getSentAt(),
                    "sentAt es null hasta que Hibernate persiste la entidad");
        }
    }

    // =========================================================================
    // 3. GETTERS Y SETTERS (Lombok)
    // =========================================================================

    @Nested
    @DisplayName("3. Getters y Setters")
    class GettersSetters {

        @Test
        @DisplayName("Setter de recipientType actualiza el valor correctamente")
        void setRecipientType_actualizaElValor() {
            Notification n = buildValidNotification();
            n.setRecipientType(RecipientType.CARVER);
            assertEquals(RecipientType.CARVER, n.getRecipientType());
        }

        @Test
        @DisplayName("Setter de recipientEmail actualiza el valor correctamente")
        void setRecipientEmail_actualizaElValor() {
            Notification n = buildValidNotification();
            n.setRecipientEmail("nuevo@example.com");
            assertEquals("nuevo@example.com", n.getRecipientEmail());
        }

        @Test
        @DisplayName("Setter de notificationType actualiza el valor correctamente")
        void setNotificationType_actualizaElValor() {
            Notification n = buildValidNotification();
            n.setNotificationType(NotificationType.CANCELLED);
            assertEquals(NotificationType.CANCELLED, n.getNotificationType());
        }

        @Test
        @DisplayName("Setter de subject actualiza el valor correctamente")
        void setSubject_actualizaElValor() {
            Notification n = buildValidNotification();
            n.setSubject("Nuevo asunto");
            assertEquals("Nuevo asunto", n.getSubject());
        }

        @Test
        @DisplayName("Setter de message actualiza el valor correctamente")
        void setMessage_actualizaElValor() {
            Notification n = buildValidNotification();
            n.setMessage("Nuevo mensaje de notificación.");
            assertEquals("Nuevo mensaje de notificación.", n.getMessage());
        }

        @Test
        @DisplayName("Setter de isSent permite marcar como no enviada")
        void setIsSent_permiteMarcarComoNoEnviada() {
            Notification n = buildValidNotification();
            n.setIsSent(false);
            assertFalse(n.getIsSent());
        }

        @Test
        @DisplayName("Setter de reservation asigna la relación opcional")
        void setReservation_asignaRelacion() {
            Notification n = buildValidNotification();
            Reservation r = buildValidReservation();
            n.setReservation(r);
            assertEquals(r, n.getReservation());
        }

        @Test
        @DisplayName("Setter de reservation permite desasignar (null)")
        void setReservation_null_desasignaRelacion() {
            Notification n = buildValidNotification();
            n.setReservation(buildValidReservation());
            n.setReservation(null);
            assertNull(n.getReservation());
        }
    }

    // =========================================================================
    // 4. VALIDACIONES — recipientType (@NotNull)
    // =========================================================================

    @Nested
    @DisplayName("4. Validaciones — recipientType")
    class ValidacionesRecipientType {

        @Test
        @DisplayName("recipientType nulo genera violación @NotNull")
        void recipientType_nulo_generaViolacion() {
            Notification n = buildValidNotification();
            n.setRecipientType(null);
            assertFalse(validator.validateProperty(n, "recipientType").isEmpty());
        }

        @ParameterizedTest(name = "recipientType válido: {0}")
        @EnumSource(RecipientType.class)
        @DisplayName("Todos los valores de RecipientType son válidos")
        void recipientType_todosLosValores_sonValidos(RecipientType tipo) {
            Notification n = buildValidNotification();
            n.setRecipientType(tipo);
            assertTrue(validator.validateProperty(n, "recipientType").isEmpty(),
                    "RecipientType." + tipo + " debe ser válido");
        }
    }

    // =========================================================================
    // 5. VALIDACIONES — recipientEmail (@NotBlank + @Email + @Size)
    // =========================================================================

    @Nested
    @DisplayName("5. Validaciones — recipientEmail")
    class ValidacionesRecipientEmail {

        @Test
        @DisplayName("recipientEmail válido no genera violaciones")
        void recipientEmail_valido_noGeneraViolaciones() {
            Notification n = buildValidNotification();
            assertTrue(validator.validateProperty(n, "recipientEmail").isEmpty());
        }

        @Test
        @DisplayName("recipientEmail nulo genera violación @NotBlank")
        void recipientEmail_nulo_generaViolacion() {
            Notification n = buildValidNotification();
            n.setRecipientEmail(null);
            assertFalse(validator.validateProperty(n, "recipientEmail").isEmpty());
        }

        @Test
        @DisplayName("recipientEmail vacío genera violación @NotBlank")
        void recipientEmail_vacio_generaViolacion() {
            Notification n = buildValidNotification();
            n.setRecipientEmail("");
            assertFalse(validator.validateProperty(n, "recipientEmail").isEmpty());
        }

        @Test
        @DisplayName("recipientEmail solo espacios genera violación @NotBlank")
        void recipientEmail_soloEspacios_generaViolacion() {
            Notification n = buildValidNotification();
            n.setRecipientEmail("   ");
            assertFalse(validator.validateProperty(n, "recipientEmail").isEmpty());
        }

        @ParameterizedTest(name = "email inválido: ''{0}''")
        @ValueSource(strings = {"sinArroba", "@sinlocal.com", "doble@@ejemplo.com"})
        @DisplayName("Emails con formato incorrecto generan violación @Email")
        void recipientEmail_formatoIncorrecto_generaViolacion(String emailInvalido) {
            Notification n = buildValidNotification();
            n.setRecipientEmail(emailInvalido);
            assertFalse(validator.validateProperty(n, "recipientEmail").isEmpty(),
                    "Email '" + emailInvalido + "' debería fallar la validación");
        }

        @Test
        @DisplayName("recipientEmail con exactamente 150 caracteres no genera violación")
        void recipientEmail_150Caracteres_noGeneraViolacion() {
            // Construcción cuidadosa respetando TRES límites RFC simultáneos:
            //   - Parte local: max 64 chars  → usamos "usuario" (7 chars)
            //   - Etiqueta DNS: max 63 chars → dividimos el dominio en 3 segmentos
            //   - Total email:  max 150 chars (nuestro @Size)
            // Fórmula: "usuario@" (8) + seg1 (63) + "." + seg2 (63) + "." + seg3 (10) + ".com" (4) = 150
            String seg1 = "a".repeat(63);
            String seg2 = "b".repeat(63);
            String seg3 = "c".repeat(10);
            String email150 = "usuario@" + seg1 + "." + seg2 + "." + seg3 + ".com";
            Notification n = buildValidNotification();
            n.setRecipientEmail(email150);
            assertTrue(validator.validateProperty(n, "recipientEmail").isEmpty(),
                    "Email de exactamente 150 caracteres con etiquetas DNS válidas debe pasar @Email y @Size");
        }

        @Test
        @DisplayName("recipientEmail con 151 caracteres genera violación @Size")
        void recipientEmail_151Caracteres_generaViolacion() {
            // Mismo patrón, seg3 con 11 chars en lugar de 10 → total 151 chars
            // "usuario@" (8) + seg1 (63) + "." + seg2 (63) + "." + seg3 (11) + ".com" (4) = 151
            String seg1 = "a".repeat(63);
            String seg2 = "b".repeat(63);
            String seg3 = "c".repeat(11);
            String email151 = "usuario@" + seg1 + "." + seg2 + "." + seg3 + ".com";
            Notification n = buildValidNotification();
            n.setRecipientEmail(email151);
            assertFalse(validator.validateProperty(n, "recipientEmail").isEmpty(),
                    "Email de 151 caracteres debe violar @Size(max=150)");
        }
    }

    // =========================================================================
    // 6. VALIDACIONES — notificationType (@NotNull)
    // =========================================================================

    @Nested
    @DisplayName("6. Validaciones — notificationType")
    class ValidacionesNotificationType {

        @Test
        @DisplayName("notificationType nulo genera violación @NotNull")
        void notificationType_nulo_generaViolacion() {
            Notification n = buildValidNotification();
            n.setNotificationType(null);
            assertFalse(validator.validateProperty(n, "notificationType").isEmpty());
        }

        @ParameterizedTest(name = "notificationType válido: {0}")
        @EnumSource(NotificationType.class)
        @DisplayName("Todos los valores de NotificationType son válidos")
        void notificationType_todosLosValores_sonValidos(NotificationType tipo) {
            Notification n = buildValidNotification();
            n.setNotificationType(tipo);
            assertTrue(validator.validateProperty(n, "notificationType").isEmpty(),
                    "NotificationType." + tipo + " debe ser válido");
        }
    }

    // =========================================================================
    // 7. VALIDACIONES — subject (@NotBlank + @Size)
    // =========================================================================

    @Nested
    @DisplayName("7. Validaciones — subject")
    class ValidacionesSubject {

        @Test
        @DisplayName("subject válido no genera violaciones")
        void subject_valido_noGeneraViolaciones() {
            assertTrue(validator.validateProperty(buildValidNotification(), "subject").isEmpty());
        }

        @Test
        @DisplayName("subject nulo genera violación @NotBlank")
        void subject_nulo_generaViolacion() {
            Notification n = buildValidNotification();
            n.setSubject(null);
            assertFalse(validator.validateProperty(n, "subject").isEmpty());
        }

        @Test
        @DisplayName("subject vacío genera violación @NotBlank")
        void subject_vacio_generaViolacion() {
            Notification n = buildValidNotification();
            n.setSubject("");
            assertFalse(validator.validateProperty(n, "subject").isEmpty());
        }

        @Test
        @DisplayName("subject solo espacios genera violación @NotBlank")
        void subject_soloEspacios_generaViolacion() {
            Notification n = buildValidNotification();
            n.setSubject("   ");
            assertFalse(validator.validateProperty(n, "subject").isEmpty());
        }

        @Test
        @DisplayName("subject con exactamente 255 caracteres no genera violación")
        void subject_255Caracteres_noGeneraViolacion() {
            Notification n = buildValidNotification();
            n.setSubject("S".repeat(255));
            assertTrue(validator.validateProperty(n, "subject").isEmpty());
        }

        @Test
        @DisplayName("subject con 256 caracteres genera violación @Size")
        void subject_256Caracteres_generaViolacion() {
            Notification n = buildValidNotification();
            n.setSubject("S".repeat(256));
            assertFalse(validator.validateProperty(n, "subject").isEmpty(),
                    "subject de 256 caracteres debe violar @Size(max=255)");
        }
    }

    // =========================================================================
    // 8. VALIDACIONES — message (@NotBlank)
    // =========================================================================

    @Nested
    @DisplayName("8. Validaciones — message")
    class ValidacionesMessage {

        @Test
        @DisplayName("message válido no genera violaciones")
        void message_valido_noGeneraViolaciones() {
            assertTrue(validator.validateProperty(buildValidNotification(), "message").isEmpty());
        }

        @Test
        @DisplayName("message nulo genera violación @NotBlank")
        void message_nulo_generaViolacion() {
            Notification n = buildValidNotification();
            n.setMessage(null);
            assertFalse(validator.validateProperty(n, "message").isEmpty());
        }

        @Test
        @DisplayName("message vacío genera violación @NotBlank")
        void message_vacio_generaViolacion() {
            Notification n = buildValidNotification();
            n.setMessage("");
            assertFalse(validator.validateProperty(n, "message").isEmpty());
        }

        @Test
        @DisplayName("message muy largo (TEXT en BD) no genera violación de @Size — no tiene límite en Java")
        void message_muyLargo_noGeneraViolacion() {
            // message usa columnDefinition="TEXT" en BD pero NO tiene @Size en Java
            // → No hay límite de longitud a nivel de Bean Validation
            Notification n = buildValidNotification();
            n.setMessage("M".repeat(10_000));
            assertTrue(validator.validateProperty(n, "message").isEmpty(),
                    "message no tiene @Size, solo @NotBlank — textos largos son válidos en Java");
        }
    }

    // =========================================================================
    // 9. RELACIÓN OPCIONAL CON RESERVATION (sin @NotNull)
    // =========================================================================

    @Nested
    @DisplayName("9. Relación opcional con Reservation")
    class RelacionReservation {

        @Test
        @DisplayName("Notification sin reservation es válida (relación opcional)")
        void notification_sinReservation_esValida() {
            Notification n = buildValidNotification(); // reservation = null
            assertTrue(validator.validate(n).isEmpty(),
                    "Una Notification sin reservation debe ser válida — la FK no tiene NOT NULL");
        }

        @Test
        @DisplayName("Notification con reservation asignada también es válida")
        void notification_conReservation_esValida() {
            Notification n = buildValidNotification();
            n.setReservation(buildValidReservation());
            assertTrue(validator.validate(n).isEmpty());
        }

        @Test
        @DisplayName("La relación es navegable: notification.reservation.service.name")
        void relacion_esNavegable() {
            Reservation r = buildValidReservation();
            Notification n = buildValidNotification();
            n.setReservation(r);

            assertEquals("Jamón", n.getReservation().getService().getName(),
                    "La navegación notification → reservation → service debe funcionar");
        }
    }

    // =========================================================================
    // 10. VALIDACIÓN GLOBAL
    // =========================================================================

    @Nested
    @DisplayName("10. Validación global")
    class ValidacionGlobal {

        @Test
        @DisplayName("Notification completamente válida: sin ninguna violación")
        void notification_completamenteValida_sinViolaciones() {
            assertTrue(validator.validate(buildValidNotification()).isEmpty(),
                    "Una Notification válida no debe tener ninguna violación");
        }

        @Test
        @DisplayName("Notification vacía tiene violaciones en los campos obligatorios")
        void notification_vacia_tieneViolacionesEnCamposObligatorios() {
            Set<ConstraintViolation<Notification>> violations = validator.validate(new Notification());

            Set<String> camposConViolacion = new HashSet<>();
            for (ConstraintViolation<Notification> v : violations) {
                camposConViolacion.add(v.getPropertyPath().toString());
            }

            assertAll("Los campos obligatorios deben tener violación",
                    () -> assertTrue(camposConViolacion.contains("recipientType"),  "recipientType debe tener violación"),
                    () -> assertTrue(camposConViolacion.contains("recipientEmail"), "recipientEmail debe tener violación"),
                    () -> assertTrue(camposConViolacion.contains("notificationType"), "notificationType debe tener violación"),
                    () -> assertTrue(camposConViolacion.contains("subject"),        "subject debe tener violación"),
                    () -> assertTrue(camposConViolacion.contains("message"),        "message debe tener violación")
            );
        }

        @Test
        @DisplayName("Notification sin reservation (null) es válida — no tiene @NotNull en esa FK")
        void notification_sinReservation_noCuentaComoViolacion() {
            Notification n = buildValidNotification();
            n.setReservation(null);
            assertTrue(validator.validate(n).isEmpty(),
                    "reservation es opcional (ON DELETE SET NULL en BD), no debe generar violación");
        }
    }

    // =========================================================================
    // 11. EQUALS Y HASHCODE
    // =========================================================================

    @Nested
    @DisplayName("11. equals() y hashCode()")
    class EqualsHashCode {

        @Test
        @DisplayName("Una Notification es igual a sí misma (reflexividad)")
        void equals_mismoObjeto_esIgual() {
            Notification n = buildValidNotification();
            assertEquals(n, n);
        }

        @Test
        @DisplayName("Dos Notifications con el mismo id son iguales")
        void equals_mismoId_sonIguales() {
            Notification n1 = buildValidNotification();
            Notification n2 = buildValidNotification();
            n1.setId(1L);
            n2.setId(1L);
            assertEquals(n1, n2);
        }

        @Test
        @DisplayName("Dos Notifications con distinto id no son iguales")
        void equals_diferenteId_noSonIguales() {
            Notification n1 = buildValidNotification();
            Notification n2 = buildValidNotification();
            n1.setId(1L);
            n2.setId(2L);
            assertNotEquals(n1, n2);
        }

        @Test
        @DisplayName("Dos Notifications sin id (sin persistir) no son iguales")
        void equals_ambosIdNull_noSonIguales() {
            assertNotEquals(buildValidNotification(), buildValidNotification());
        }

        @Test
        @DisplayName("Notification no es igual a null")
        void equals_vsNull_noEsIgual() {
            assertNotEquals(null, buildValidNotification());
        }

        @Test
        @DisplayName("Notification no es igual a un objeto de otra clase")
        void equals_otraClase_noEsIgual() {
            assertNotEquals("notificacion", buildValidNotification());
        }

        @Test
        @DisplayName("hashCode es consistente para el mismo objeto")
        void hashCode_esConsistente() {
            Notification n = buildValidNotification();
            assertEquals(n.hashCode(), n.hashCode());
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
            assertNotNull(buildValidNotification().toString());
        }

        @Test
        @DisplayName("toString() contiene el recipientEmail")
        void toString_contieneRecipientEmail() {
            assertTrue(buildValidNotification().toString().contains("cliente@example.com"));
        }

        @Test
        @DisplayName("toString() contiene el notificationType")
        void toString_contieneNotificationType() {
            assertTrue(buildValidNotification().toString().contains("CREATED"));
        }

        @Test
        @DisplayName("toString() contiene el subject")
        void toString_contieneSubject() {
            assertTrue(buildValidNotification().toString().contains("Tu reserva ha sido confirmada"));
        }

        @Test
        @DisplayName("toString() con reservation asignada muestra reservationId, no el objeto completo")
        void toString_conReservation_muestraReservationIdNoObjetoCompleto() {
            Reservation r = buildValidReservation();
            r.setId(9L);
            Notification n = buildValidNotification();
            n.setReservation(r);

            String result = n.toString();

            assertTrue(result.contains("9"),
                    "toString debe incluir el reservationId");
            assertFalse(result.contains("password"),
                    "toString NO debe exponer datos del User asociado a la Reservation");
        }

        @Test
        @DisplayName("toString() con reservation null no lanza NullPointerException")
        void toString_sinReservation_noLanzaExcepcion() {
            Notification n = buildValidNotification(); // reservation = null
            assertDoesNotThrow(n::toString,
                    "toString no debe lanzar NPE cuando reservation es null");
            assertTrue(n.toString().contains("reservationId=null"));
        }

        @Test
        @DisplayName("toString() NO incluye el mensaje completo — solo los campos de cabecera")
        void toString_noIncluyeMensajeCompleto() {
            // El toString manual incluye subject pero NO message (puede ser muy largo — TEXT)
            Notification n = buildValidNotification();
            String result = n.toString();
            // subject sí aparece, pero message (el cuerpo largo) no está en el toString
            assertFalse(result.contains("Hola, tu reserva para el servicio"),
                    "toString no debe incluir el cuerpo del mensaje para mantener logs limpios");
        }
    }
}