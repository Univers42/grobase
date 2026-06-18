package com.hambooking.backend.model.entity;

import com.hambooking.backend.model.enums.Role;
import jakarta.persistence.*;
import jakarta.validation.constraints.*;
import lombok.*;
import org.hibernate.annotations.CreationTimestamp;
import org.hibernate.annotations.UpdateTimestamp;

import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;

/**
 * Entidad JPA que representa un usuario del sistema HamBooking.
 * Mapea a la tabla 'users' en MySQL.
 */
@Entity
@Table(name = "users")
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class User {

    /** Identificador único del usuario (Autoincremental). */
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    /** Documento Nacional de Identidad con formato válido (8 números y 1 letra). */
    @NotBlank(message = "DNI es obligatorio")
    @Pattern(regexp = "^[0-9]{8}[A-Za-z]$", message = "DNI debe tener formato: 12345678A")
    @Column(nullable = false, unique = true, length = 9)
    private String dni;

    /** Nombre del usuario. */
    @NotBlank(message = "Nombre es obligatorio")
    @Size(max = 100, message = "El nombre no puede exceder de los 100 caracteres")
    @Column(name = "first_name", nullable = false, length = 100)
    private String firstName;

    /** Apellidos del usuario. */
    @NotBlank(message = "Apellidos son obligatorios")
    @Size(max = 150, message = "Los apellidos no pueden exceder de los 150 caracteres")
    @Column(name = "last_name", nullable = false, length = 150)
    private String lastName;

    /** Correo electrónico único para inicio de sesión. */
    @NotBlank(message = "Email es obligatorio")
    @Email(message = "Email debe tener formato válido")
    @Size(max = 150, message = "El email no puede exceder de los 150 caracteres")
    @Column(nullable = false, unique = true, length = 150)
    private String email;

    /** Teléfono de contacto. */
    @NotBlank(message = "Teléfono es obligatorio")
    @Pattern(regexp = "^[+]?[0-9]{9,15}$", message = "Teléfono inválido")
    @Column(nullable = false, length = 15)
    private String phone;

    /** Hash de la contraseña almacenada mediante BCrypt. */
    @NotBlank(message = "Password es obligatorio")
    @Column(name = "password_hash", nullable = false)
    private String passwordHash;

    /** Rol asignado al usuario (ADMIN o CLIENT). */
    @NotNull(message = "Rol es obligatorio")
    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    @Builder.Default
    private Role role = Role.CLIENT;

    /** Indica si el usuario está habilitado en el sistema. */
    @Column(name = "is_active", nullable = false)
    @Builder.Default
    private Boolean isActive = true;

    /** Fecha y hora de registro del usuario. */
    @CreationTimestamp
    @Column(name = "created_at", updatable = false)
    private LocalDateTime createdAt;

    /** Fecha y hora de la última actualización del perfil. */
    @UpdateTimestamp
    @Column(name = "updated_at")
    private LocalDateTime updatedAt;

    /** Perfil profesional asociado si el usuario es un cortador. */
    @OneToOne(mappedBy = "user", cascade = CascadeType.ALL, orphanRemoval = true)
    private Carver carver;

    /** Listado de reservas realizadas por este usuario (como cliente). */
    @OneToMany(mappedBy = "client", fetch = FetchType.LAZY, cascade = CascadeType.ALL)
    @Builder.Default
    private List<Reservation> reservations = new ArrayList<>();

    /**
     * Añade una reserva a la lista del cliente y establece la relación bidireccional.
     * @param reservation La reserva a añadir.
     */
    public void addReservation(Reservation reservation) {
        reservations.add(reservation);
        reservation.setClient(this);
    }

    /**
     * Elimina una reserva de la lista y rompe la relación.
     * @param reservation La reserva a eliminar.
     */
    public void removeReservation(Reservation reservation) {
        reservations.remove(reservation);
        reservation.setClient(null);
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof User)) return false;
        User user = (User) o;
        return id != null && id.equals(user.getId());
    }

    @Override
    public int hashCode() {
        return getClass().hashCode();
    }

    @Override
    public String toString() {
        return "User{" +
                "id=" + id +
                ", dni='" + dni + '\'' +
                ", firstName='" + firstName + '\'' +
                ", lastName='" + lastName + '\'' +
                ", email='" + email + '\'' +
                ", role=" + role +
                ", isActive=" + isActive +
                '}';
    }
}
