package com.hambooking.backend.exception;

/**
 * Excepción lanzada cuando un usuario intenta realizar más reservas activas de las permitidas por el sistema.
 */
public class ReservationLimitExceededException extends RuntimeException {

    public ReservationLimitExceededException(String message) {
        super(message);
    }
}
