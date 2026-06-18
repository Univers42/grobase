package com.hambooking.backend.service;

import com.hambooking.backend.dto.reservation.CreateReservationDTO;
import com.hambooking.backend.dto.reservation.ReservationResponseDTO;
import com.hambooking.backend.dto.reservation.UpdateReservationDTO;
import com.hambooking.backend.exception.BusinessRuleException;
import com.hambooking.backend.exception.ReservationLimitExceededException;
import com.hambooking.backend.exception.ResourceNotFoundException;
import com.hambooking.backend.exception.TimeSlotNotAvailableException;
import com.hambooking.backend.model.entity.Carver;
import com.hambooking.backend.model.entity.Reservation;
import com.hambooking.backend.model.entity.Service;
import com.hambooking.backend.model.entity.User;
import com.hambooking.backend.model.enums.NotificationType;
import com.hambooking.backend.model.enums.Status;
import com.hambooking.backend.repository.CarverRepository;
import com.hambooking.backend.repository.ReservationRepository;
import com.hambooking.backend.repository.ServiceRepository;
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
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
@DisplayName("ReservationService - Tests Unitarios")
class ReservationServiceTest {

    @Mock
    private ReservationRepository reservationRepository;
    @Mock
    private UserRepository userRepository;
    @Mock
    private CarverRepository carverRepository;
    @Mock
    private ServiceRepository serviceRepository;
    @Mock
    private NotificationService notificationService;

    @InjectMocks
    private ReservationService reservationService;

    private User client;
    private Carver carver;
    private Service serviceEntity;
    private Reservation reservation;
    private CreateReservationDTO createRequest;

    @BeforeEach
    void setUp() {
        client = new User();
        client.setId(1L);
        client.setFirstName("Juan");
        client.setLastName("Perez");

        User carverUser = new User();
        carverUser.setFirstName("Carlos");
        carverUser.setLastName("Cortador");

        carver = new Carver();
        carver.setId(2L);
        carver.setIsActive(true);
        carver.setUser(carverUser);

        serviceEntity = new Service();
        serviceEntity.setId(3L);
        serviceEntity.setName("Corte Jamon");
        serviceEntity.setDurationMinutes(60);

        // Lunes 9 de marzo de 2026
        LocalDate monday = LocalDate.of(2026, 3, 9);

        reservation = new Reservation();
        reservation.setId(10L);
        reservation.setClient(client);
        reservation.setCarver(carver);
        reservation.setService(serviceEntity);
        reservation.setReservationDate(monday);
        reservation.setStartTime(LocalTime.of(10, 0));
        reservation.setEndTime(LocalTime.of(11, 0));
        reservation.setStatus(Status.PENDING);

        createRequest = new CreateReservationDTO();
        createRequest.setClientId(1L);
        createRequest.setCarverId(2L);
        createRequest.setServiceId(3L);
        createRequest.setReservationDate(monday);
        createRequest.setStartTime(LocalTime.of(10, 0));
        createRequest.setNotes("Notas de prueba");
    }

    @Nested
    @DisplayName("1. createReservation")
    class CreateReservation {

        @Test
        @DisplayName("Debe crear una reserva con éxito")
        void success() {
            when(userRepository.findById(1L)).thenReturn(Optional.of(client));
            when(carverRepository.findById(2L)).thenReturn(Optional.of(carver));
            when(serviceRepository.findById(3L)).thenReturn(Optional.of(serviceEntity));
            when(reservationRepository.countActiveReservationsByClientAndDate(client, createRequest.getReservationDate())).thenReturn(0);
            when(reservationRepository.sumActiveMinutesByCarverAndDate(carver, createRequest.getReservationDate())).thenReturn(0);
            when(reservationRepository.findByCarverAndReservationDateAndStatusIn(any(), any(), any())).thenReturn(List.of());
            when(reservationRepository.save(any(Reservation.class))).thenReturn(reservation);

            ReservationResponseDTO response = reservationService.createReservation(createRequest);

            assertNotNull(response);
            assertEquals(10L, response.getId());
            verify(reservationRepository).save(any(Reservation.class));
            verify(notificationService).sendReservationNotification(reservation, NotificationType.CREATED);
        }

        @Test
        @DisplayName("Lanza excepción si el cortador no está activo")
        void carverNotActive() {
            carver.setIsActive(false);
            when(userRepository.findById(1L)).thenReturn(Optional.of(client));
            when(carverRepository.findById(2L)).thenReturn(Optional.of(carver));
            when(serviceRepository.findById(3L)).thenReturn(Optional.of(serviceEntity));

            assertThrows(BusinessRuleException.class, () -> reservationService.createReservation(createRequest));
        }

        @Test
        @DisplayName("Lanza excepción si la reserva es en fin de semana")
        void weekendReservation() {
            createRequest.setReservationDate(LocalDate.of(2026, 3, 14)); // Sábado
            when(userRepository.findById(1L)).thenReturn(Optional.of(client));
            when(carverRepository.findById(2L)).thenReturn(Optional.of(carver));
            when(serviceRepository.findById(3L)).thenReturn(Optional.of(serviceEntity));

            assertThrows(BusinessRuleException.class, () -> reservationService.createReservation(createRequest));
        }

