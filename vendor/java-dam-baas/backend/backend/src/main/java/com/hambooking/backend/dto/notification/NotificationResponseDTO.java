package com.hambooking.backend.dto.notification;

import com.hambooking.backend.model.enums.NotificationType;
import com.hambooking.backend.model.enums.RecipientType;

import java.time.LocalDateTime;

/**
 * Objeto de transferencia de datos para la visualización de notificaciones.
 * Representa un registro histórico de una comunicación enviada por el sistema.
 */
public class NotificationResponseDTO {

    /** Identificador único de la notificación. */
    private Long id;

    /** Identificador de la reserva vinculada (si existe). */
    private Long reservationId;

    /** Tipo de perfil del destinatario (CLIENT, CARVER, ADMIN). */
    private RecipientType recipientType;

    /** Dirección de correo electrónico de destino. */
    private String recipientEmail;

    /** Motivo de la notificación (ej. CREATED, CANCELLED). */
    private NotificationType notificationType;

    /** Título o encabezado del mensaje. */
    private String subject;

    /** Contenido detallado del mensaje. */
    private String message;

    /** Indica si el envío se realizó con éxito. */
    private Boolean isSent;

    /** Fecha y hora exacta del registro del envío. */
    private LocalDateTime sentAt;

    /**
     * Constructor por defecto para la deserialización JSON.
     */
    public NotificationResponseDTO() {}

    /**
     * Constructor completo para la creación del DTO desde el servicio.
     * @param id ID.
     * @param reservationId ID Reserva.
     * @param recipientType Tipo Destinatario.
     * @param recipientEmail Email Destinatario.
     * @param notificationType Tipo Notificación.
     * @param subject Asunto.
     * @param message Mensaje.
     * @param isSent Estado envío.
     * @param sentAt Fecha envío.
     */
    public NotificationResponseDTO(Long id, Long reservationId,
                                   RecipientType recipientType, String recipientEmail,
                                   NotificationType notificationType, String subject,
                                   String message, Boolean isSent, LocalDateTime sentAt) {
        this.id = id;
        this.reservationId = reservationId;
        this.recipientType = recipientType;
        this.recipientEmail = recipientEmail;
        this.notificationType = notificationType;
        this.subject = subject;
        this.message = message;
        this.isSent = isSent;
        this.sentAt = sentAt;
    }

    /** @return ID Notificación. */
    public Long getId() { return id; }
    /** @param id Nuevo ID. */
    public void setId(Long id) { this.id = id; }

    /** @return ID Reserva vinculada. */
    public Long getReservationId() { return reservationId; }
    /** @param reservationId Nuevo ID Reserva. */
    public void setReservationId(Long reservationId) { this.reservationId = reservationId; }

    /** @return Tipo de destinatario. */
    public RecipientType getRecipientType() { return recipientType; }
    /** @param recipientType Nuevo tipo. */
    public void setRecipientType(RecipientType recipientType) { this.recipientType = recipientType; }

    /** @return Email de destino. */
    public String getRecipientEmail() { return recipientEmail; }
    /** @param recipientEmail Nuevo email. */
    public void setRecipientEmail(String recipientEmail) { this.recipientEmail = recipientEmail; }

    /** @return Tipo de notificación. */
    public NotificationType getNotificationType() { return notificationType; }
    /** @param notificationType Nuevo tipo. */
    public void setNotificationType(NotificationType notificationType) { this.notificationType = notificationType; }

    /** @return Asunto. */
    public String getSubject() { return subject; }
    /** @param subject Nuevo asunto. */
    public void setSubject(String subject) { this.subject = subject; }

    /** @return Mensaje completo. */
    public String getMessage() { return message; }
    /** @param message Nuevo mensaje. */
    public void setMessage(String message) { this.message = message; }

    /** @return true si fue enviado. */
    public Boolean getIsSent() { return isSent; }
    /** @param isSent Nuevo estado. */
    public void setIsSent(Boolean isSent) { this.isSent = isSent; }

    /** @return Fecha de envío. */
    public LocalDateTime getSentAt() { return sentAt; }
    /** @param sentAt Nueva fecha. */
    public void setSentAt(LocalDateTime sentAt) { this.sentAt = sentAt; }
}
