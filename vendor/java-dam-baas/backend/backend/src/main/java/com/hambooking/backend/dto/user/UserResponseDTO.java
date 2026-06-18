package com.hambooking.backend.dto.user;

import com.hambooking.backend.model.enums.Role;

/**
 * Objeto de transferencia de datos para la representación segura de perfiles de usuario.
 * Excluye deliberadamente el hash de la contraseña para evitar su exposición en la red.
 */
public class UserResponseDTO {

    /** Identificador único del usuario. */
    private Long id;

    /** Documento Nacional de Identidad. */
    private String dni;

    /** Nombre de pila. */
    private String firstName;

    /** Apellidos. */
    private String lastName;

    /** Correo electrónico de contacto. */
    private String email;

    /** Número de teléfono. */
    private String phone;

    /** Rol asignado (ADMIN o CLIENT). */
    private Role role;

    /** Indica si el usuario puede acceder al sistema. */
    private Boolean isActive;

    /**
     * Constructor por defecto para la deserialización JSON.
     */
    public UserResponseDTO() {}

    /**
     * Constructor completo para el mapeo desde el servicio.
     * @param id ID.
     * @param dni DNI.
     * @param firstName Nombre.
     * @param lastName Apellidos.
     * @param email Email.
     * @param phone Teléfono.
     * @param role Rol.
     * @param isActive Estado.
     */
    public UserResponseDTO(Long id, String dni, String firstName, String lastName,
                           String email, String phone, Role role, Boolean isActive) {
        this.id = id;
        this.dni = dni;
        this.firstName = firstName;
        this.lastName = lastName;
        this.email = email;
        this.phone = phone;
        this.role = role;
        this.isActive = isActive;
    }

    /** @return ID Usuario. */
    public Long getId() { return id; }
    /** @param id Nuevo ID. */
    public void setId(Long id) { this.id = id; }

    /** @return DNI. */
    public String getDni() { return dni; }
    /** @param dni Nuevo DNI. */
    public void setDni(String dni) { this.dni = dni; }

    /** @return Nombre. */
    public String getFirstName() { return firstName; }
    /** @param firstName Nuevo nombre. */
    public void setFirstName(String firstName) { this.firstName = firstName; }

    /** @return Apellidos. */
    public String getLastName() { return lastName; }
    /** @param lastName Nuevos apellidos. */
    public void setLastName(String lastName) { this.lastName = lastName; }

    /** @return Email. */
    public String getEmail() { return email; }
    /** @param email Nuevo email. */
    public void setEmail(String email) { this.email = email; }

    /** @return Teléfono. */
    public String getPhone() { return phone; }
    /** @param phone Nuevo teléfono. */
    public void setPhone(String phone) { this.phone = phone; }

    /** @return Rol. */
    public Role getRole() { return role; }
    /** @param role Nuevo rol. */
    public void setRole(Role role) { this.role = role; }

    /** @return true si está activo. */
    public Boolean getIsActive() { return isActive; }
    /** @param isActive Nuevo estado. */
    public void setIsActive(Boolean isActive) { this.isActive = isActive; }
}
