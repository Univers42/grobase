package com.hambooking.backend.controller;

import com.hambooking.backend.dto.reservation.CreateReservationDTO;
import com.hambooking.backend.dto.reservation.ReservationResponseDTO;
import com.hambooking.backend.dto.reservation.UpdateReservationDTO;
import com.hambooking.backend.service.ReservationService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;

/**
 * Controlador REST para gestionar el ciclo de vida de las reservas.
 * Permite la creación, consulta, actualización, confirmación y cancelación de reservas.
 */
@RestController
@RequestMapping("/api/reservations")
@RequiredArgsConstructor
public class ReservationController {

    private final ReservationService reservationService;

    /**
     * Obtiene un listado de todas las reservas del sistema.
     *
     * @return ResponseEntity con la lista de todas las reservas.
     */
    @GetMapping
    public ResponseEntity<List<ReservationResponseDTO>> listAllReservations() {
        return ResponseEntity.ok(reservationService.listAllReservations());
    }

    /**
     * Lista las reservas realizadas por un cliente específico.
     *
     * @param clientId ID del cliente.
     * @return ResponseEntity con la lista de reservas del cliente indicado.
     */
    @GetMapping("/client/{clientId}")
    public ResponseEntity<List<ReservationResponseDTO>> listReservationsByClient(
            @PathVariable Long clientId) {
        return ResponseEntity.ok(reservationService.listReservationsByClient(clientId));
    }

    /**
     * Crea una nueva reserva.
     *
     * @param request DTO con los detalles de la nueva reserva.
     * @return ResponseEntity con los datos de la reserva creada y estado HTTP 201.
     */
    @PostMapping
    public ResponseEntity<ReservationResponseDTO> createReservation(
            @Valid @RequestBody CreateReservationDTO request) {
        return ResponseEntity.status(HttpStatus.CREATED)
                .body(reservationService.createReservation(request));
    }

    /**
     * Actualiza los datos de una reserva existente.
     *
     * @param id ID de la reserva a modificar.
     * @param request DTO con la nueva información de la reserva.
     * @return ResponseEntity con los datos de la reserva actualizada.
     */
    @PutMapping("/{id}")
    public ResponseEntity<ReservationResponseDTO> updateReservation(
            @PathVariable Long id,
            @Valid @RequestBody UpdateReservationDTO request) {
        return ResponseEntity.ok(reservationService.updateReservation(id, request));
    }

    /**
     * Confirma una reserva pendiente.
     *
     * @param id ID de la reserva a confirmar.
     * @return ResponseEntity con los datos de la reserva ya confirmada.
     */
    @PatchMapping("/{id}/confirm")
    public ResponseEntity<ReservationResponseDTO> confirmReservation(@PathVariable Long id) {
        return ResponseEntity.ok(reservationService.confirmReservation(id));
    }

    /**
     * Cancela una reserva del sistema.
     *
     * @param id ID de la reserva a cancelar.
     * @return ResponseEntity sin contenido (HTTP 204).
     */
    @PatchMapping("/{id}/cancel")
    public ResponseEntity<Void> cancelReservation(@PathVariable Long id) {
        reservationService.cancelReservation(id);
        return ResponseEntity.noContent().build();
    }
}