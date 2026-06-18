package com.hambooking.backend.repository;

import com.hambooking.backend.model.entity.Notification;
import com.hambooking.backend.model.entity.Reservation;
import com.hambooking.backend.model.enums.NotificationType;
import com.hambooking.backend.model.enums.RecipientType;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/**
 * Tests unitarios para NotificationRepository usando Mockito.
 *
 * NotificationRepository cierra el ciclo de la FASE 3 — repositories.
 * Consolida todos los patrones vistos hasta ahora:
 *
 *   - Filtro por entidad relacionada  → findByReservation (como CarverRepository)
 *   - Filtro por enum                 → findByRecipientType, findByNotificationType
 *   - Filtro combinado entidad + enum → findByReservationAndNotificationType
 *   - @Query escalar                  → countByReservation (como ReservationRepository)
 *
 * Particularidad de Notification:
 *   La relación con Reservation es NULLABLE — una notificación genérica
 *   del sistema puede no tener reserva asociada. Los tests reflejan
 *   ambos escenarios (con y sin reserva).
 */
@ExtendWith(MockitoExtension.class)
@DisplayName("NotificationRepository — Tests unitarios con Mockito")
class NotificationRepositoryTest {

    @Mock
    private NotificationRepository notificationRepository;

    // =========================================================================
    // MÉTODOS AUXILIARES
    // =========================================================================

    /**
     * Construye una notificación vinculada a una reserva.
     */
    private Notification buildNotification(Reservation reservation,
                                           RecipientType recipientType,
                                           String recipientEmail,
                                           NotificationType notificationType) {
        Notification n = new Notification();
        n.setId(1L);
        n.setReservation(reservation);
        n.setRecipientType(recipientType);
        n.setRecipientEmail(recipientEmail);
        n.setNotificationType(notificationType);
        n.setSubject("Asunto de prueba");
        n.setMessage("Mensaje de prueba para el test");
        n.setIsSent(true);
        return n;
    }

    /**
     * Construye una notificación genérica SIN reserva asociada (reservation = null).
     */
    private Notification buildGenericNotification(RecipientType recipientType,
                                                  String recipientEmail,
                                                  NotificationType notificationType) {
        Notification n = new Notification();
        n.setId(99L);
        n.setReservation(null);   // nullable — notificación genérica del sistema
        n.setRecipientType(recipientType);
        n.setRecipientEmail(recipientEmail);
        n.setNotificationType(notificationType);
        n.setSubject("Notificación del sistema");
        n.setMessage("Mensaje del sistema sin reserva asociada");
        n.setIsSent(true);
        return n;
    }

    /**
     * Crea un stub mínimo de Reservation para los tests que la necesitan como FK.
     */
    private Reservation buildReservationStub(Long id) {
        Reservation r = new Reservation();
        r.setId(id);
        return r;
    }

    // =========================================================================
    // 1. findByReservation
    // =========================================================================

    @Nested
    @DisplayName("1. findByReservation")
    class FindByReservation {

        @Test
        @DisplayName("Devuelve las 3 notificaciones generadas para una reserva (CLIENT, CARVER, ADMIN)")
        void dadoReservaConNotificaciones_devuelveTres() {
            // GIVEN — una reserva genera 3 notificaciones: una por destinatario
            Reservation reservation = buildReservationStub(1L);

            Notification nClient = buildNotification(reservation,
                    RecipientType.CLIENT, "cliente@test.com", NotificationType.CREATED);
            Notification nCarver = buildNotification(reservation,
                    RecipientType.CARVER, "cortador@test.com", NotificationType.CREATED);
            nCarver.setId(2L);
            Notification nAdmin = buildNotification(reservation,
                    RecipientType.ADMIN, "admin@hambooking.com", NotificationType.CREATED);
            nAdmin.setId(3L);

            when(notificationRepository.findByReservation(reservation))
                    .thenReturn(List.of(nClient, nCarver, nAdmin));

            // WHEN
            List<Notification> resultado = notificationRepository.findByReservation(reservation);

            // THEN
            assertEquals(3, resultado.size(),
                    "Cada evento de reserva genera 3 notificaciones (CLIENT, CARVER, ADMIN)");
            verify(notificationRepository).findByReservation(reservation);
        }