        @Test
        @DisplayName("Lanza excepción si está fuera del horario laboral")
        void outsideWorkingHours() {
            createRequest.setStartTime(LocalTime.of(9, 0)); // Antes de abrir
            when(userRepository.findById(1L)).thenReturn(Optional.of(client));
            when(carverRepository.findById(2L)).thenReturn(Optional.of(carver));
            when(serviceRepository.findById(3L)).thenReturn(Optional.of(serviceEntity));

            assertThrows(BusinessRuleException.class, () -> reservationService.createReservation(createRequest));
        }

        @Test
        @DisplayName("Lanza excepción si el cliente supera su límite diario")
        void clientLimitExceeded() {
            when(userRepository.findById(1L)).thenReturn(Optional.of(client));
            when(carverRepository.findById(2L)).thenReturn(Optional.of(carver));
            when(serviceRepository.findById(3L)).thenReturn(Optional.of(serviceEntity));
            when(reservationRepository.countActiveReservationsByClientAndDate(client, createRequest.getReservationDate())).thenReturn(2);

            assertThrows(ReservationLimitExceededException.class, () -> reservationService.createReservation(createRequest));
        }

        @Test
        @DisplayName("Lanza excepción si hay solapamiento horario")
        void timeSlotNotAvailable() {
            when(userRepository.findById(1L)).thenReturn(Optional.of(client));
            when(carverRepository.findById(2L)).thenReturn(Optional.of(carver));
            when(serviceRepository.findById(3L)).thenReturn(Optional.of(serviceEntity));
            when(reservationRepository.countActiveReservationsByClientAndDate(client, createRequest.getReservationDate())).thenReturn(0);
            when(reservationRepository.sumActiveMinutesByCarverAndDate(carver, createRequest.getReservationDate())).thenReturn(0);
            
            Reservation existing = new Reservation();
            existing.setStartTime(LocalTime.of(10, 30));
            existing.setEndTime(LocalTime.of(11, 30)); // Solapa con 10:00-11:00
            when(reservationRepository.findByCarverAndReservationDateAndStatusIn(any(), any(), any())).thenReturn(List.of(existing));

            assertThrows(TimeSlotNotAvailableException.class, () -> reservationService.createReservation(createRequest));
        }
    }

    @Nested
    @DisplayName("2. confirmReservation")
    class ConfirmReservation {
        @Test
        @DisplayName("Debe confirmar una reserva PENDING")
        void success() {
            when(reservationRepository.findById(10L)).thenReturn(Optional.of(reservation));
            when(reservationRepository.save(any(Reservation.class))).thenReturn(reservation);

            ReservationResponseDTO response = reservationService.confirmReservation(10L);

            assertEquals(Status.CONFIRMED, reservation.getStatus());
            assertNotNull(response);
            verify(reservationRepository).save(reservation);
        }

        @Test
        @DisplayName("Lanza excepción si no es PENDING")
        void notPending() {
            reservation.setStatus(Status.CONFIRMED);
            when(reservationRepository.findById(10L)).thenReturn(Optional.of(reservation));

            assertThrows(BusinessRuleException.class, () -> reservationService.confirmReservation(10L));
        }
    }

    @Nested
    @DisplayName("3. updateReservation")
    class UpdateReservation {
        @Test
        @DisplayName("Debe actualizar reserva exitosamente")
        void success() {
            UpdateReservationDTO updateDTO = new UpdateReservationDTO();
            updateDTO.setReservationDate(LocalDate.of(2026, 3, 10)); // Martes
            updateDTO.setStartTime(LocalTime.of(12, 0));
            updateDTO.setNotes("Nueva nota");

            when(reservationRepository.findById(10L)).thenReturn(Optional.of(reservation));
            when(reservationRepository.findByCarverAndReservationDateAndStatusIn(any(), any(), any())).thenReturn(List.of());
            when(reservationRepository.save(any(Reservation.class))).thenReturn(reservation);

            ReservationResponseDTO response = reservationService.updateReservation(10L, updateDTO);

            assertEquals(LocalTime.of(12, 0), reservation.getStartTime());
            verify(notificationService).sendReservationNotification(reservation, NotificationType.MODIFIED);
            assertNotNull(response);
        }
    }

    @Nested
    @DisplayName("4. cancelReservation")
    class CancelReservation {
        @Test
        @DisplayName("Debe cancelar exitosamente")
        void success() {
            when(reservationRepository.findById(10L)).thenReturn(Optional.of(reservation));
            when(reservationRepository.save(any(Reservation.class))).thenReturn(reservation);

            reservationService.cancelReservation(10L);

            assertEquals(Status.CANCELLED, reservation.getStatus());
            verify(notificationService).sendReservationNotification(reservation, NotificationType.CANCELLED);
        }

        @Test
        @DisplayName("Lanza excepción si ya está completada")
        void alreadyCompleted() {
            reservation.setStatus(Status.COMPLETED);
            when(reservationRepository.findById(10L)).thenReturn(Optional.of(reservation));

            assertThrows(BusinessRuleException.class, () -> reservationService.cancelReservation(10L));
        }
    }
}
