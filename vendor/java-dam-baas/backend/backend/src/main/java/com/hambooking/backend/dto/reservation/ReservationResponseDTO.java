package com.hambooking.backend.dto.reservation;

import com.hambooking.backend.model.enums.Status;

import java.time.LocalDate;
import java.time.LocalTime;
import java.time.LocalDateTime;

/**
 * Objeto de transferencia de datos para representar una reserva completa en las respuestas de la API.
 * Aplica una técnica de aplanamiento (flattening) para incluir nombres descriptivos de clientes,
 * cortadores y servicios, facilitando su visualización directa en el frontend sin peticiones adicionales.
 */
public class ReservationResponseDTO {

    /** Identificador único de la reserva. */
    private Long id;

    /** Identificador del cliente. */
    private Long clientId;

    /** Nombre del cliente. */
    private String clientFirstName;

    /** Apellidos del cliente. */
    private String clientLastName;

    /** Identificador del cortador profesional. */
    private Long carverId;

    /** Nombre del cortador. */
    private String carverFirstName;

    /** Apellidos del cortador. */
    private String carverLastName;

    /** Identificador del servicio contratado. */
    private Long serviceId;

    /** Nombre descriptivo del servicio. */
    private String serviceName;

    /** Duración estimada en minutos. */
    private Integer serviceDurationMinutes;

    /** Fecha programada de la cita. */
    private LocalDate reservationDate;

    /** Hora de inicio. */
    private LocalTime startTime;

    /** Hora estimada de finalización (calculada en el servidor). */
    private LocalTime endTime;

    /** Estado actual de la reserva (ej. PENDING, CONFIRMED). */
    private Status status;

    /** Notas u observaciones del cliente. */
    private String notes;

    /** Fecha y hora de creación del registro. */
    private LocalDateTime createdAt;

    /**
     * Constructor por defecto para la deserialización JSON.
     */
    public ReservationResponseDTO() {}

    /**
     * Constructor completo para el mapeo desde el servicio de negocio.
     * @param id ID.
     * @param clientId ID Cliente.
     * @param clientFirstName Nombre Cliente.
     * @param clientLastName Apellidos Cliente.
     * @param carverId ID Cortador.
     * @param carverFirstName Nombre Cortador.
     * @param carverLastName Apellidos Cortador.
     * @param serviceId ID Servicio.
     * @param serviceName Nombre Servicio.
     * @param serviceDurationMinutes Duración.
     * @param reservationDate Fecha.
     * @param startTime Inicio.
     * @param endTime Fin.
     * @param status Estado.
     * @param notes Notas.
     * @param createdAt Creación.
     */
    public ReservationResponseDTO(Long id,
                                  Long clientId, String clientFirstName, String clientLastName,
                                  Long carverId, String carverFirstName, String carverLastName,
                                  Long serviceId, String serviceName, Integer serviceDurationMinutes,
                                  LocalDate reservationDate, LocalTime startTime, LocalTime endTime,
                                  Status status, String notes, LocalDateTime createdAt) {
        this.id = id;
        this.clientId = clientId;
        this.clientFirstName = clientFirstName;
        this.clientLastName = clientLastName;
        this.carverId = carverId;
        this.carverFirstName = carverFirstName;
        this.carverLastName = carverLastName;
        this.serviceId = serviceId;
        this.serviceName = serviceName;
        this.serviceDurationMinutes = serviceDurationMinutes;
        this.reservationDate = reservationDate;
        this.startTime = startTime;
        this.endTime = endTime;
        this.status = status;
        this.notes = notes;
        this.createdAt = createdAt;
    }

    /** @return ID de la reserva. */
    public Long getId() { return id; }
    /** @param id Nuevo ID. */
    public void setId(Long id) { this.id = id; }

    /** @return ID Cliente. */
    public Long getClientId() { return clientId; }
    /** @param clientId Nuevo ID Cliente. */
    public void setClientId(Long clientId) { this.clientId = clientId; }

    /** @return Nombre Cliente. */
    public String getClientFirstName() { return clientFirstName; }
    /** @param clientFirstName Nuevo nombre. */
    public void setClientFirstName(String clientFirstName) { this.clientFirstName = clientFirstName; }

    /** @return Apellidos Cliente. */
    public String getClientLastName() { return clientLastName; }
    /** @param clientLastName Nuevos apellidos. */
    public void setClientLastName(String clientLastName) { this.clientLastName = clientLastName; }

    /** @return ID Cortador. */
    public Long getCarverId() { return carverId; }
    /** @param carverId Nuevo ID Cortador. */
    public void setCarverId(Long carverId) { this.carverId = carverId; }

    /** @return Nombre Cortador. */
    public String getCarverFirstName() { return carverFirstName; }
    /** @param carverFirstName Nuevo nombre. */
    public void setCarverFirstName(String carverFirstName) { this.carverFirstName = carverFirstName; }

    /** @return Apellidos Cortador. */
    public String getCarverLastName() { return carverLastName; }
    /** @param carverLastName Nuevos apellidos. */
    public void setCarverLastName(String carverLastName) { this.carverLastName = carverLastName; }

    /** @return ID Servicio. */
    public Long getServiceId() { return serviceId; }
    /** @param serviceId Nuevo ID Servicio. */
    public void setServiceId(Long serviceId) { this.serviceId = serviceId; }

    /** @return Nombre Servicio. */
    public String getServiceName() { return serviceName; }
    /** @param serviceName Nuevo nombre. */
    public void setServiceName(String serviceName) { this.serviceName = serviceName; }

    /** @return Duración en minutos. */
    public Integer getServiceDurationMinutes() { return serviceDurationMinutes; }
    /** @param serviceDurationMinutes Nueva duración. */
    public void setServiceDurationMinutes(Integer serviceDurationMinutes) { this.serviceDurationMinutes = serviceDurationMinutes; }

    /** @return Fecha programada. */
    public LocalDate getReservationDate() { return reservationDate; }
    /** @param reservationDate Nueva fecha. */
    public void setReservationDate(LocalDate reservationDate) { this.reservationDate = reservationDate; }

    /** @return Hora de inicio. */
    public LocalTime getStartTime() { return startTime; }
    /** @param startTime Nueva hora. */
    public void setStartTime(LocalTime startTime) { this.startTime = startTime; }

    /** @return Hora de fin estimada. */
    public LocalTime getEndTime() { return endTime; }
    /** @param endTime Nueva hora. */
    public void setEndTime(LocalTime endTime) { this.endTime = endTime; }

    /** @return Estado actual. */
    public Status getStatus() { return status; }
    /** @param status Nuevo estado. */
    public void setStatus(Status status) { this.status = status; }

    /** @return Notas del cliente. */
    public String getNotes() { return notes; }
    /** @param notes Nuevas notas. */
    public void setNotes(String notes) { this.notes = notes; }

    /** @return Fecha de creación. */
    public LocalDateTime getCreatedAt() { return createdAt; }
    /** @param createdAt Nueva fecha. */
    public void setCreatedAt(LocalDateTime createdAt) { this.createdAt = createdAt; }
}
