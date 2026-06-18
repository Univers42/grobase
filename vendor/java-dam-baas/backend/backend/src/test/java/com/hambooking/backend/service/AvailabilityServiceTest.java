package com.hambooking.backend.service;

import com.hambooking.backend.exception.BusinessRuleException;
import com.hambooking.backend.exception.ResourceNotFoundException;
import com.hambooking.backend.model.entity.Carver;
import com.hambooking.backend.model.entity.Reservation;
import com.hambooking.backend.model.entity.Service;
import com.hambooking.backend.model.enums.Status;
import com.hambooking.backend.repository.CarverRepository;
import com.hambooking.backend.repository.ReservationRepository;
import com.hambooking.backend.repository.ServiceRepository;
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
@DisplayName("AvailabilityService - Tests Unitarios")
class AvailabilityServiceTest {

    @Mock
    private ReservationRepository reservationRepository;
    @Mock
    private CarverRepository carverRepository;
    @Mock
    private ServiceRepository serviceRepository;

    @InjectMocks
    private AvailabilityService availabilityService;

    private Carver carver;
    private Service service30m;
    private Service service60m;
    private Service service120m;
    private LocalDate monday;

    @BeforeEach
    void setUp() {
        carver = new Carver();
        carver.setId(1L);
        carver.setIsActive(true);

        service30m = new Service();
        service30m.setId(1L);
        service30m.setDurationMinutes(30);

        service60m = new Service();
        service60m.setId(2L);
        service60m.setDurationMinutes(60);

        service120m = new Service();
        service120m.setId(3L);
        service120m.setDurationMinutes(120);

        monday = LocalDate.of(2026, 3, 9); // Lunes
    }

    @Nested
    @DisplayName("Cálculo de Slots Disponibles")
    class GetAvailableSlots {

        @Test
        @DisplayName("Genera 16 slots (10:00 a 17:30) para un servicio de 30 min sin reservas")
        void allSlotsAvailableFor30m() {
            when(carverRepository.findById(1L)).thenReturn(Optional.of(carver));
            when(serviceRepository.findById(1L)).thenReturn(Optional.of(service30m));
            when(reservationRepository.findByCarverAndReservationDateAndStatusIn(any(), any(), any())).thenReturn(List.of());

            List<LocalTime> slots = availabilityService.getAvailableSlots(1L, monday, 1L);

            assertEquals(16, slots.size(), "Deberían generarse 16 slots de 30 min entre 10:00 y 18:00");
            assertEquals(LocalTime.of(10, 0), slots.get(0));
            assertEquals(LocalTime.of(17, 30), slots.get(15));
        }

        @Test
        @DisplayName("Genera 15 slots (último a las 17:00) para un servicio de 60 min")
        void slotsAvailableFor60m() {
            when(carverRepository.findById(1L)).thenReturn(Optional.of(carver));
            when(serviceRepository.findById(2L)).thenReturn(Optional.of(service60m));
            when(reservationRepository.findByCarverAndReservationDateAndStatusIn(any(), any(), any())).thenReturn(List.of());

            List<LocalTime> slots = availabilityService.getAvailableSlots(1L, monday, 2L);

            assertEquals(15, slots.size());
            assertEquals(LocalTime.of(17, 0), slots.get(14));
        }

        @Test
        @DisplayName("Genera 13 slots (último a las 16:00) para un servicio de 120 min")
        void slotsAvailableFor120m() {
            when(carverRepository.findById(1L)).thenReturn(Optional.of(carver));
            when(serviceRepository.findById(3L)).thenReturn(Optional.of(service120m));
            when(reservationRepository.findByCarverAndReservationDateAndStatusIn(any(), any(), any())).thenReturn(List.of());

            List<LocalTime> slots = availabilityService.getAvailableSlots(1L, monday, 3L);

            assertEquals(13, slots.size());
            assertEquals(LocalTime.of(16, 0), slots.get(12));
        }

        @Test
        @DisplayName("Filtra slots solapados por reservas existentes")
        void filterOccupiedSlots() {
            Reservation existing = new Reservation();
            existing.setStartTime(LocalTime.of(10, 30));
            existing.setEndTime(LocalTime.of(11, 30));
            existing.setStatus(Status.CONFIRMED);

            when(carverRepository.findById(1L)).thenReturn(Optional.of(carver));
            when(serviceRepository.findById(2L)).thenReturn(Optional.of(service60m));
            when(reservationRepository.findByCarverAndReservationDateAndStatusIn(any(), any(), any())).thenReturn(List.of(existing));

            List<LocalTime> slots = availabilityService.getAvailableSlots(1L, monday, 2L);

            // Servicio 60m: 10:00 (solapa con 10:30), 10:30 (solapa), 11:00 (solapa).
            // De los 15 originales, se quitan 3. Quedan 12.
            assertEquals(12, slots.size());
            assertFalse(slots.contains(LocalTime.of(10, 0)));
            assertFalse(slots.contains(LocalTime.of(10, 30)));
            assertFalse(slots.contains(LocalTime.of(11, 0)));
            assertTrue(slots.contains(LocalTime.of(11, 30))); // Empieza justo cuando acaba
        }
    }

    @Nested
    @DisplayName("Validaciones de Reglas de Negocio")
    class BusinessRules {

        @Test
        @DisplayName("Lanza excepción si el cortador no existe")
        void carverNotFound() {
            when(carverRepository.findById(1L)).thenReturn(Optional.empty());

            assertThrows(ResourceNotFoundException.class, () -> availabilityService.getAvailableSlots(1L, monday, 1L));
        }

        @Test
        @DisplayName("Lanza excepción si el servicio no existe")
        void serviceNotFound() {
            when(carverRepository.findById(1L)).thenReturn(Optional.of(carver));
            when(serviceRepository.findById(1L)).thenReturn(Optional.empty());

            assertThrows(ResourceNotFoundException.class, () -> availabilityService.getAvailableSlots(1L, monday, 1L));
        }

        @Test
        @DisplayName("Lanza excepción si el cortador está inactivo")
        void carverInactive() {
            carver.setIsActive(false);
            when(carverRepository.findById(1L)).thenReturn(Optional.of(carver));
            when(serviceRepository.findById(1L)).thenReturn(Optional.of(service30m));

            assertThrows(BusinessRuleException.class, () -> availabilityService.getAvailableSlots(1L, monday, 1L));
        }

        @Test
        @DisplayName("Lanza excepción si se consulta un fin de semana")
        void weekendConsultation() {
            when(carverRepository.findById(1L)).thenReturn(Optional.of(carver));
            when(serviceRepository.findById(1L)).thenReturn(Optional.of(service30m));

            LocalDate saturday = LocalDate.of(2026, 3, 14);

            assertThrows(BusinessRuleException.class, () -> availabilityService.getAvailableSlots(1L, saturday, 1L));
        }
    }
}
