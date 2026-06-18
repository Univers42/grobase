package com.hambooking.backend.exception;

/**
 * Excepción lanzada cuando un recurso solicitado (por ejemplo, usuario o reserva) no existe en la base de datos.
 */
public class ResourceNotFoundException extends RuntimeException {

    public ResourceNotFoundException(String message) {
        super(message);
    }
}
