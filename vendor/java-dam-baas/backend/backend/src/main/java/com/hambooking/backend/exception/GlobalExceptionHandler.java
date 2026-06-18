package com.hambooking.backend.exception;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

/**
 * Controlador global de excepciones que captura y maneja los errores en toda la aplicación.
 * Centraliza la lógica de tratamiento de excepciones para devolver respuestas HTTP estandarizadas.
 */
@RestControllerAdvice
public class GlobalExceptionHandler {

    /**
     * Maneja las excepciones lanzadas por credenciales de acceso inválidas.
     *
     * @param ex La excepción capturada de credenciales inválidas.
     * @return Una respuesta con estado 401 Unauthorized y el cuerpo del error detallado.
     */
    @ExceptionHandler(InvalidCredentialsException.class)
    public ResponseEntity<ErrorResponse> handleInvalidCredentials(InvalidCredentialsException ex) {
        ErrorResponse error = new ErrorResponse(
                HttpStatus.UNAUTHORIZED.value(),
                ex.getMessage()
        );
        return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(error);
    }

    /**
     * Maneja las excepciones genéricas de violación de reglas de negocio.
     *
     * @param ex La excepción de regla de negocio capturada.
     * @return Una respuesta con estado 422 Unprocessable Entity y el detalle del error.
     */
    @ExceptionHandler(BusinessRuleException.class)
    public ResponseEntity<ErrorResponse> handleBusinessRule(BusinessRuleException ex) {
        ErrorResponse error = new ErrorResponse(
                HttpStatus.UNPROCESSABLE_ENTITY.value(),
                ex.getMessage()
        );
        return ResponseEntity.status(HttpStatus.UNPROCESSABLE_ENTITY).body(error);
    }

    /**
     * Maneja las excepciones cuando no se encuentra un recurso específico.
     *
     * @param ex La excepción de recurso no encontrado capturada.
     * @return Una respuesta con estado 404 Not Found y el detalle del error.
     */
    @ExceptionHandler(ResourceNotFoundException.class)
    public ResponseEntity<ErrorResponse> handleResourceNotFound(ResourceNotFoundException ex) {
        ErrorResponse error = new ErrorResponse(
                HttpStatus.NOT_FOUND.value(),
                ex.getMessage()
        );
        return ResponseEntity.status(HttpStatus.NOT_FOUND).body(error);
    }

    /**
     * Maneja las excepciones por falta de disponibilidad en un horario solicitado.
     *
     * @param ex La excepción de horario no disponible capturada.
     * @return Una respuesta con estado 409 Conflict y el detalle del error.
     */
    @ExceptionHandler(TimeSlotNotAvailableException.class)
    public ResponseEntity<ErrorResponse> handleTimeSlotNotAvailable(TimeSlotNotAvailableException ex) {
        ErrorResponse error = new ErrorResponse(
                HttpStatus.CONFLICT.value(),
                ex.getMessage()
        );
        return ResponseEntity.status(HttpStatus.CONFLICT).body(error);
    }

    /**
     * Maneja las excepciones cuando un usuario ha excedido su límite permitido de reservas.
     *
     * @param ex La excepción de límite de reservas excedido capturada.
     * @return Una respuesta con estado 422 Unprocessable Entity y el detalle del error.
     */
    @ExceptionHandler(ReservationLimitExceededException.class)
    public ResponseEntity<ErrorResponse> handleReservationLimitExceeded(ReservationLimitExceededException ex) {
        ErrorResponse error = new ErrorResponse(
                HttpStatus.UNPROCESSABLE_ENTITY.value(),
                ex.getMessage()
        );
        return ResponseEntity.status(HttpStatus.UNPROCESSABLE_ENTITY).body(error);
    }
}
