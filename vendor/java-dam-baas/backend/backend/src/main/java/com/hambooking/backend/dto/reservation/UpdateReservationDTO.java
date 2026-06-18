package com.hambooking.backend.dto.reservation;

import jakarta.validation.constraints.Future;
import jakarta.validation.constraints.NotNull;

import java.time.LocalDate;
import java.time.LocalTime;

/**
 * Objeto de transferencia de datos para la actualización de una reserva existente.
 * Permite modificar únicamente los datos temporales y las observaciones de la cita.
 */
public class UpdateReservationDTO {

    /** Nueva fecha programada para la reserva. */
    @NotNull(message = "La fecha de reserva es obligatoria")
    @Future(message = "La fecha de reserva debe ser en el futuro")
    private LocalDate reservationDate;

    /** Nueva hora de inicio solicitada. */
    @NotNull(message = "La hora de inicio es obligatoria")
    private LocalTime startTime;

    /** Notas u observaciones actualizadas del cliente. */
    private String notes;

    /**
     * Constructor por defecto para Jackson.
     */
    public UpdateReservationDTO() {}

    /**
     * Constructor completo para la instanciación manual.
     * @param reservationDate Nueva fecha.
     * @param startTime Nueva hora.
     * @param notes Nuevas notas.
     */
    public UpdateReservationDTO(LocalDate reservationDate, LocalTime startTime, String notes) {
        this.reservationDate = reservationDate;
        this.startTime = startTime;
        this.notes = notes;
    }

    /** @return Fecha programada. */
    public LocalDate getReservationDate() { return reservationDate; }
    /** @param reservationDate Nueva fecha. */
    public void setReservationDate(LocalDate reservationDate) { this.reservationDate = reservationDate; }

    /** @return Hora de inicio. */
    public LocalTime getStartTime() { return startTime; }
    /** @param startTime Nueva hora. */
    public void setStartTime(LocalTime startTime) { this.startTime = startTime; }

    /** @return Notas del cliente. */
    public String getNotes() { return notes; }
    /** @param notes Nuevas notas. */
    public void setNotes(String notes) { this.notes = notes; }
}
