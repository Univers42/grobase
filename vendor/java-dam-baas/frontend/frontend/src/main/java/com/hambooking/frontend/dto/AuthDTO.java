package com.hambooking.frontend.dto;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

/**
 * Contenedor de los Objetos de Transferencia de Datos (DTO) para autenticación.
 * Actúan como espejo estricto de los contratos JSON del backend.
 * 
 * Se ha aplicado {@code @JsonIgnoreProperties(ignoreUnknown = true)} para garantizar
 * que el frontend sea resiliente a futuros cambios en la API (ej. si el backend añade nuevos campos).
 */
public final class AuthDTO {

    /**
     * Constructor privado para evitar instanciación de la clase contenedora.
     */
    private AuthDTO() {}

    // ── Request: Login ────────────────────────────────────────────
    
    /**
     * DTO para enviar las credenciales de inicio de sesión.
     */
    public static class LoginRequest {
        @JsonProperty("email")
        public String email;
        
        @JsonProperty("password")
        public String password;

        public LoginRequest() {}

        public LoginRequest(final String email, final String password) {
            this.email = email;
            this.password = password;
        }
    }

    // ── Response: Login ───────────────────────────────────────────
    
    /**
     * DTO que recibe los datos del usuario tras un login exitoso.
     */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class LoginResponse {
        @JsonProperty("id")
        public Long id;
        
        @JsonProperty("firstName")
        public String firstName;
        
        @JsonProperty("lastName")
        public String lastName;
        
        @JsonProperty("email")
        public String email;
        
        @JsonProperty("role")
        public String role; // "ADMIN" o "CLIENT"

        public LoginResponse() {}
    }

    // ── Request: Register ─────────────────────────────────────────
    
    /**
     * DTO para enviar los datos de creación de una nueva cuenta.
     */
    public static class RegisterRequest {
        @JsonProperty("dni")
        public String dni;
        
        @JsonProperty("firstName")
        public String firstName;
        
        @JsonProperty("lastName")
        public String lastName;
        
        @JsonProperty("email")
        public String email;
        
        @JsonProperty("password")
        public String password;
        
        @JsonProperty("phone")
        public String phone;

        public RegisterRequest() {}

        public RegisterRequest(final String dni, final String firstName, final String lastName,
                               final String email, final String password, final String phone) {
            this.dni = dni;
            this.firstName = firstName;
            this.lastName = lastName;
            this.email = email;
            this.password = password;
            this.phone = phone;
        }
    }

    // ── Response: Error del backend ───────────────────────────────
    
    /**
     * DTO genérico para mapear respuestas de error del servidor (ej. HTTP 400, 500).
     */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class ErrorResponse {
        @JsonProperty("status")
        public int status;
        
        @JsonProperty("message")
        public String message;
        
        @JsonProperty("timestamp")
        public String timestamp;

        public ErrorResponse() {}
    }
}