        @Test
        @DisplayName("Devuelve lista vacía cuando la reserva no tiene notificaciones")
        void dadoReservaSinNotificaciones_devuelveListaVacia() {
            // GIVEN
            Reservation reservation = buildReservationStub(2L);
            when(notificationRepository.findByReservation(reservation)).thenReturn(List.of());

            // WHEN + THEN
            assertTrue(notificationRepository.findByReservation(reservation).isEmpty());
        }
    }

    // =========================================================================
    // 2. findByReservationAndNotificationType
    // =========================================================================

    @Nested
    @DisplayName("2. findByReservationAndNotificationType")
    class FindByReservationAndNotificationType {

        @Test
        @DisplayName("Devuelve solo las notificaciones CANCELLED de una reserva concreta")
        void dadoReservaYTipoCancelled_devuelveSoloCancelaciones() {
            // GIVEN
            Reservation reservation = buildReservationStub(3L);
            Notification nClient = buildNotification(reservation,
                    RecipientType.CLIENT, "cliente@test.com", NotificationType.CANCELLED);
            Notification nCarver = buildNotification(reservation,
                    RecipientType.CARVER, "cortador@test.com", NotificationType.CANCELLED);
            nCarver.setId(2L);

            when(notificationRepository.findByReservationAndNotificationType(
                    reservation, NotificationType.CANCELLED))
                    .thenReturn(List.of(nClient, nCarver));

            // WHEN
            List<Notification> resultado = notificationRepository
                    .findByReservationAndNotificationType(reservation, NotificationType.CANCELLED);

            // THEN
            assertEquals(2, resultado.size());
            assertTrue(resultado.stream()
                    .allMatch(n -> n.getNotificationType() == NotificationType.CANCELLED));
        }

        @Test
        @DisplayName("Devuelve lista vacía cuando esa reserva no tiene ese tipo de notificación")
        void dadoReservaSinEseTipo_devuelveListaVacia() {
            // GIVEN
            Reservation reservation = buildReservationStub(4L);
            when(notificationRepository.findByReservationAndNotificationType(
                    reservation, NotificationType.REMINDER))
                    .thenReturn(List.of());

            // WHEN + THEN
            assertTrue(notificationRepository
                    .findByReservationAndNotificationType(reservation, NotificationType.REMINDER)
                    .isEmpty());
        }
    }

    // =========================================================================
    // 3. findByRecipientEmail
    // =========================================================================

    @Nested
    @DisplayName("3. findByRecipientEmail")
    class FindByRecipientEmail {

        @Test
        @DisplayName("Devuelve todas las notificaciones recibidas por un email")
        void dadoEmailExistente_devuelveHistorialDelDestinatario() {
            // GIVEN — el cliente recibió notificaciones de dos reservas distintas
            Reservation r1 = buildReservationStub(1L);
            Reservation r2 = buildReservationStub(2L);
            Notification n1 = buildNotification(r1,
                    RecipientType.CLIENT, "juan@test.com", NotificationType.CREATED);
            Notification n2 = buildNotification(r2,
                    RecipientType.CLIENT, "juan@test.com", NotificationType.CANCELLED);
            n2.setId(2L);

            when(notificationRepository.findByRecipientEmail("juan@test.com"))
                    .thenReturn(List.of(n1, n2));

            // WHEN
            List<Notification> resultado = notificationRepository
                    .findByRecipientEmail("juan@test.com");

            // THEN
            assertEquals(2, resultado.size());
            assertTrue(resultado.stream()
                    .allMatch(n -> "juan@test.com".equals(n.getRecipientEmail())));
        }

        @Test
        @DisplayName("Devuelve lista vacía para un email sin notificaciones")
        void dadoEmailSinNotificaciones_devuelveListaVacia() {
            // GIVEN
            when(notificationRepository.findByRecipientEmail("nuevo@test.com"))
                    .thenReturn(List.of());

            // WHEN + THEN
            assertTrue(notificationRepository
                    .findByRecipientEmail("nuevo@test.com").isEmpty());
        }
    }

    // =========================================================================
    // 4. findByRecipientType
    // =========================================================================

    @Nested
    @DisplayName("4. findByRecipientType")
    class FindByRecipientType {

