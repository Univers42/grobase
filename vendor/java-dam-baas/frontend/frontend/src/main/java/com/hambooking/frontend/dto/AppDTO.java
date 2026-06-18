package com.hambooking.frontend.dto;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.LocalTime;

/**
 * Contenedor de los Objetos de Transferencia de Datos (DTO) del dominio de la aplicación.
 * Actúan como contratos de sincronización estricta con el backend mediante Jackson.
 * 
 * Todas las clases de respuesta ignoran propiedades desconocidas para hacer que el cliente
 * sea tolerante a cambios (resiliente) si el backend evoluciona y añade nuevos campos.
 */
public final class AppDTO {

    /**
     * Constructor privado para evitar instanciación de la clase contenedora.
     */
    private AppDTO() {}

    // ── Carver ───────────────────────────────────────────────────────────

    /**
     * DTO que representa el perfil público y la configuración de un cortador.
     */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class CarverResponse {
        @JsonProperty("id")
        public Long id;
        
        @JsonProperty("userId")
        public Long userId;
        
        @JsonProperty("firstName")
        public String firstName;
        
        @JsonProperty("lastName")
        public String lastName;
        
        @JsonProperty("dni")
        public String dni;
        
        @JsonProperty("email")
        public String email;
        
        @JsonProperty("phone")
        public String phone;
        
        @JsonProperty("specialty")
        public String specialty;
        
        @JsonProperty("experienceYears")
        public Integer experienceYears;
        
        @JsonProperty("maxHamsPerDay")
        public Integer maxHamsPerDay;
        
        @JsonProperty("isActive")
        public Boolean isActive;

        public CarverResponse() {}

        /**
         * Devuelve el nombre completo o la especialidad si el nombre no está disponible.
         */
        public String getDisplayName() {
            if (firstName != null && lastName != null) {
                return firstName + " " + lastName;
            }
            return specialty != null ? specialty : "Cortador #" + id;
        }
    }

    // ── User ─────────────────────────────────────────────────────────────

    /**
     * DTO que representa un usuario registrado en el sistema.
     */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class UserResponse {
        @JsonProperty("id")
        public Long id;
        
        @JsonProperty("dni")
        public String dni;
        
        @JsonProperty("firstName")
        public String firstName;
        
        @JsonProperty("lastName")
        public String lastName;
        
        @JsonProperty("email")
        public String email;
        
        @JsonProperty("phone")
        public String phone;
        
        @JsonProperty("role")
        public String role;
        
        @JsonProperty("isActive")
        public Boolean isActive;

        public UserResponse() {}

        /**
         * Devuelve el nombre completo del usuario.
         */
        public String getFullName() {
            return firstName + " " + lastName;
        }
    }

    // ── Service ──────────────────────────────────────────────────────────

    /**
     * DTO que representa un servicio ofrecido por los cortadores.
     */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class ServiceResponse {
        @JsonProperty("id")
        public Long id;
        
        @JsonProperty("name")
        public String name;
        
        @JsonProperty("description")
        public String description;
        
        @JsonProperty("durationMinutes")
        public Integer durationMinutes;
        
        @JsonProperty("basePrice")
        public BigDecimal basePrice;
        
        @JsonProperty("isActive")
        public Boolean isActive;

        public ServiceResponse() {}

        /**
         * Devuelve el nombre del servicio formateado con su duración y precio.
         * Útil para mostrar en desplegables (ComboBox).
         */
        public String getDisplayName() {
            final int h = durationMinutes / 60;
            final int min = durationMinutes % 60;
            final String durStr = h > 0
                    ? (h + "h" + (min > 0 ? min + "min" : ""))
                    : (min + "min");
            return name + " (" + durStr + ") - " + basePrice + " EUR";
        }

        /**
         * Obtiene el precio base como cadena formateada.
         */
        public String getPrecioStr() {
            return basePrice != null ? basePrice.toPlainString() + " EUR" : "";
        }
    }

    // ── Reservation: crear ───────────────────────────────────────────────

    /**
     * DTO para solicitar la creación de una nueva reserva.
     */
    public static class CreateReservationRequest {
        @JsonProperty("clientId")
        public Long clientId;
        
