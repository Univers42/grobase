package com.hambooking.backend.exception;

/**
 * Excepción lanzada cuando las credenciales proporcionadas por el usuario durante la autenticación son incorrectas.
 */
public class InvalidCredentialsException extends RuntimeException {

    public InvalidCredentialsException(String message) {
        super(message);
    }
}
