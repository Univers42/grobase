package com.hambooking.backend.model.entity;

import com.hambooking.backend.model.enums.Status;
import jakarta.persistence.*;
import jakarta.validation.constraints.*;
import lombok.*;
import org.hibernate.annotations.CreationTimestamp;
import org.hibernate.annotations.UpdateTimestamp;

import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.LocalTime;
import java.util.ArrayList;
import java.util.List;

/**
 * Entidad JPA que representa una reserva en el sistema.
 * Mapea a la tabla 'reservations' en MySQL.
 * Actúa como tabla pivote con información extra conectando User, Carver y Service.
 */
@Entity
@Table(name = "reservations")
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class Reservation {

    /** Identificador único de la reserva. */
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    /** Cliente (Usuario) que realiza la reserva. */
    @NotNull(message = "El cliente es obligatorio")
    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "client_id", nullable = false)
    private User client;

    /** Cortador profesional asignado a la reserva. */
    @NotNull(message = "El cortador es obligatorio")
    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "carver_id", nullable = false)
    private Carver carver;

    /** Tipo de servicio contratado en la reserva. */
    @NotNull(message = "El servicio es obligatorio")
    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "service_id", nullable = false)
    private Service service;

    /** Fecha programada para la prestación del servicio. */
    @NotNull(message = "La fecha de reserva es obligatoria")
    @Future(message = "La fecha de reserva debe ser en el futuro")
    @Column(name = "reservation_date", nullable = false)
    private LocalDate reservationDate;

    /** Hora exacta de inicio del servicio. */
    @NotNull(message = "La hora de inicio es obligatoria")
    @Column(name = "start_time", nullable = false)
    private LocalTime startTime;

    /** Hora estimada de finalización del servicio. */
    @NotNull(message = "La hora de fin es obligatoria")
    @Column(name = "end_time", nullable = false)
    private LocalTime endTime;

    /** Estado actual de la reserva (PENDING, CONFIRMED, etc.). */
    @NotNull(message = "El estado es obligatorio")
    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    @Builder.Default
    private Status status = Status.PENDING;

    /** Observaciones o notas adicionales proporcionadas por el cliente. */
    @Column(columnDefinition = "TEXT")
    private String notes;

    /** Fecha y hora en la que se creó la reserva. */
    @CreationTimestamp
    @Column(name = "created_at", updatable = false)
    private LocalDateTime createdAt;

    /** Fecha y hora de la última modificación de la reserva. */
    @UpdateTimestamp
    @Column(name = "updated_at")
    private LocalDateTime updatedAt;

    /** Historial de notificaciones enviadas con relación a esta reserva. */
    @OneToMany(mappedBy = "reservation", cascade = CascadeType.ALL, orphanRemoval = true)
    @Builder.Default
    private List<Notification> notifications = new ArrayList<>();

    /**
     * Calcula automáticamente la hora de fin de la reserva sumando
     * la duración del servicio a la hora de inicio.
     */
    public void calculateEndTime() {
        if (this.startTime != null && this.service != null && this.service.getDurationMinutes() != null) {
            this.endTime = this.startTime.plusMinutes(this.service.getDurationMinutes());
        }
    }

    /**
     * Registra una nueva notificación asociada a esta reserva.
     * @param notification La notificación a registrar.
     */
    public void addNotification(Notification notification) {
        notifications.add(notification);
        notification.setReservation(this);
    }

    /**
     * Elimina una notificación del historial de la reserva.
     * @param notification La notificación a eliminar.
     */
    public void removeNotification(Notification notification) {
        notifications.remove(notification);
        notification.setReservation(null);
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof Reservation)) return false;
        Reservation that = (Reservation) o;
        return id != null && id.equals(that.getId());
    }

    @Override
    public int hashCode() {
        return getClass().hashCode();
    }

    @Override
    public String toString() {
        Long clientId = (client != null) ? client.getId() : null;
        Long carverId = (carver != null) ? carver.getId() : null;
        Long serviceId = (service != null) ? service.getId() : null;

        return "Reservation{" +
                "id=" + id +
                ", clientId=" + clientId +
                ", carverId=" + carverId +
                ", serviceId=" + serviceId +
                ", reservationDate=" + reservationDate +
                ", startTime=" + startTime +
                ", endTime=" + endTime +
                ", status=" + status +
                '}';
    }
}
