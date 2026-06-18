package com.hambooking.backend.exception;

/**
 * Excepción lanzada cuando se intenta realizar una reserva en un horario que ya está ocupado o no se encuentra disponible.
 */
public class TimeSlotNotAvailableException extends RuntimeException {

    public TimeSlotNotAvailableException(String message) {
        super(message);
    }
}
