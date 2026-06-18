package com.hambooking.backend.model.entity;

import jakarta.persistence.*;
import jakarta.validation.constraints.*;
import lombok.*;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;

/**
 * Entidad JPA que representa el catálogo de servicios de corte disponibles.
 * Mapea a la tabla 'services' en MySQL.
 */
@Entity
@Table(name = "services")
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class Service {

    /** Identificador único del servicio. */
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    /** Nombre descriptivo del servicio (ej. Corte de Jamón). */
    @NotBlank(message = "El nombre del servicio es obligatorio")
    @Size(max = 100, message = "El nombre no puede exceder los 100 caracteres")
    @Column(nullable = false, unique = true, length = 100)
    private String name;

    /** Detalles extensos sobre lo que incluye el servicio. */
    @Size(max = 1000, message = "La descripción es demasiado larga")
    @Column(columnDefinition = "TEXT")
    private String description;

    /** Tiempo estimado en minutos para la realización del servicio. */
    @NotNull(message = "La duración es obligatoria")
    @Positive(message = "La duración en minutos debe ser mayor a 0")
    @Column(name = "duration_minutes", nullable = false)
    private Integer durationMinutes;

    /** Coste base del servicio (Manejado con precisión decimal). */
    @NotNull(message = "El precio base es obligatorio")
    @DecimalMin(value = "0.0", inclusive = true, message = "El precio base no puede ser negativo")
    @Column(name = "base_price", nullable = false, precision = 10, scale = 2)
    private BigDecimal basePrice;

    /** Indica si el servicio está actualmente ofertado en el catálogo. */
    @Column(name = "is_active", nullable = false)
    @Builder.Default
    private Boolean isActive = true;

    /** Listado de reservas que han contratado este servicio específico. */
    @OneToMany(mappedBy = "service", fetch = FetchType.LAZY, cascade = CascadeType.ALL)
    @Builder.Default
    private List<Reservation> reservations = new ArrayList<>();

    /**
     * Vincula una nueva reserva a este servicio.
     * @param reservation La reserva a vincular.
     */
    public void addReservation(Reservation reservation) {
        reservations.add(reservation);
        reservation.setService(this);
    }

    /**
     * Desvincula una reserva del catálogo.
     * @param reservation La reserva a desvincular.
     */
    public void removeReservation(Reservation reservation) {
        reservations.remove(reservation);
        reservation.setService(null);
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof Service)) return false;
        Service service = (Service) o;
        return id != null && id.equals(service.getId());
    }

    @Override
    public int hashCode() {
        return getClass().hashCode();
    }

    @Override
    public String toString() {
        return "Service{" +
                "id=" + id +
                ", name='" + name + '\'' +
                ", durationMinutes=" + durationMinutes +
                ", basePrice=" + basePrice +
                ", isActive=" + isActive +
                '}';
    }
}
