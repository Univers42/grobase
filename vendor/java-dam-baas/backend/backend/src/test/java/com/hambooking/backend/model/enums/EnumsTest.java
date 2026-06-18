package com.hambooking.backend.model.enums;

import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;

import java.util.HashSet;
import java.util.Set;
import static org.junit.jupiter.api.Assertions.*;

/**
 * Batería de tests unitarios para todos los enums del sistema HamBooking.
 *
 * Enums cubiertos:
 *   - Role         (ADMIN, CLIENT)
 *   - Status       (PENDING, CONFIRMED, COMPLETED, CANCELLED)
 *   - NotificationType (CREATED, MODIFIED, CANCELLED, REMINDER)
 *   - RecipientType    (CLIENT, CARVER, ADMIN)
 *
 * Cubre por cada enum:
 *   - Número exacto de valores definidos (contrato de la API)
 *   - Existencia y nombre exacto de cada constante
 *   - getDisplayName() retorna el valor esperado
 *   - valueOf() funciona correctamente para todos los valores
 *   - name() retorna el nombre de la constante en String
 *   - ordinal() tiene el orden correcto
 *   - Compatibilidad con EnumType.STRING (nombre == valor guardado en BD)
 */
@DisplayName("Enums — Tests unitarios")
class EnumsTest {

    // =========================================================================
    // ROLE
    // =========================================================================

    @Nested
    @DisplayName("Role")
    class RoleTest {

        @Test
        @DisplayName("Role tiene exactamente 2 valores")
        void role_tieneExactamenteDosValores() {
            assertEquals(2, Role.values().length,
                    "Role debe tener exactamente 2 valores: ADMIN y CLIENT");
        }

        @Test
        @DisplayName("Role contiene ADMIN")
        void role_contieneAdmin() {
            assertDoesNotThrow(() -> Role.valueOf("ADMIN"),
                    "Role.ADMIN debe existir");
        }

        @Test
        @DisplayName("Role contiene CLIENT")
        void role_contieneClient() {
            assertDoesNotThrow(() -> Role.valueOf("CLIENT"),
                    "Role.CLIENT debe existir");
        }

        @Test
        @DisplayName("Role.ADMIN.getDisplayName() retorna 'Administrador'")
        void role_admin_displayName() {
            assertEquals("Administrador", Role.ADMIN.getDisplayName());
        }

        @Test
        @DisplayName("Role.CLIENT.getDisplayName() retorna 'Cliente'")
        void role_client_displayName() {
            assertEquals("Cliente", Role.CLIENT.getDisplayName());
        }

        @ParameterizedTest(name = "Role.{0}: getDisplayName() no es null ni vacío")
        @EnumSource(Role.class)
        @DisplayName("Todos los valores de Role tienen displayName no nulo ni vacío")
        void role_todosLosValores_tienenDisplayNameValido(Role role) {
            assertNotNull(role.getDisplayName(),
                    "displayName de Role." + role + " no debe ser null");
            assertFalse(role.getDisplayName().isBlank(),
                    "displayName de Role." + role + " no debe estar en blanco");
        }

        @Test
        @DisplayName("Role.valueOf() es case-sensitive: 'admin' lanza excepción")
        void role_valueOf_esCaseSensitive() {
            assertThrows(IllegalArgumentException.class, () -> Role.valueOf("admin"),
                    "valueOf() es case-sensitive: 'admin' no es un valor válido");
        }

        @Test
        @DisplayName("Role.ADMIN.name() retorna 'ADMIN' (compatibilidad EnumType.STRING en BD)")
        void role_admin_name_esCompatibleConBD() {
            assertEquals("ADMIN", Role.ADMIN.name(),
                    "El valor guardado en BD con EnumType.STRING debe ser 'ADMIN'");
        }

        @Test
        @DisplayName("Role.CLIENT.name() retorna 'CLIENT' (compatibilidad EnumType.STRING en BD)")
        void role_client_name_esCompatibleConBD() {
            assertEquals("CLIENT", Role.CLIENT.name());
        }

        @Test
        @DisplayName("Role.ADMIN tiene ordinal 0 y Role.CLIENT tiene ordinal 1")
        void role_ordinalesCorrectos() {
            assertAll(
                    () -> assertEquals(0, Role.ADMIN.ordinal()),
                    () -> assertEquals(1, Role.CLIENT.ordinal())
            );
        }
    }

    // =========================================================================
    // STATUS
    // =========================================================================

    @Nested
    @DisplayName("Status")
    class StatusTest {

