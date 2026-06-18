package com.hambooking.backend.repository;

import com.hambooking.backend.model.entity.Notification;
import com.hambooking.backend.model.entity.Reservation;
import com.hambooking.backend.model.enums.NotificationType;
import com.hambooking.backend.model.enums.RecipientType;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

import java.util.List;

/**
 * Repositorio para la gestión de persistencia de la entidad {@link Notification}.
 * Actúa como el registro de auditoría de todas las comunicaciones enviadas por el sistema.
 */
@Repository
public interface NotificationRepository extends JpaRepository<Notification, Long> {

    /**
     * Recupera todas las notificaciones vinculadas a una reserva específica.
     * @param reservation La reserva cuyo historial se consulta.
     * @return Lista de notificaciones asociadas.
     */
    List<Notification> findByReservation(Reservation reservation);

    /**
     * Obtiene notificaciones de una reserva filtradas por el motivo del envío.
     * @param reservation La reserva asociada.
     * @param notificationType Tipo de evento que disparó la notificación.
     * @return Lista de notificaciones que cumplen ambos criterios.
     */
    List<Notification> findByReservationAndNotificationType(
            Reservation reservation,
            NotificationType notificationType
    );

    /**
     * Recupera el historial de notificaciones enviadas a una dirección de email.
     * @param recipientEmail Correo electrónico del destinatario.
     * @return Lista de mensajes enviados a esa dirección.
     */
    List<Notification> findByRecipientEmail(String recipientEmail);

    /**
     * Obtiene todas las notificaciones dirigidas a un tipo de perfil específico.
     * @param recipientType Categoría del destinatario (CLIENT, CARVER, ADMIN).
     * @return Lista de notificaciones para ese perfil.
     */
    List<Notification> findByRecipientType(RecipientType recipientType);

    /**
     * Recupera todas las notificaciones del sistema según su categoría.
     * @param notificationType Tipo de notificación a filtrar.
     * @return Lista de notificaciones de ese tipo.
     */
    List<Notification> findByNotificationType(NotificationType notificationType);

    /**
     * Cuenta el número total de comunicaciones generadas para una reserva.
     * @param reservation La reserva objeto de la consulta.
     * @return Número de notificaciones registradas.
     */
    @Query("SELECT COUNT(n) FROM Notification n WHERE n.reservation = :reservation")
    long countByReservation(@Param("reservation") Reservation reservation);
}
