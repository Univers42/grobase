package com.hambooking.backend.dto.auth;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;

/**
 * Objeto de transferencia de datos para las solicitudes de inicio de sesión.
 * Captura las credenciales proporcionadas por el usuario desde el frontend.
 */
public class LoginRequestDTO {

    /** Dirección de correo electrónico del usuario. */
    @NotBlank(message = "El email no puede estar vacío")
    @Email(message = "El formato del email no es válido")
    private String email;

    /** Contraseña del usuario en texto plano (para ser verificada en el servidor). */
    @NotBlank(message = "La contraseña no puede estar vacía")
    private String password;

    /**
     * Constructor por defecto requerido para la deserialización JSON (Jackson).
     */
    public LoginRequestDTO() {}

    /**
     * Constructor completo para facilitar la instanciación en pruebas y servicios.
     * @param email Email del usuario.
     * @param password Contraseña proporcionada.
     */
    public LoginRequestDTO(String email, String password) {
        this.email = email;
        this.password = password;
    }

    /** @return Email del usuario. */
    public String getEmail() { return email; }
    /** @param email Nuevo email a establecer. */
    public void setEmail(String email) { this.email = email; }

    /** @return Contraseña proporcionada. */
    public String getPassword() { return password; }
    /** @param password Nueva contraseña a establecer. */
    public void setPassword(String password) { this.password = password; }
}
