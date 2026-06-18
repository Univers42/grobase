package com.hambooking.backend.exception;

import lombok.Getter;
import java.time.LocalDateTime;

/**
 * Representa una respuesta de error estandarizada para la API.
 * Proporciona detalles sobre el código de estado, el mensaje y el momento exacto del error.
 */
@Getter
public class ErrorResponse {

    /**
     * El código de estado HTTP del error.
     */
    private int status;

    /**
     * El mensaje descriptivo del error ocurrido.
     */
    private String message;

    /**
     * La marca de tiempo que indica cuándo se generó el error.
     */
    private LocalDateTime timestamp;

    public ErrorResponse(int status, String message) {
        this.status = status;
        this.message = message;
        this.timestamp = LocalDateTime.now();
    }
}
