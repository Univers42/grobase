package com.hambooking.backend.dto.reservation;

import jakarta.validation.constraints.Future;
import jakarta.validation.constraints.NotNull;

import java.time.LocalDate;
import java.time.LocalTime;

/**
 * Objeto de transferencia de datos para la creación de una nueva reserva.
 * Contiene los identificadores de las entidades relacionadas y los datos temporales de la cita.
 */
public class CreateReservationDTO {

    /** Identificador del cliente que realiza la solicitud. */
    @NotNull(message = "El cliente es obligatorio")
    private Long clientId;

    /** Identificador del cortador seleccionado. */
    @NotNull(message = "El cortador es obligatorio")
    private Long carverId;

    /** Identificador del tipo de servicio contratado. */
    @NotNull(message = "El servicio es obligatorio")
    private Long serviceId;

    /** Fecha programada para la reserva (debe ser una fecha futura). */
    @NotNull(message = "La fecha de reserva es obligatoria")
    @Future(message = "La fecha de reserva debe ser en el futuro")
    private LocalDate reservationDate;

    /** Hora de inicio de la prestación del servicio. */
    @NotNull(message = "La hora de inicio es obligatoria")
    private LocalTime startTime;

    /** Observaciones opcionales proporcionadas por el cliente. */
    private String notes;

    /**
     * Constructor por defecto para Jackson.
     */
    public CreateReservationDTO() {}

    /**
     * Constructor completo para la instanciación manual.
     * @param clientId ID Cliente.
     * @param carverId ID Cortador.
     * @param serviceId ID Servicio.
     * @param reservationDate Fecha.
     * @param startTime Hora de inicio.
     * @param notes Notas adicionales.
     */
    public CreateReservationDTO(Long clientId, Long carverId, Long serviceId,
                                LocalDate reservationDate, LocalTime startTime, String notes) {
        this.clientId = clientId;
        this.carverId = carverId;
        this.serviceId = serviceId;
        this.reservationDate = reservationDate;
        this.startTime = startTime;
        this.notes = notes;
    }

    /** @return ID Cliente. */
    public Long getClientId() { return clientId; }
    /** @param clientId Nuevo ID Cliente. */
    public void setClientId(Long clientId) { this.clientId = clientId; }

    /** @return ID Cortador. */
    public Long getCarverId() { return carverId; }
    /** @param carverId Nuevo ID Cortador. */
    public void setCarverId(Long carverId) { this.carverId = carverId; }

    /** @return ID Servicio. */
    public Long getServiceId() { return serviceId; }
    /** @param serviceId Nuevo ID Servicio. */
    public void setServiceId(Long serviceId) { this.serviceId = serviceId; }

    /** @return Fecha de reserva. */
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
