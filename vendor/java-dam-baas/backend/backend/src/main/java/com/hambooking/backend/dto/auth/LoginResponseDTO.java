package com.hambooking.backend.dto.auth;

import com.hambooking.backend.model.enums.Role;

/**
 * Objeto de transferencia de datos para la respuesta tras un inicio de sesión exitoso.
 * Contiene la información básica de perfil y sesión necesaria para el frontend.
 */
public class LoginResponseDTO {

    /** Identificador único del usuario. */
    private Long id;

    /** Nombre del usuario. */
    private String firstName;

    /** Apellidos del usuario. */
    private String lastName;

    /** Email del usuario (utilizado como identificador de sesión). */
    private String email;

    /** Rol asignado que determina los permisos en la aplicación. */
    private Role role;

    /**
     * Constructor por defecto requerido para la deserialización JSON.
     */
    public LoginResponseDTO() {}

    /**
     * Constructor completo para la creación de la respuesta desde el servicio.
     * @param id Identificador.
     * @param firstName Nombre.
     * @param lastName Apellidos.
     * @param email Email.
     * @param role Rol.
     */
    public LoginResponseDTO(Long id, String firstName, String lastName, String email, Role role) {
        this.id = id;
        this.firstName = firstName;
        this.lastName = lastName;
        this.email = email;
        this.role = role;
    }

    /** @return ID del usuario. */
    public Long getId() { return id; }
    /** @param id Nuevo ID. */
    public void setId(Long id) { this.id = id; }

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

    /** @return Rol. */
    public Role getRole() { return role; }
    /** @param role Nuevo rol. */
    public void setRole(Role role) { this.role = role; }
}
