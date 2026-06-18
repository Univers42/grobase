package com.hambooking.backend.service;

import com.hambooking.backend.dto.notification.NotificationResponseDTO;
import com.hambooking.backend.exception.ResourceNotFoundException;
import com.hambooking.backend.model.entity.Notification;
import com.hambooking.backend.model.entity.Reservation;
import com.hambooking.backend.model.entity.User;
import com.hambooking.backend.model.enums.NotificationType;
import com.hambooking.backend.model.enums.RecipientType;
import com.hambooking.backend.model.enums.Role;
import com.hambooking.backend.repository.NotificationRepository;
import com.hambooking.backend.repository.UserRepository;
import lombok.RequiredArgsConstructor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.stream.Collectors;

/**
 * Servicio encargado de gestionar el envío y consulta de notificaciones del sistema.
 */
@Service
@RequiredArgsConstructor
public class NotificationService {

    /** Logger de la clase para registro de eventos de notificación. */
    private static final Logger logger = LoggerFactory.getLogger(NotificationService.class);

    /** Repositorio de notificaciones para persistencia y consulta. */
    private final NotificationRepository notificationRepository;
    
    /** Repositorio de usuarios para buscar administradores y validar correos. */
    private final UserRepository userRepository;

    /**
     * Genera y envía tres notificaciones por cada evento de reserva:
     * una al cliente, una al cortador y otra al administrador.
     *
     * @param reservation La reserva asociada al evento.
     * @param type El tipo de notificación (CREADA, MODIFICADA, CANCELADA, RECORDATORIO).
     */
    @Transactional
    public void sendReservationNotification(Reservation reservation, NotificationType type) {
        String subject = buildSubject(type, reservation);

        sendSingle(reservation, type, RecipientType.CLIENT,
                reservation.getClient().getEmail(), subject,
                buildClientMessage(type, reservation));

        sendSingle(reservation, type, RecipientType.CARVER,
                reservation.getCarver().getUser().getEmail(), subject,
                buildCarverMessage(type, reservation));

        String adminEmail = userRepository.findByRole(Role.ADMIN).stream()
                .findFirst().map(User::getEmail).orElse("admin@hambooking.com");

        sendSingle(reservation, type, RecipientType.ADMIN,
                adminEmail, subject, buildAdminMessage(type, reservation));
    }

    /**
     * Lista todas las notificaciones registradas en el sistema (ideal para administradores).
     *
     * @return Lista de DTOs con la información de todas las notificaciones.
     */
    @Transactional(readOnly = true)
    public List<NotificationResponseDTO> listAllNotifications() {
        return notificationRepository.findAll().stream()
                .map(this::toDTO).collect(Collectors.toList());
    }

    /**
     * Lista todas las notificaciones dirigidas a un usuario específico.
     *
     * @param userId Identificador del usuario.
     * @return Lista de DTOs con las notificaciones del usuario.
     * @throws ResourceNotFoundException Si el usuario no existe.
     */
    @Transactional(readOnly = true)
    public List<NotificationResponseDTO> listByUser(Long userId) {
        User user = userRepository.findById(userId)
                .orElseThrow(() -> new ResourceNotFoundException("Usuario no encontrado"));
        return notificationRepository.findByRecipientEmail(user.getEmail())
                .stream().map(this::toDTO).collect(Collectors.toList());
    }

    /**
     * Obtiene el historial de notificaciones asociadas a una reserva específica.
     *
     * @param reservation Entidad de la reserva.
     * @return Lista de DTOs de notificaciones vinculadas a la reserva.
     */
    @Transactional(readOnly = true)
    public List<NotificationResponseDTO> getNotificationsByReservation(Reservation reservation) {
        return notificationRepository.findByReservation(reservation)
                .stream().map(this::toDTO).collect(Collectors.toList());
    }

    /**
     * Método auxiliar para registrar y enviar una notificación individual.
     *
     * @param reservation Entidad de la reserva.
     * @param type Tipo de notificación.
     * @param recipientType Tipo de destinatario.
     * @param email Correo electrónico del destinatario.
     * @param subject Asunto del correo.
     * @param message Cuerpo del mensaje.
     */
    private void sendSingle(Reservation reservation, NotificationType type,
                            RecipientType recipientType, String email,
                            String subject, String message) {
        Notification n = Notification.builder()
                .reservation(reservation)
                .notificationType(type)
                .recipientType(recipientType)
                .recipientEmail(email)
                .subject(subject)
                .message(message)
                .isSent(true)
                .build();
        notificationRepository.save(n);
        logger.info("[NOTIFICATION] {} → {} | {} | {}", type, recipientType, email, subject);
    }

