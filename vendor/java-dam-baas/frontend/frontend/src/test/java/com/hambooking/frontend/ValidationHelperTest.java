package com.hambooking.frontend;

import com.hambooking.frontend.util.ValidationHelper;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Batería de tests unitarios para asegurar la integridad de la lógica de validación
 * del frontend (Reglas de Negocio Desacopladas de la UI).
 */
@DisplayName("ValidationHelper - Tests Unitarios")
class ValidationHelperTest {

    @Nested
    @DisplayName("Validación de Cadenas Nulas o Vacías")
    class NullOrEmptyTests {
        
        @Test
        void isNullOrEmpty_WithNull_ReturnsTrue() {
            assertTrue(ValidationHelper.isNullOrEmpty(null));
        }

        @Test
        void isNullOrEmpty_WithEmptyString_ReturnsTrue() {
            assertTrue(ValidationHelper.isNullOrEmpty(""));
        }

        @Test
        void isNullOrEmpty_WithSpaces_ReturnsTrue() {
            assertTrue(ValidationHelper.isNullOrEmpty("   "));
        }

        @Test
        void isNullOrEmpty_WithValidText_ReturnsFalse() {
            assertFalse(ValidationHelper.isNullOrEmpty("texto"));
        }
    }

    @Nested
    @DisplayName("Validación de Email")
    class EmailTests {

        @Test
        @DisplayName("Email válido")
        void isValidEmail_WithValidEmails_ReturnsTrue() {
            String[] emails = {"test@test.com", "nombre.apellido@dominio.org", "123user@app.net", "u+tag@domain.co"};
            for (String email : emails) {
                assertTrue(ValidationHelper.isValidEmail(email));
            }
        }

        @Test
        @DisplayName("Email inválido")
        void isValidEmail_WithInvalidEmails_ReturnsFalse() {
            String[] emails = {"sindominio", "sinarroba.com", "@sinnombre.es"};
            for (String email : emails) {
                assertFalse(ValidationHelper.isValidEmail(email));
            }
        }
        
        @Test
        void isValidEmail_WithNullOrEmpty_ReturnsFalse() {
            assertFalse(ValidationHelper.isValidEmail(null));
            assertFalse(ValidationHelper.isValidEmail("   "));
        }
    }

    @Nested
    @DisplayName("Validación de Contraseñas Seguras")
    class PasswordTests {

        @Test
        @DisplayName("Contraseña válida: min 8 chars, 1 mayúscula, 1 número")
        void isStrongPassword_ValidPassword_ReturnsTrue() {
            assertTrue(ValidationHelper.isStrongPassword("Pass1234"));
            assertTrue(ValidationHelper.isStrongPassword("S3gura!!"));
        }

        @Test
        @DisplayName("Contraseña inválida: menor a 8 caracteres")
        void isStrongPassword_TooShort_ReturnsFalse() {
            assertFalse(ValidationHelper.isStrongPassword("Pass123")); // 7 chars
        }

        @Test
        @DisplayName("Contraseña inválida: sin mayúsculas")
        void isStrongPassword_NoUpperCase_ReturnsFalse() {
            assertFalse(ValidationHelper.isStrongPassword("password123"));
        }

        @Test
        @DisplayName("Contraseña inválida: sin números")
        void isStrongPassword_NoNumbers_ReturnsFalse() {
            assertFalse(ValidationHelper.isStrongPassword("Password"));
        }
    }

    @Nested
    @DisplayName("Validación de DNI")
    class DniTests {

        @Test
        @DisplayName("DNI con formato correcto")
        void isValidDNI_WithValidDNI_ReturnsTrue() {
            String[] dnis = {"12345678A", "00000000Z", "87654321B"};
            for (String dni : dnis) {
                assertTrue(ValidationHelper.isValidDNI(dni), "Fallo con: " + dni);
            }
        }

        @Test
        @DisplayName("DNI con formato incorrecto")
        void isValidDNI_WithInvalidDNI_ReturnsFalse() {
            String[] dnis = {"1234567A", "123456789", "A2345678B", "12345678 "};
            for (String dni : dnis) {
                assertFalse(ValidationHelper.isValidDNI(dni), "Fallo con: " + dni);
            }
        }
    }

    @Nested
    @DisplayName("Validación de Teléfono")
    class PhoneTests {

        @Test
        void isValidPhone_WithValidSpanishPhone_ReturnsTrue() {
            assertTrue(ValidationHelper.isValidPhone("612345678"));
            assertTrue(ValidationHelper.isValidPhone("912345678"));
        }

        @Test
        void isValidPhone_WithInvalidLengthOrChars_ReturnsFalse() {
            assertFalse(ValidationHelper.isValidPhone("12345678")); // 8 chars
            assertFalse(ValidationHelper.isValidPhone("1234567890")); // 10 chars
            assertFalse(ValidationHelper.isValidPhone("612345abc")); // con letras
        }
    }
}
