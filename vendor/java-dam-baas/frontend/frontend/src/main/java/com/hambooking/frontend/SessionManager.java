package com.hambooking.frontend;

import com.hambooking.frontend.dto.AuthDTO;

/**
 * Gestor de sesión único (Singleton) para la aplicación HamBooking.
 * Esta clase es responsable de mantener en memoria los datos del usuario autenticado
 * durante el ciclo de vida de la ejecución. Permite el acceso global a la información
 * del perfil y los permisos del usuario.
 */
public final class SessionManager {

    /** Identificador único del usuario en la base de datos. */
    private Long userId;
    
    /** Nombre de pila del usuario. */
    private String firstName;
    
    /** Apellidos del usuario. */
    private String lastName;
    
    /** Dirección de correo electrónico asociada a la cuenta. */
    private String email;
    
    /** Rol asignado al usuario (ej. "ADMIN" o "CLIENT"). */
    private String role;

    /**
     * Constructor privado para impedir la instanciación externa.
     */
    private SessionManager() {}

    /**
     * Clase estática interna para la inicialización segura y eficiente del Singleton (Bill Pugh).
     */
    private static class Holder {
        private static final SessionManager INSTANCE = new SessionManager();
    }

    /**
     * Obtiene la instancia única de SessionManager.
     *
     * @return La instancia global de la sesión.
     */
    public static SessionManager getInstance() {
        return Holder.INSTANCE;
    }

    /**
     * Obtiene el ID del usuario actual.
     *
     * @return Long con el identificador del usuario.
     */
    public Long getUserId() {
        return userId;
    }

    /**
     * Obtiene el nombre del usuario.
     *
     * @return Cadena con el nombre de pila.
     */
    public String getFirstName() {
        return firstName;
    }

    /**
     * Obtiene los apellidos del usuario.
     *
     * @return Cadena con los apellidos.
     */
    public String getLastName() {
        return lastName;
    }

    /**
     * Obtiene el correo electrónico del usuario.
     *
     * @return Cadena con el email.
     */
    public String getEmail() {
        return email;
    }

    /**
     * Obtiene el rol del usuario.
     *
     * @return Cadena con el rol ("ADMIN" o "CLIENT").
     */
    public String getRole() {
        return role;
    }

    /**
     * Genera el nombre completo combinando nombre y apellidos.
     *
     * @return Cadena con el formato "Nombre Apellidos".
     */
    public String getFullName() {
        return (firstName != null ? firstName : "") + " " + (lastName != null ? lastName : "");
    }

    /**
     * Verifica si el usuario actual tiene privilegios de administrador.
     *
     * @return true si el rol es "ADMIN", false en caso contrario.
     */
    public boolean isAdmin() {
        return "ADMIN".equals(role);
    }

    /**
     * Comprueba si hay una sesión activa de usuario.
     *
     * @return true si existe un userId cargado, false si la sesión está vacía.
     */
    public boolean isLoggedIn() {
        return userId != null;
    }

    /**
     * Inicializa los datos de la sesión a partir de un objeto de respuesta de login.
     * Este método debe invocarse únicamente tras una autenticación exitosa.
     *
     * @param user DTO con la información del usuario autenticado.
     */
    public void setSession(final AuthDTO.LoginResponse user) {
        if (user != null) {
            this.userId = user.id;
            this.firstName = user.firstName;
            this.lastName = user.lastName;
            this.email = user.email;
            this.role = user.role;
        }
    }

    /**
     * Limpia todos los datos de la sesión actual. 
     * Debe llamarse al realizar un logout para garantizar que no quede información sensible en memoria.
     */
    public void clear() {
        this.userId = null;
        this.firstName = null;
        this.lastName = null;
        this.email = null;
        this.role = null;
    }
}