    /**
     * Construye el asunto del correo electrónico según el tipo de notificación.
     *
     * @param type Tipo de notificación.
     * @param r Reserva asociada.
     * @return Cadena con el asunto.
     */
    private String buildSubject(NotificationType type, Reservation r) {
        return switch (type) {
            case CREATED   -> "Nueva reserva confirmada - " + r.getService().getName();
            case MODIFIED  -> "Reserva modificada - " + r.getService().getName();
            case CANCELLED -> "Reserva cancelada - " + r.getService().getName();
            case REMINDER  -> "Recordatorio de reserva - " + r.getService().getName();
        };
    }

    /**
     * Construye el mensaje personalizado para el cliente.
     *
     * @param type Tipo de notificación.
     * @param r Reserva asociada.
     * @return Cadena con el mensaje para el cliente.
     */
    private String buildClientMessage(NotificationType type, Reservation r) {
        String base = "Hola " + r.getClient().getFirstName() + ",\n\n";
        return base + switch (type) {
            case CREATED   -> "Tu reserva de " + r.getService().getName()
                    + " ha sido creada para el " + r.getReservationDate()
                    + " a las " + r.getStartTime() + ".";
            case MODIFIED  -> "Tu reserva de " + r.getService().getName()
                    + " ha sido modificada. Nueva fecha: " + r.getReservationDate()
                    + " a las " + r.getStartTime() + ".";
            case CANCELLED -> "Tu reserva de " + r.getService().getName()
                    + " del " + r.getReservationDate() + " ha sido cancelada.";
            case REMINDER  -> "Recuerda tu reserva de " + r.getService().getName()
                    + " mañana " + r.getReservationDate() + " a las " + r.getStartTime() + ".";
        };
    }

    /**
     * Construye el mensaje personalizado para el cortador.
     *
     * @param type Tipo de notificación.
     * @param r Reserva asociada.
     * @return Cadena con el mensaje para el cortador.
     */
    private String buildCarverMessage(NotificationType type, Reservation r) {
        String base = "Hola " + r.getCarver().getUser().getFirstName() + ",\n\n";
        return base + switch (type) {
            case CREATED   -> "Nueva reserva de " + r.getService().getName()
                    + " el " + r.getReservationDate() + " a las " + r.getStartTime() + ".";
            case MODIFIED  -> "Reserva modificada. Nueva fecha: " + r.getReservationDate()
                    + " a las " + r.getStartTime() + ".";
            case CANCELLED -> "Reserva de " + r.getService().getName()
                    + " del " + r.getReservationDate() + " cancelada.";
            case REMINDER  -> "Recuerda tu reserva de " + r.getService().getName()
                    + " mañana " + r.getReservationDate() + " a las " + r.getStartTime() + ".";
        };
    }

    /**
     * Construye el resumen del evento para el administrador.
     *
     * @param type Tipo de notificación.
     * @param r Reserva asociada.
     * @return Cadena con el resumen para el administrador.
     */
    private String buildAdminMessage(NotificationType type, Reservation r) {
        String client = r.getClient().getFirstName() + " " + r.getClient().getLastName();
        String carver = r.getCarver().getUser().getFirstName() + " " + r.getCarver().getUser().getLastName();
        return switch (type) {
            case CREATED   -> "Nueva reserva. Cliente: " + client + " | Cortador: " + carver
                    + " | " + r.getService().getName() + " | " + r.getReservationDate() + " " + r.getStartTime();
            case MODIFIED  -> "Reserva modificada. Cliente: " + client
                    + " | Nueva fecha: " + r.getReservationDate() + " " + r.getStartTime();
            case CANCELLED -> "Reserva cancelada. Cliente: " + client + " | Cortador: " + carver
                    + " | " + r.getService().getName() + " | " + r.getReservationDate();
            case REMINDER  -> "Recordatorio. Cliente: " + client
                    + " | " + r.getService().getName() + " | " + r.getReservationDate();
        };
    }

    /**
     * Convierte una entidad Notification a su correspondiente DTO.
     *
     * @param n Entidad a convertir.
     * @return Objeto NotificationResponseDTO con los datos mapeados.
     */
    private NotificationResponseDTO toDTO(Notification n) {
        return new NotificationResponseDTO(
                n.getId(),
                n.getReservation() != null ? n.getReservation().getId() : null,
                n.getRecipientType(),
                n.getRecipientEmail(),
                n.getNotificationType(),
                n.getSubject(),
                n.getMessage(),
                n.getIsSent(),
                n.getSentAt()
        );
    }
}