        @Test
        @DisplayName("Devuelve todas las notificaciones enviadas al ADMIN")
        void dadoTipoAdmin_devuelveNotificacionesDelAdmin() {
            // GIVEN — el admin recibe copia de todos los eventos
            Reservation r1 = buildReservationStub(1L);
            Reservation r2 = buildReservationStub(2L);
            Notification n1 = buildNotification(r1,
                    RecipientType.ADMIN, "admin@hambooking.com", NotificationType.CREATED);
            Notification n2 = buildNotification(r2,
                    RecipientType.ADMIN, "admin@hambooking.com", NotificationType.CANCELLED);
            n2.setId(2L);

            when(notificationRepository.findByRecipientType(RecipientType.ADMIN))
                    .thenReturn(List.of(n1, n2));

            // WHEN
            List<Notification> resultado = notificationRepository
                    .findByRecipientType(RecipientType.ADMIN);

            // THEN
            assertEquals(2, resultado.size());
            assertTrue(resultado.stream()
                    .allMatch(n -> n.getRecipientType() == RecipientType.ADMIN));
        }

        @Test
        @DisplayName("Devuelve lista vacía cuando no hay notificaciones para ese tipo")
        void dadoTipoSinNotificaciones_devuelveListaVacia() {
            // GIVEN
            when(notificationRepository.findByRecipientType(RecipientType.CARVER))
                    .thenReturn(List.of());

            // WHEN + THEN
            assertTrue(notificationRepository
                    .findByRecipientType(RecipientType.CARVER).isEmpty());
        }
    }

    // =========================================================================
    // 5. findByNotificationType
    // =========================================================================

    @Nested
    @DisplayName("5. findByNotificationType")
    class FindByNotificationType {

        @Test
        @DisplayName("Devuelve todas las notificaciones de tipo REMINDER")
        void dadoTipoReminder_devuelveRecordatorios() {
            // GIVEN
            Reservation r1 = buildReservationStub(1L);
            Reservation r2 = buildReservationStub(2L);
            Notification n1 = buildNotification(r1,
                    RecipientType.CLIENT, "c1@test.com", NotificationType.REMINDER);
            Notification n2 = buildNotification(r2,
                    RecipientType.CLIENT, "c2@test.com", NotificationType.REMINDER);
            n2.setId(2L);

            when(notificationRepository.findByNotificationType(NotificationType.REMINDER))
                    .thenReturn(List.of(n1, n2));

            // WHEN
            List<Notification> resultado = notificationRepository
                    .findByNotificationType(NotificationType.REMINDER);

            // THEN
            assertEquals(2, resultado.size());
            assertTrue(resultado.stream()
                    .allMatch(n -> n.getNotificationType() == NotificationType.REMINDER));
        }

        @Test
        @DisplayName("Devuelve lista vacía cuando no hay notificaciones de ese tipo")
        void dadoTipoSinNotificaciones_devuelveListaVacia() {
            // GIVEN
            when(notificationRepository.findByNotificationType(NotificationType.MODIFIED))
                    .thenReturn(List.of());

            // WHEN + THEN
            assertTrue(notificationRepository
                    .findByNotificationType(NotificationType.MODIFIED).isEmpty());
        }
    }

    // =========================================================================
    // 6. countByReservation  ← @Query JPQL escalar
    // =========================================================================

    @Nested
    @DisplayName("6. countByReservation (@Query)")
    class CountByReservation {

        @Test
        @DisplayName("Devuelve 0 cuando la reserva no tiene notificaciones")
        void sinNotificaciones_devuelveCero() {
            // GIVEN
            Reservation reservation = buildReservationStub(5L);
            when(notificationRepository.countByReservation(reservation)).thenReturn(0L);

            // WHEN + THEN
            assertEquals(0L, notificationRepository.countByReservation(reservation));
        }

        @Test
        @DisplayName("Devuelve 3 cuando se han generado las 3 notificaciones esperadas")
        void tresNotificaciones_devuelveTres() {
            // GIVEN — tras crear una reserva el Service genera 3 notifs (CLIENT + CARVER + ADMIN)
            Reservation reservation = buildReservationStub(6L);
            when(notificationRepository.countByReservation(reservation)).thenReturn(3L);

            // WHEN
            long count = notificationRepository.countByReservation(reservation);

            // THEN
            assertEquals(3L, count,
                    "Cada evento de reserva debe generar exactamente 3 notificaciones");
        }

