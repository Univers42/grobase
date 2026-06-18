package com.hambooking.frontend.util;

/**
 * Utilidad centralizada para encapsular la lógica de validación de negocio.
 * Sigue el principio SRP (Single Responsibility Principle) al separar 
 * la validación de la UI en los controladores, permitiendo pruebas unitarias completas.
 */
public final class ValidationHelper {

    private static final String REGEX_DNI = "^[0-9]{8}[A-Za-z]$";
    private static final String REGEX_PHONE = "^[0-9]{9}$";
    // Regex estándar simplificado para la validación básica de emails en el frontend.
    private static final String REGEX_EMAIL = "^[A-Za-z0-9+_.-]+@(.+)$";

    private ValidationHelper() {}

    /**
     * Verifica si una cadena nula o vacía.
     */
    public static boolean isNullOrEmpty(final String text) {
        return text == null || text.trim().isEmpty();
    }

    /**
     * Valida el formato del DNI (8 números seguidos de una letra).
     */
    public static boolean isValidDNI(final String dni) {
        if (isNullOrEmpty(dni)) return false;
        return dni.trim().matches(REGEX_DNI);
    }

    /**
     * Valida el formato del teléfono (9 dígitos numéricos).
     */
    public static boolean isValidPhone(final String phone) {
        if (isNullOrEmpty(phone)) return false;
        return phone.trim().matches(REGEX_PHONE);
    }

    /**
     * Valida el formato del correo electrónico mediante Regex.
     */
    public static boolean isValidEmail(final String email) {
        if (isNullOrEmpty(email)) return false;
        return email.trim().matches(REGEX_EMAIL);
    }

    /**
     * Comprueba si la contraseña es segura:
     * - Al menos 8 caracteres
     * - Al menos una mayúscula
     * - Al menos un número
     */
    public static boolean isStrongPassword(final String password) {
        if (isNullOrEmpty(password) || password.length() < 8) {
            return false;
        }
        
        final boolean tieneMayuscula = password.chars().anyMatch(Character::isUpperCase);
        final boolean tieneNumero = password.chars().anyMatch(Character::isDigit);
        
        return tieneMayuscula && tieneNumero;
    }
}
