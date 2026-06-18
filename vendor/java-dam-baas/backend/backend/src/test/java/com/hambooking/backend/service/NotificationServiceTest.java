package com.hambooking.backend.service;

import com.hambooking.backend.dto.notification.NotificationResponseDTO;
import com.hambooking.backend.exception.ResourceNotFoundException;
import com.hambooking.backend.model.entity.Carver;
import com.hambooking.backend.model.entity.Notification;
import com.hambooking.backend.model.entity.Reservation;
import com.hambooking.backend.model.entity.Service;
import com.hambooking.backend.model.entity.User;
import com.hambooking.backend.model.enums.NotificationType;
import com.hambooking.backend.model.enums.RecipientType;
import com.hambooking.backend.model.enums.Role;
import com.hambooking.backend.repository.NotificationRepository;
import com.hambooking.backend.repository.UserRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.time.LocalDate;
import java.time.LocalTime;
import java.util.List;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
@DisplayName("NotificationService - Tests Unitarios")
class NotificationServiceTest {

    @Mock
    private NotificationRepository notificationRepository;

    @Mock
    private UserRepository userRepository;

    @InjectMocks
    private NotificationService notificationService;

    private Reservation reservation;
    private User client;
    private User carverUser;
    private Carver carver;

    @BeforeEach
    void setUp() {
        client = new User();
        client.setId(1L);
        client.setFirstName("Cliente");
        client.setLastName("Test");
        client.setEmail("cliente@test.com");

        carverUser = new User();
        carverUser.setId(2L);
        carverUser.setFirstName("Cortador");
        carverUser.setLastName("Test");
        carverUser.setEmail("cortador@test.com");

        carver = new Carver();
        carver.setUser(carverUser);

        Service service = new Service();
        service.setName("Corte");

        reservation = new Reservation();
        reservation.setId(10L);
        reservation.setClient(client);
        reservation.setCarver(carver);
        reservation.setService(service);
        reservation.setReservationDate(LocalDate.of(2026, 3, 9));
        reservation.setStartTime(LocalTime.of(10, 0));
    }

    @Nested
    @DisplayName("1. sendReservationNotification")
    class SendReservationNotification {

        @Test
        @DisplayName("Envia 3 notificaciones al crear reserva")
        void sendThreeNotifications() {
            User admin = new User();
            admin.setEmail("admin@test.com");

            when(userRepository.findByRole(Role.ADMIN)).thenReturn(List.of(admin));

            notificationService.sendReservationNotification(reservation, NotificationType.CREATED);

            verify(notificationRepository, times(3)).save(any(Notification.class));
            verify(userRepository).findByRole(Role.ADMIN);
        }

        @Test
        @DisplayName("Fallback a email por defecto si no hay admin")
        void noAdminFallback() {
            when(userRepository.findByRole(Role.ADMIN)).thenReturn(List.of());

            notificationService.sendReservationNotification(reservation, NotificationType.MODIFIED);

            verify(notificationRepository, times(3)).save(any(Notification.class));
        }
    }

    @Nested
    @DisplayName("2. Consultas de notificaciones")
    class Queries {

        private Notification notif;

        @BeforeEach
        void initNotif() {
            notif = Notification.builder()
                    .id(1L)
                    .recipientType(RecipientType.CLIENT)
                    .notificationType(NotificationType.CREATED)
                    .message("Test")
                    .isSent(true)
                    .build();
        }

        @Test
        @DisplayName("Lista todas")
        void listAll() {
            when(notificationRepository.findAll()).thenReturn(List.of(notif));
            List<NotificationResponseDTO> list = notificationService.listAllNotifications();
            assertEquals(1, list.size());
        }

        @Test
        @DisplayName("Lista por usuario con exito")
        void listByUser() {
            when(userRepository.findById(1L)).thenReturn(Optional.of(client));
            when(notificationRepository.findByRecipientEmail(client.getEmail())).thenReturn(List.of(notif));

            List<NotificationResponseDTO> list = notificationService.listByUser(1L);

            assertEquals(1, list.size());
        }

        @Test
        @DisplayName("Falla al listar por usuario si no existe")
        void listByUserNotFound() {
            when(userRepository.findById(1L)).thenReturn(Optional.empty());

            assertThrows(ResourceNotFoundException.class, () -> notificationService.listByUser(1L));
        }

        @Test
        @DisplayName("Obtiene notificaciones por reserva")
        void getNotificationsByReservation() {
            when(notificationRepository.findByReservation(reservation)).thenReturn(List.of(notif));

            List<NotificationResponseDTO> list = notificationService.getNotificationsByReservation(reservation);

            assertEquals(1, list.size());
        }
    }
}