        @JsonProperty("carverId")
        public Long carverId;
        
        @JsonProperty("serviceId")
        public Long serviceId;
        
        @JsonProperty("reservationDate")
        public LocalDate reservationDate;
        
        @JsonProperty("startTime")
        public LocalTime startTime;
        
        @JsonProperty("notes")
        public String notes;

        public CreateReservationRequest() {}

        public CreateReservationRequest(final Long clientId, final Long carverId, final Long serviceId,
                                        final LocalDate reservationDate, final LocalTime startTime,
                                        final String notes) {
            this.clientId = clientId;
            this.carverId = carverId;
            this.serviceId = serviceId;
            this.reservationDate = reservationDate;
            this.startTime = startTime;
            this.notes = notes;
        }
    }

    // ── Reservation: respuesta ───────────────────────────────────────────

    /**
     * DTO que representa una reserva programada o histórica.
     */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class ReservationResponse {
        @JsonProperty("id")
        public Long id;
        
        @JsonProperty("clientId")
        public Long clientId;
        
        @JsonProperty("clientFirstName")
        public String clientFirstName;
        
        @JsonProperty("clientLastName")
        public String clientLastName;
        
        @JsonProperty("carverId")
        public Long carverId;
        
        @JsonProperty("carverFirstName")
        public String carverFirstName;
        
        @JsonProperty("carverLastName")
        public String carverLastName;
        
        @JsonProperty("serviceId")
        public Long serviceId;
        
        @JsonProperty("serviceName")
        public String serviceName;
        
        @JsonProperty("serviceDurationMinutes")
        public Integer serviceDurationMinutes;
        
        @JsonProperty("reservationDate")
        public LocalDate reservationDate;
        
        @JsonProperty("startTime")
        public LocalTime startTime;
        
        @JsonProperty("endTime")
        public LocalTime endTime;
        
        @JsonProperty("status")
        public String status;
        
        @JsonProperty("notes")
        public String notes;
        
        @JsonProperty("createdAt")
        public LocalDateTime createdAt;

        public ReservationResponse() {}

        /**
         * Devuelve el nombre completo del cortador asignado a la reserva.
         */
        public String getCarverFullName() {
            return carverFirstName + " " + carverLastName;
        }

        /**
         * Devuelve el nombre completo del cliente que realizó la reserva.
         */
        public String getClientFullName() {
            return clientFirstName + " " + clientLastName;
        }

        /**
         * Obtiene la franja horaria de la reserva como cadena.
         */
        public String getHoraStr() {
            return startTime + " - " + endTime;
        }

        /**
         * Obtiene la fecha de la reserva como cadena.
         */
        public String getFechaStr() {
            return reservationDate != null ? reservationDate.toString() : "";
        }
    }

    // ── Reservation: actualizar ──────────────────────────────────────────

    /**
     * DTO para enviar actualizaciones sobre una reserva existente.
     */
    public static class UpdateReservationRequest {
        @JsonProperty("reservationDate")
        public LocalDate reservationDate;
        
        @JsonProperty("startTime")
        public LocalTime startTime;
        
        @JsonProperty("notes")
        public String notes;

        public UpdateReservationRequest() {}

        public UpdateReservationRequest(final LocalDate reservationDate,
                                        final LocalTime startTime, final String notes) {
            this.reservationDate = reservationDate;
            this.startTime = startTime;
            this.notes = notes;
        }
    }

    // ── Notification ─────────────────────────────────────────────────────

    /**
     * DTO que representa una notificación o mensaje enviado por el sistema.
     */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class NotificationResponse {
        @JsonProperty("id")
        public Long id;
        
        @JsonProperty("reservationId")
        public Long reservationId;
        
        @JsonProperty("recipientType")
        public String recipientType;
        
        @JsonProperty("recipientEmail")
        public String recipientEmail;
        
        @JsonProperty("notificationType")
        public String notificationType;
        
        @JsonProperty("subject")
        public String subject;
        
        @JsonProperty("message")
        public String message;
        
        @JsonProperty("isSent")
        public Boolean isSent;
        
        @JsonProperty("sentAt")
        public LocalDateTime sentAt;

        public NotificationResponse() {}
    }
}