        @Test
        @DisplayName("Status tiene exactamente 4 valores")
        void status_tieneExactamenteCuatroValores() {
            assertEquals(4, Status.values().length,
                    "Status debe tener exactamente 4 valores");
        }

        @Test
        @DisplayName("Status contiene PENDING, CONFIRMED, COMPLETED, CANCELLED")
        void status_contieneTodasLasConstantes() {
            assertAll(
                    () -> assertDoesNotThrow(() -> Status.valueOf("PENDING")),
                    () -> assertDoesNotThrow(() -> Status.valueOf("CONFIRMED")),
                    () -> assertDoesNotThrow(() -> Status.valueOf("COMPLETED")),
                    () -> assertDoesNotThrow(() -> Status.valueOf("CANCELLED"))
            );
        }

        @Test
        @DisplayName("Status.PENDING.getDisplayName() retorna 'Pendiente'")
        void status_pending_displayName() {
            assertEquals("Pendiente", Status.PENDING.getDisplayName());
        }

        @Test
        @DisplayName("Status.CONFIRMED.getDisplayName() retorna 'Confirmada'")
        void status_confirmed_displayName() {
            assertEquals("Confirmada", Status.CONFIRMED.getDisplayName());
        }

        @Test
        @DisplayName("Status.COMPLETED.getDisplayName() retorna 'Completada'")
        void status_completed_displayName() {
            assertEquals("Completada", Status.COMPLETED.getDisplayName());
        }

        @Test
        @DisplayName("Status.CANCELLED.getDisplayName() retorna 'Cancelada'")
        void status_cancelled_displayName() {
            assertEquals("Cancelada", Status.CANCELLED.getDisplayName());
        }

        @ParameterizedTest(name = "Status.{0}: getDisplayName() no es null ni vacío")
        @EnumSource(Status.class)
        @DisplayName("Todos los valores de Status tienen displayName válido")
        void status_todosLosValores_tienenDisplayNameValido(Status status) {
            assertNotNull(status.getDisplayName());
            assertFalse(status.getDisplayName().isBlank());
        }

        @Test
        @DisplayName("Status.valueOf() es case-sensitive: 'pending' lanza excepción")
        void status_valueOf_esCaseSensitive() {
            assertThrows(IllegalArgumentException.class, () -> Status.valueOf("pending"));
        }

        @Test
        @DisplayName("Todos los name() son compatibles con EnumType.STRING en BD")
        void status_names_sonCompatiblesConBD() {
            assertAll(
                    () -> assertEquals("PENDING",   Status.PENDING.name()),
                    () -> assertEquals("CONFIRMED", Status.CONFIRMED.name()),
                    () -> assertEquals("COMPLETED", Status.COMPLETED.name()),
                    () -> assertEquals("CANCELLED", Status.CANCELLED.name())
            );
        }

        @Test
        @DisplayName("Status tiene el orden correcto de ciclo de vida de una reserva")
        void status_ordinalesReflejanCicloDeVida() {
            assertAll(
                    () -> assertEquals(0, Status.PENDING.ordinal(),   "PENDING debe ser el primero"),
                    () -> assertEquals(1, Status.CONFIRMED.ordinal(), "CONFIRMED debe ser el segundo"),
                    () -> assertEquals(2, Status.COMPLETED.ordinal(), "COMPLETED debe ser el tercero"),
                    () -> assertEquals(3, Status.CANCELLED.ordinal(), "CANCELLED debe ser el cuarto")
            );
        }
    }

    // =========================================================================
    // NOTIFICATION TYPE
    // =========================================================================

    @Nested
    @DisplayName("NotificationType")
    class NotificationTypeTest {

        @Test
        @DisplayName("NotificationType tiene exactamente 4 valores")
        void notificationType_tieneExactamenteCuatroValores() {
            assertEquals(4, NotificationType.values().length);
        }

        @Test
        @DisplayName("NotificationType contiene CREATED, MODIFIED, CANCELLED, REMINDER")
        void notificationType_contieneTodasLasConstantes() {
            assertAll(
                    () -> assertDoesNotThrow(() -> NotificationType.valueOf("CREATED")),
                    () -> assertDoesNotThrow(() -> NotificationType.valueOf("MODIFIED")),
                    () -> assertDoesNotThrow(() -> NotificationType.valueOf("CANCELLED")),
                    () -> assertDoesNotThrow(() -> NotificationType.valueOf("REMINDER"))
            );
        }

        @Test
        @DisplayName("NotificationType.CREATED.getDisplayName() retorna 'Reserva Creada'")
        void notificationType_created_displayName() {
            assertEquals("Reserva Creada", NotificationType.CREATED.getDisplayName());
        }

