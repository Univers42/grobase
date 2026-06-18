package com.hambooking.frontend.service;

/**
 * Excepción personalizada para errores ocurridos durante las peticiones a la API REST.
 * Captura tanto el mensaje amigable para el usuario como el código de estado HTTP.
 */
public class ApiException extends Exception {
    private final int statusCode;

    /**
     * Construye una nueva excepción de API.
     *
     * @param message    Mensaje de error descriptivo.
     * @param statusCode Código de estado HTTP (0 si es un error de conexión).
     */
    public ApiException(String message, int statusCode) {
        super(message);
        this.statusCode = statusCode;
    }

    public int getStatusCode() {
        return statusCode;
    }

    public boolean isConnectionError() {
        return statusCode == 0;
    }

    public boolean isUnauthorized() {
        return statusCode == 401;
    }

    public boolean isConflict() {
        return statusCode == 409;
    }

    public boolean isNotFound() {
        return statusCode == 404;
    }
}
