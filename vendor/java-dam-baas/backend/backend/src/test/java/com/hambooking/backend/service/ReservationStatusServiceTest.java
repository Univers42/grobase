package com.hambooking.backend.service;

import com.hambooking.backend.model.enums.Status;
import com.hambooking.backend.repository.ReservationRepository;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.time.LocalDate;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
@DisplayName("ReservationStatusService - Tests Unitarios")
class ReservationStatusServiceTest {

    @Mock
    private ReservationRepository reservationRepository;

    @InjectMocks
    private ReservationStatusService reservationStatusService;

    @Test
    @DisplayName("Actualiza estados pasados correctamente")
    void actualizarEstadosPasados() {
        when(reservationRepository.updateStatusForPastReservations(eq(Status.CANCELLED), eq(Status.PENDING), any(LocalDate.class))).thenReturn(5);
        when(reservationRepository.updateStatusForPastReservations(eq(Status.COMPLETED), eq(Status.CONFIRMED), any(LocalDate.class))).thenReturn(10);

        reservationStatusService.actualizarEstadosPasados();

        verify(reservationRepository).updateStatusForPastReservations(eq(Status.CANCELLED), eq(Status.PENDING), any(LocalDate.class));
        verify(reservationRepository).updateStatusForPastReservations(eq(Status.COMPLETED), eq(Status.CONFIRMED), any(LocalDate.class));
    }
}