        @Test
        @DisplayName("NotificationType.MODIFIED.getDisplayName() retorna 'Reserva Modificada'")
        void notificationType_modified_displayName() {
            assertEquals("Reserva Modificada", NotificationType.MODIFIED.getDisplayName());
        }

        @Test
        @DisplayName("NotificationType.CANCELLED.getDisplayName() retorna 'Reserva Cancelada'")
        void notificationType_cancelled_displayName() {
            assertEquals("Reserva Cancelada", NotificationType.CANCELLED.getDisplayName());
        }

        @Test
        @DisplayName("NotificationType.REMINDER.getDisplayName() retorna 'Recordatorio'")
        void notificationType_reminder_displayName() {
            assertEquals("Recordatorio", NotificationType.REMINDER.getDisplayName());
        }

        @ParameterizedTest(name = "NotificationType.{0}: getDisplayName() no es null ni vacío")
        @EnumSource(NotificationType.class)
        @DisplayName("Todos los valores de NotificationType tienen displayName válido")
        void notificationType_todosLosValores_tienenDisplayNameValido(NotificationType tipo) {
            assertNotNull(tipo.getDisplayName());
            assertFalse(tipo.getDisplayName().isBlank());
        }

        @Test
        @DisplayName("NotificationType.valueOf() es case-sensitive")
        void notificationType_valueOf_esCaseSensitive() {
            assertThrows(IllegalArgumentException.class,
                    () -> NotificationType.valueOf("created"));
        }

        @Test
        @DisplayName("Todos los name() son compatibles con EnumType.STRING en BD")
        void notificationType_names_sonCompatiblesConBD() {
            assertAll(
                    () -> assertEquals("CREATED",   NotificationType.CREATED.name()),
                    () -> assertEquals("MODIFIED",  NotificationType.MODIFIED.name()),
                    () -> assertEquals("CANCELLED", NotificationType.CANCELLED.name()),
                    () -> assertEquals("REMINDER",  NotificationType.REMINDER.name())
            );
        }

        @Test
        @DisplayName("NotificationType tiene el orden correcto de eventos del sistema")
        void notificationType_ordinalesCorrectos() {
            assertAll(
                    () -> assertEquals(0, NotificationType.CREATED.ordinal()),
                    () -> assertEquals(1, NotificationType.MODIFIED.ordinal()),
                    () -> assertEquals(2, NotificationType.CANCELLED.ordinal()),
                    () -> assertEquals(3, NotificationType.REMINDER.ordinal())
            );
        }
    }

    // =========================================================================
    // RECIPIENT TYPE
    // =========================================================================

    @Nested
    @DisplayName("RecipientType")
    class RecipientTypeTest {

        @Test
        @DisplayName("RecipientType tiene exactamente 3 valores")
        void recipientType_tieneExactamenteTresValores() {
            assertEquals(3, RecipientType.values().length,
                    "RecipientType debe tener exactamente 3 valores: CLIENT, CARVER, ADMIN");
        }

        @Test
        @DisplayName("RecipientType contiene CLIENT, CARVER, ADMIN")
        void recipientType_contieneTodasLasConstantes() {
            assertAll(
                    () -> assertDoesNotThrow(() -> RecipientType.valueOf("CLIENT")),
                    () -> assertDoesNotThrow(() -> RecipientType.valueOf("CARVER")),
                    () -> assertDoesNotThrow(() -> RecipientType.valueOf("ADMIN"))
            );
        }

        @Test
        @DisplayName("RecipientType.CLIENT.getDisplayName() retorna 'Cliente'")
        void recipientType_client_displayName() {
            assertEquals("Cliente", RecipientType.CLIENT.getDisplayName());
        }

        @Test
        @DisplayName("RecipientType.CARVER.getDisplayName() retorna 'Cortador'")
        void recipientType_carver_displayName() {
            assertEquals("Cortador", RecipientType.CARVER.getDisplayName());
        }

        @Test
        @DisplayName("RecipientType.ADMIN.getDisplayName() retorna 'Administrador'")
        void recipientType_admin_displayName() {
            assertEquals("Administrador", RecipientType.ADMIN.getDisplayName());
        }

        @ParameterizedTest(name = "RecipientType.{0}: getDisplayName() no es null ni vacío")
        @EnumSource(RecipientType.class)
        @DisplayName("Todos los valores de RecipientType tienen displayName válido")
        void recipientType_todosLosValores_tienenDisplayNameValido(RecipientType tipo) {
            assertNotNull(tipo.getDisplayName());
            assertFalse(tipo.getDisplayName().isBlank());
        }

