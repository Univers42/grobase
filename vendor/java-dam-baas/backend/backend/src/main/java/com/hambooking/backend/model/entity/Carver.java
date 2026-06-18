package com.hambooking.backend.model.entity;

import jakarta.persistence.*;
import jakarta.validation.constraints.*;
import lombok.*;
import org.hibernate.annotations.CreationTimestamp;

import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;

/**
 * Entidad JPA que representa el perfil profesional de un cortador.
 * Mapea a la tabla 'carvers' en MySQL.
 * Es dueña de la relación OneToOne con User.
 */
@Entity
@Table(name = "carvers")
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class Carver {

    /** Identificador único del perfil de cortador. */
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    /** Referencia al usuario base (Relación 1:1, dueña de la FK). */
    @OneToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "user_id", nullable = false, unique = true)
    private User user;

    /** Especialidad técnica del cortador (ej. Jamón de Bellota). */
    @Size(max = 100, message = "La especialidad no puede exceder de los 100 caracteres")
    @Column(length = 100)
    private String specialty;

    /** Cantidad de años de experiencia profesional demostrada. */
    @Min(value = 0, message = "Los años de experiencia no pueden ser negativos")
    @Column(name = "experience_years")
    @Builder.Default
    private Integer experienceYears = 0;

    /** Límite diario de piezas de jamón/paleta que el cortador puede atender. */
    @Min(value = 1, message = "Debe permitir al menos 1 servicio por día")
    @Max(value = 10, message = "El límite máximo de servicios por día es 10")
    @Column(name = "max_hams_per_day")
    @Builder.Default
    private Integer maxHamsPerDay = 3;

    /** Indica si el cortador está disponible para recibir nuevas reservas. */
    @Column(name = "is_active", nullable = false)
    @Builder.Default
    private Boolean isActive = true;

    /** Fecha y hora en la que se habilitó el perfil profesional. */
    @CreationTimestamp
    @Column(name = "created_at", updatable = false)
    private LocalDateTime createdAt;

    /** Listado de reservas asignadas a este cortador. */
    @OneToMany(mappedBy = "carver", fetch = FetchType.LAZY, cascade = CascadeType.ALL)
    @Builder.Default
    private List<Reservation> reservations = new ArrayList<>();

    /**
     * Añade una reserva a la planificación del cortador.
     * @param reservation La reserva a añadir.
     */
    public void addReservation(Reservation reservation) {
        reservations.add(reservation);
        reservation.setCarver(this);
    }

    /**
     * Elimina una reserva de la planificación.
     * @param reservation La reserva a eliminar.
     */
    public void removeReservation(Reservation reservation) {
        reservations.remove(reservation);
        reservation.setCarver(null);
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof Carver)) return false;
        Carver carver = (Carver) o;
        return id != null && id.equals(carver.getId());
    }

    @Override
    public int hashCode() {
        return getClass().hashCode();
    }

    @Override
    public String toString() {
        Long userId = (user != null) ? user.getId() : null;

        return "Carver{" +
                "id=" + id +
                ", userId=" + userId +
                ", specialty='" + specialty + '\'' +
                ", experienceYears=" + experienceYears +
                ", maxHamsPerDay=" + maxHamsPerDay +
                ", isActive=" + isActive +
                '}';
    }
}
