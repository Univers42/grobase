package com.hambooking.backend.exception;

/**
 * Excepción genérica para violaciones de reglas de negocio.
 * Se lanza cuando una operación no cumple con las políticas de negocio establecidas en el sistema.
 */
public class BusinessRuleException extends RuntimeException {

    public BusinessRuleException(String message) {
        super(message);
    }
}