        @Test
        @DisplayName("RecipientType.valueOf() es case-sensitive")
        void recipientType_valueOf_esCaseSensitive() {
            assertThrows(IllegalArgumentException.class,
                    () -> RecipientType.valueOf("client"));
        }

        @Test
        @DisplayName("Todos los name() son compatibles con EnumType.STRING en BD")
        void recipientType_names_sonCompatiblesConBD() {
            assertAll(
                    () -> assertEquals("CLIENT", RecipientType.CLIENT.name()),
                    () -> assertEquals("CARVER", RecipientType.CARVER.name()),
                    () -> assertEquals("ADMIN",  RecipientType.ADMIN.name())
            );
        }

        @Test
        @DisplayName("RecipientType tiene el orden correcto: CLIENT, CARVER, ADMIN")
        void recipientType_ordinalesCorrectos() {
            assertAll(
                    () -> assertEquals(0, RecipientType.CLIENT.ordinal()),
                    () -> assertEquals(1, RecipientType.CARVER.ordinal()),
                    () -> assertEquals(2, RecipientType.ADMIN.ordinal())
            );
        }

        @Test
        @DisplayName("RecipientType cubre los 3 actores del sistema (cliente, cortador, admin)")
        void recipientType_cubresLosTresActoresDelSistema() {
            // Verificamos que existe un tipo por cada rol del sistema
            // Esto garantiza que el sistema puede notificar a todos los actores
            Set<String> actores = new HashSet<>();
            for (RecipientType tipo : RecipientType.values()) {
                actores.add(tipo.name());
            }
            assertAll(
                    () -> assertTrue(actores.contains("CLIENT"), "Debe existir un tipo para notificar al cliente"),
                    () -> assertTrue(actores.contains("CARVER"), "Debe existir un tipo para notificar al cortador"),
                    () -> assertTrue(actores.contains("ADMIN"),  "Debe existir un tipo para notificar al admin")
            );
        }
    }

    // =========================================================================
    // COMPATIBILIDAD CRUZADA — Tests que verifican consistencia entre enums
    // =========================================================================

    @Nested
    @DisplayName("Compatibilidad cruzada entre enums")
    class CompatibilidadCruzada {

        @Test
        @DisplayName("Role.ADMIN y RecipientType.ADMIN son independientes pero comparten semántica")
        void role_admin_y_recipientType_admin_sonIndependientes() {
            // Ambos representan al administrador pero son tipos distintos
            // No deben ser comparables con ==
            assertNotEquals(Role.ADMIN.getClass(), RecipientType.ADMIN.getClass(),
                    "Role y RecipientType son clases distintas — no se pueden comparar directamente");
            // Pero comparten el mismo displayName por diseño del sistema
            assertEquals(Role.ADMIN.getDisplayName(), RecipientType.ADMIN.getDisplayName(),
                    "Role.ADMIN y RecipientType.ADMIN deben tener el mismo displayName 'Administrador'");
        }

        @Test
        @DisplayName("Role.CLIENT y RecipientType.CLIENT comparten displayName por diseño")
        void role_client_y_recipientType_client_compartenDisplayName() {
            assertEquals(Role.CLIENT.getDisplayName(), RecipientType.CLIENT.getDisplayName(),
                    "Role.CLIENT y RecipientType.CLIENT deben tener el mismo displayName 'Cliente'");
        }

        @Test
        @DisplayName("Ningún displayName está duplicado dentro de su propio enum")
        void cadaEnum_noTieneDisplayNamesDuplicados() {
            // Role
            long rolesUnicos = java.util.Arrays.stream(Role.values())
                    .map(Role::getDisplayName).distinct().count();
            assertEquals(Role.values().length, rolesUnicos,
                    "Role no debe tener displayNames duplicados");

            // Status
            long statusUnicos = java.util.Arrays.stream(Status.values())
                    .map(Status::getDisplayName).distinct().count();
            assertEquals(Status.values().length, statusUnicos,
                    "Status no debe tener displayNames duplicados");

            // NotificationType
            long notifUnicos = java.util.Arrays.stream(NotificationType.values())
                    .map(NotificationType::getDisplayName).distinct().count();
            assertEquals(NotificationType.values().length, notifUnicos,
                    "NotificationType no debe tener displayNames duplicados");

            // RecipientType
            long recipientUnicos = java.util.Arrays.stream(RecipientType.values())
                    .map(RecipientType::getDisplayName).distinct().count();
            assertEquals(RecipientType.values().length, recipientUnicos,
                    "RecipientType no debe tener displayNames duplicados");
        }
    }
}