        @Test
        @DisplayName("Devuelve 6 cuando se han generado notificaciones de creación y cancelación")
        void seisNotificaciones_dosEventos() {
            // GIVEN — creación (3) + cancelación (3) = 6 notificaciones para esa reserva
            Reservation reservation = buildReservationStub(7L);
            when(notificationRepository.countByReservation(reservation)).thenReturn(6L);

            // WHEN + THEN
            assertEquals(6L, notificationRepository.countByReservation(reservation));
        }
    }

    // =========================================================================
    // 7. Notificación sin reserva asociada (reservation = null)
    // =========================================================================

    @Nested
    @DisplayName("7. Notificación genérica sin reserva (nullable)")
    class NotificacionGenerica {

        @Test
        @DisplayName("save() persiste una notificación con reservation null")
        void dadoNotificacionSinReserva_seGuardaCorrectamente() {
            // GIVEN — notificación genérica del sistema (sin reserva)
            Notification sinReserva = buildGenericNotification(
                    RecipientType.ADMIN, "admin@hambooking.com", NotificationType.CREATED);
            Notification guardada = buildGenericNotification(
                    RecipientType.ADMIN, "admin@hambooking.com", NotificationType.CREATED);
            guardada.setId(100L);

            when(notificationRepository.save(sinReserva)).thenReturn(guardada);

            // WHEN
            Notification resultado = notificationRepository.save(sinReserva);

            // THEN
            assertNotNull(resultado.getId());
            assertNull(resultado.getReservation(),
                    "Una notificación genérica puede existir sin reserva asociada");
        }

        @Test
        @DisplayName("findById() recupera una notificación con reservation null")
        void findById_devuelveNotificacionConReservationNull() {
            // GIVEN
            Notification notif = buildGenericNotification(
                    RecipientType.CLIENT, "aviso@test.com", NotificationType.REMINDER);
            notif.setId(50L);
            when(notificationRepository.findById(50L)).thenReturn(Optional.of(notif));

            // WHEN
            Optional<Notification> resultado = notificationRepository.findById(50L);

            // THEN
            assertTrue(resultado.isPresent());
            assertNull(resultado.get().getReservation(),
                    "El campo reservation puede ser null — relación nullable");
        }
    }

    // =========================================================================
    // 8. OPERACIONES CRUD heredadas de JpaRepository (smoke tests)
    // =========================================================================

    @Nested
    @DisplayName("8. Operaciones CRUD heredadas")
    class OperacionesCrud {

        @Test
        @DisplayName("save() devuelve la notificación con id asignado")
        void save_devuelveNotificacionConId() {
            // GIVEN
            Reservation reservation = buildReservationStub(1L);
            Notification sinId = buildNotification(reservation,
                    RecipientType.CLIENT, "nuevo@test.com", NotificationType.CREATED);
            sinId.setId(null);
            Notification conId = buildNotification(reservation,
                    RecipientType.CLIENT, "nuevo@test.com", NotificationType.CREATED);
            conId.setId(10L);

            when(notificationRepository.save(sinId)).thenReturn(conId);

            // WHEN
            Notification guardada = notificationRepository.save(sinId);

            // THEN
            assertNotNull(guardada.getId());
            assertEquals(10L, guardada.getId());
            assertTrue(guardada.getIsSent());
        }

        @Test
        @DisplayName("count() devuelve el total de notificaciones en el sistema")
        void count_devuelveTotalDeNotificaciones() {
            // GIVEN
            when(notificationRepository.count()).thenReturn(12L);

            // WHEN + THEN
            assertEquals(12L, notificationRepository.count());
        }

        @Test
        @DisplayName("deleteById() se invoca exactamente una vez")
        void deleteById_seInvocaUnaVez() {
            // GIVEN
            doNothing().when(notificationRepository).deleteById(1L);

            // WHEN
            notificationRepository.deleteById(1L);

            // THEN
            verify(notificationRepository, times(1)).deleteById(1L);
        }
    }
}