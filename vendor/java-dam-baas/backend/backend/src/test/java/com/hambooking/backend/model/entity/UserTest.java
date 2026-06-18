package com.hambooking.backend.model.entity;

import com.hambooking.backend.model.enums.Role;
import jakarta.validation.ConstraintViolation;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import jakarta.validation.ValidatorFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Batería de tests unitarios para la entidad User.
 *
 * Cubre:
 *   - Construcción mediante Builder y constructor vacío
 *   - Valores por defecto (@Builder.Default)
 *   - Getters y Setters (Lombok)
 *   - Validaciones Bean Validation (@NotBlank, @Email, @Pattern, @Size)
 *   - Métodos de utilidad (addReservation / removeReservation)
 *   - equals() y hashCode()
 *   - toString()
 *   - Relación con Carver
 */
@DisplayName("User — Tests unitarios")
class UserTest {

    // =========================================================================
    // INFRAESTRUCTURA DE VALIDACIÓN (Bean Validation sin Spring)
    // =========================================================================

    private static Validator validator;

    @BeforeAll
    static void setUpValidator() {
        ValidatorFactory factory = Validation.buildDefaultValidatorFactory();
        validator = factory.getValidator();
    }

    // =========================================================================
    // MÉTODO AUXILIAR: construye un User válido para reutilizar en los tests
    // =========================================================================

    private User buildValidUser() {
        return User.builder()
                .dni("12345678A")
                .firstName("Juan")
                .lastName("García López")
                .email("juan.garcia@example.com")
                .phone("612345678")
                .passwordHash("$2a$10$hashedpassword")
                .role(Role.CLIENT)
                .isActive(true)
                .build();
    }

    // =========================================================================
    // 1. CONSTRUCCIÓN — Builder y NoArgsConstructor
    // =========================================================================

    @Nested
    @DisplayName("1. Construcción del objeto")
    class Construccion {

        @Test
        @DisplayName("Builder crea User con todos los campos correctamente")
        void builder_conCamposValidos_creaUserCorrectamente() {
            User user = buildValidUser();

            assertAll("Todos los campos deben coincidir con los valores del Builder",
                    () -> assertEquals("12345678A", user.getDni()),
                    () -> assertEquals("Juan", user.getFirstName()),
                    () -> assertEquals("García López", user.getLastName()),
                    () -> assertEquals("juan.garcia@example.com", user.getEmail()),
                    () -> assertEquals("612345678", user.getPhone()),
                    () -> assertEquals("$2a$10$hashedpassword", user.getPasswordHash()),
                    () -> assertEquals(Role.CLIENT, user.getRole()),
                    () -> assertTrue(user.getIsActive())
            );
        }

        @Test
        @DisplayName("NoArgsConstructor crea un User no nulo")
        void noArgsConstructor_creaInstanciaNula() {
            User user = new User();
            assertNotNull(user, "El constructor vacío no debe retornar null");
        }

        @Test
        @DisplayName("NoArgsConstructor: id es null antes de persistir")
        void noArgsConstructor_idEsNullAntesDePersistir() {
            User user = new User();
            assertNull(user.getId(), "El id debe ser null antes de la persistencia");
        }

        @Test
        @DisplayName("AllArgsConstructor crea User con todos los argumentos")
        void allArgsConstructor_creaUserConTodosLosArgumentos() {
            User user = new User(1L, "87654321B", "Ana", "Martínez", "ana@example.com",
                    "698765432", "hash", Role.ADMIN, true, null, null, null, new java.util.ArrayList<>());

            assertEquals(1L, user.getId());
            assertEquals("87654321B", user.getDni());
            assertEquals(Role.ADMIN, user.getRole());
        }
    }

    // =========================================================================
    // 2. VALORES POR DEFECTO (@Builder.Default)
    // =========================================================================

    @Nested
    @DisplayName("2. Valores por defecto")
    class ValoresPorDefecto {

        @Test
        @DisplayName("Role por defecto es CLIENT cuando no se especifica")
        void role_porDefecto_esClient() {
            User user = User.builder()
                    .dni("12345678A")
                    .firstName("Test")
                    .lastName("User")
                    .email("test@example.com")
                    .phone("612345678")
                    .passwordHash("hash")
                    .build();

            assertEquals(Role.CLIENT, user.getRole(),
                    "El rol por defecto debe ser CLIENT si no se especifica");
        }

        @Test
        @DisplayName("isActive por defecto es true cuando no se especifica")
        void isActive_porDefecto_esTrue() {
            User user = User.builder()
                    .dni("12345678A")
                    .firstName("Test")
                    .lastName("User")
                    .email("test@example.com")
                    .phone("612345678")
                    .passwordHash("hash")
                    .build();

            assertTrue(user.getIsActive(),
                    "isActive debe ser true por defecto");
        }

        @Test
        @DisplayName("La lista de reservations se inicializa vacía, no null")
        void reservations_porDefecto_esListaVacia() {
            User user = buildValidUser();

            assertNotNull(user.getReservations(), "La lista de reservations no debe ser null");
            assertTrue(user.getReservations().isEmpty(), "La lista de reservations debe estar vacía al crear");
        }
    }

    // =========================================================================
    // 3. GETTERS Y SETTERS (Lombok)
    // =========================================================================

    @Nested
    @DisplayName("3. Getters y Setters")
    class GettersSetters {

        @Test
        @DisplayName("Setter de firstName actualiza el valor correctamente")
        void setFirstName_actualizaElValor() {
            User user = buildValidUser();
            user.setFirstName("Carlos");
            assertEquals("Carlos", user.getFirstName());
        }

        @Test
        @DisplayName("Setter de email actualiza el valor correctamente")
        void setEmail_actualizaElValor() {
            User user = buildValidUser();
            user.setEmail("nuevo@example.com");
            assertEquals("nuevo@example.com", user.getEmail());
        }

        @Test
        @DisplayName("Setter de isActive permite desactivar el usuario")
        void setIsActive_permiteDesactivar() {
            User user = buildValidUser();
            user.setIsActive(false);
            assertFalse(user.getIsActive());
        }

        @Test
        @DisplayName("Setter de role permite cambiar a ADMIN")
        void setRole_permiteAsignarAdmin() {
            User user = buildValidUser();
            user.setRole(Role.ADMIN);
            assertEquals(Role.ADMIN, user.getRole());
        }

        @Test
        @DisplayName("Setter de id permite asignar un valor")
        void setId_asignaValorCorrectamente() {
            User user = new User();
            user.setId(99L);
            assertEquals(99L, user.getId());
        }
    }

    // =========================================================================
    // 4. VALIDACIONES BEAN VALIDATION — DNI
    // =========================================================================

    @Nested
    @DisplayName("4. Validaciones — DNI")
    class ValidacionesDni {

        @Test
        @DisplayName("DNI válido no genera violaciones")
        void dni_valido_noGeneraViolaciones() {
            User user = buildValidUser(); // DNI: 12345678A
            Set<ConstraintViolation<User>> violations = validator.validateProperty(user, "dni");
            assertTrue(violations.isEmpty());
        }

        @Test
        @DisplayName("DNI nulo genera violación @NotBlank")
        void dni_nulo_generaViolacion() {
            User user = buildValidUser();
            user.setDni(null);
            Set<ConstraintViolation<User>> violations = validator.validateProperty(user, "dni");
            assertFalse(violations.isEmpty());
        }

        @Test
        @DisplayName("DNI vacío genera violación @NotBlank")
        void dni_vacio_generaViolacion() {
            User user = buildValidUser();
            user.setDni("");
            Set<ConstraintViolation<User>> violations = validator.validateProperty(user, "dni");
            assertFalse(violations.isEmpty());
        }

        @ParameterizedTest(name = "DNI inválido: ''{0}''")
        @ValueSource(strings = {
                "1234567",        // Demasiado corto (7 dígitos)
                "123456789",      // 9 dígitos sin letra final
                "ABCDEFGHI",      // Solo letras, sin dígitos
                "1234567 A",      // Espacio en medio
                "1234567AB"       // Dos letras al final
        })
        @DisplayName("DNI con formato incorrecto genera violación @Pattern")
        void dni_formatoIncorrecto_generaViolacion(String dniInvalido) {
            User user = buildValidUser();
            user.setDni(dniInvalido);
            Set<ConstraintViolation<User>> violations = validator.validateProperty(user, "dni");
            assertFalse(violations.isEmpty(),
                    "DNI '" + dniInvalido + "' debería generar una violación de @Pattern");
        }

        @ParameterizedTest(name = "DNI válido: ''{0}''")
        @ValueSource(strings = {"12345678A", "00000001Z", "99999999R", "12345678a"}) // regex acepta [A-Za-z]
        @DisplayName("DNIs con formato correcto no generan violación")
        void dni_formatoCorrecto_noGeneraViolacion(String dniValido) {
            User user = buildValidUser();
            user.setDni(dniValido);
            Set<ConstraintViolation<User>> violations = validator.validateProperty(user, "dni");
            assertTrue(violations.isEmpty(),
                    "DNI '" + dniValido + "' no debería generar violaciones");
        }
    }

    // =========================================================================
    // 5. VALIDACIONES BEAN VALIDATION — Email
    // =========================================================================

    @Nested
    @DisplayName("5. Validaciones — Email")
    class ValidacionesEmail {

        @Test
        @DisplayName("Email válido no genera violaciones")
        void email_valido_noGeneraViolaciones() {
            User user = buildValidUser();
            Set<ConstraintViolation<User>> violations = validator.validateProperty(user, "email");
            assertTrue(violations.isEmpty());
        }

        @Test
        @DisplayName("Email nulo genera violación @NotBlank")
        void email_nulo_generaViolacion() {
            User user = buildValidUser();
            user.setEmail(null);
            Set<ConstraintViolation<User>> violations = validator.validateProperty(user, "email");
            assertFalse(violations.isEmpty());
        }

        @ParameterizedTest(name = "Email inválido: ''{0}''")
        @ValueSource(strings = {
                "sinArroba",          // Sin carácter @
                "@sinlocal.com",      // Sin parte local antes del @
                "doble@@ejemplo.com"  // Doble @
                // NOTA: "sin@dominio" es técnicamente válido según RFC 5321,
                // por eso Hibernate Validator 9 lo acepta. No incluir en inválidos.
        })
        @DisplayName("Emails con formato incorrecto generan violación @Email")
        void email_formatoIncorrecto_generaViolacion(String emailInvalido) {
            User user = buildValidUser();
            user.setEmail(emailInvalido);
            Set<ConstraintViolation<User>> violations = validator.validateProperty(user, "email");
            assertFalse(violations.isEmpty(),
                    "Email '" + emailInvalido + "' debería fallar la validación");
        }
    }

    // =========================================================================
    // 6. VALIDACIONES BEAN VALIDATION — Teléfono
    // =========================================================================

    @Nested
    @DisplayName("6. Validaciones — Teléfono")
    class ValidacionesTelefono {

        @ParameterizedTest(name = "Teléfono válido: ''{0}''")
        @ValueSource(strings = {"612345678", "+34612345678", "123456789012345"})
        @DisplayName("Teléfonos con formato correcto no generan violación")
        void telefono_valido_noGeneraViolacion(String telefonoValido) {
            User user = buildValidUser();
            user.setPhone(telefonoValido);
            Set<ConstraintViolation<User>> violations = validator.validateProperty(user, "phone");
            assertTrue(violations.isEmpty());
        }

        @ParameterizedTest(name = "Teléfono inválido: ''{0}''")
        @ValueSource(strings = {"12345678", "abc123456", "123 456 789", "+", "12345"})
        @DisplayName("Teléfonos con formato incorrecto generan violación @Pattern")
        void telefono_invalido_generaViolacion(String telefonoInvalido) {
            User user = buildValidUser();
            user.setPhone(telefonoInvalido);
            Set<ConstraintViolation<User>> violations = validator.validateProperty(user, "phone");
            assertFalse(violations.isEmpty(),
                    "Teléfono '" + telefonoInvalido + "' debería fallar la validación");
        }
    }

    // =========================================================================
    // 7. VALIDACIONES BEAN VALIDATION — Campos @NotBlank y @Size
    // =========================================================================

    @Nested
    @DisplayName("7. Validaciones — Campos obligatorios y tamaño")
    class ValidacionesCamposObligatorios {

        @Test
        @DisplayName("firstName nulo genera violación @NotBlank")
        void firstName_nulo_generaViolacion() {
            User user = buildValidUser();
            user.setFirstName(null);
            assertFalse(validator.validateProperty(user, "firstName").isEmpty());
        }

        @Test
        @DisplayName("firstName vacío genera violación @NotBlank")
        void firstName_vacio_generaViolacion() {
            User user = buildValidUser();
            user.setFirstName("   ");
            assertFalse(validator.validateProperty(user, "firstName").isEmpty());
        }

        @Test
        @DisplayName("firstName con 100 caracteres exactos no genera violación")
        void firstName_100Caracteres_noGeneraViolacion() {
            User user = buildValidUser();
            user.setFirstName("A".repeat(100));
            assertTrue(validator.validateProperty(user, "firstName").isEmpty());
        }

        @Test
        @DisplayName("firstName con 101 caracteres genera violación @Size")
        void firstName_101Caracteres_generaViolacion() {
            User user = buildValidUser();
            user.setFirstName("A".repeat(101));
            assertFalse(validator.validateProperty(user, "firstName").isEmpty());
        }

        @Test
        @DisplayName("lastName nulo genera violación @NotBlank")
        void lastName_nulo_generaViolacion() {
            User user = buildValidUser();
            user.setLastName(null);
            assertFalse(validator.validateProperty(user, "lastName").isEmpty());
        }

        @Test
        @DisplayName("lastName con 150 caracteres exactos no genera violación")
        void lastName_150Caracteres_noGeneraViolacion() {
            User user = buildValidUser();
            user.setLastName("B".repeat(150));
            assertTrue(validator.validateProperty(user, "lastName").isEmpty());
        }

        @Test
        @DisplayName("lastName con 151 caracteres genera violación @Size")
        void lastName_151Caracteres_generaViolacion() {
            User user = buildValidUser();
            user.setLastName("B".repeat(151));
            assertFalse(validator.validateProperty(user, "lastName").isEmpty());
        }

        @Test
        @DisplayName("passwordHash nulo genera violación @NotBlank")
        void passwordHash_nulo_generaViolacion() {
            User user = buildValidUser();
            user.setPasswordHash(null);
            assertFalse(validator.validateProperty(user, "passwordHash").isEmpty());
        }

        @Test
        @DisplayName("role nulo genera violación @NotNull")
        void role_nulo_generaViolacion() {
            User user = buildValidUser();
            user.setRole(null);
            assertFalse(validator.validateProperty(user, "role").isEmpty());
        }

        @Test
        @DisplayName("User completamente válido: el validador no encuentra violaciones")
        void user_completamenteValido_sinViolaciones() {
            User user = buildValidUser();
            Set<ConstraintViolation<User>> violations = validator.validate(user);
            assertTrue(violations.isEmpty(),
                    "Un User válido no debe tener ninguna violación de constraints");
        }
    }

    // =========================================================================
    // 8. MÉTODOS DE UTILIDAD — addReservation / removeReservation
    // =========================================================================

    @Nested
    @DisplayName("8. Métodos de utilidad — addReservation / removeReservation")
    class MetodosUtilidad {

        @Test
        @DisplayName("addReservation: añade la reserva a la lista del user")
        void addReservation_anadeReservaALista() {
            User user = buildValidUser();
            Reservation reservation = new Reservation();

            user.addReservation(reservation);

            assertEquals(1, user.getReservations().size(),
                    "Debe haber 1 reserva en la lista tras addReservation");
        }

        @Test
        @DisplayName("addReservation: establece el cliente en la reserva (bidireccional)")
        void addReservation_estableceClienteEnReserva() {
            User user = buildValidUser();
            Reservation reservation = new Reservation();

            user.addReservation(reservation);

            assertEquals(user, reservation.getClient(),
                    "La reserva debe apuntar al user como cliente (relación bidireccional)");
        }

        @Test
        @DisplayName("removeReservation: elimina la reserva de la lista del user")
        void removeReservation_eliminaReservaDeLista() {
            User user = buildValidUser();
            Reservation reservation = new Reservation();
            user.addReservation(reservation);

            user.removeReservation(reservation);

            assertTrue(user.getReservations().isEmpty(),
                    "La lista debe estar vacía tras removeReservation");
        }

        @Test
        @DisplayName("removeReservation: pone el cliente de la reserva a null")
        void removeReservation_poneCilentANull() {
            User user = buildValidUser();
            Reservation reservation = new Reservation();
            user.addReservation(reservation);

            user.removeReservation(reservation);

            assertNull(reservation.getClient(),
                    "El cliente de la reserva debe ser null tras removeReservation");
        }

        @Test
        @DisplayName("addReservation: se pueden añadir múltiples reservas")
        void addReservation_variosReservaciones_listaCreceCorrectamente() {
            User user = buildValidUser();

            user.addReservation(new Reservation());
            user.addReservation(new Reservation());
            user.addReservation(new Reservation());

            assertEquals(3, user.getReservations().size());
        }
    }

    // =========================================================================
    // 9. EQUALS Y HASHCODE
    // =========================================================================

    @Nested
    @DisplayName("9. equals() y hashCode()")
    class EqualsHashCode {

        @Test
        @DisplayName("Un User es igual a sí mismo (reflexividad)")
        void equals_mismoObjeto_esIgual() {
            User user = buildValidUser();
            assertEquals(user, user);
        }

        @Test
        @DisplayName("Dos Users con el mismo id son iguales")
        void equals_mismoId_sonIguales() {
            User user1 = buildValidUser();
            User user2 = buildValidUser();
            user1.setId(1L);
            user2.setId(1L);

            assertEquals(user1, user2);
        }

        @Test
        @DisplayName("Dos Users con distinto id no son iguales")
        void equals_diferenteId_noSonIguales() {
            User user1 = buildValidUser();
            User user2 = buildValidUser();
            user1.setId(1L);
            user2.setId(2L);

            assertNotEquals(user1, user2);
        }

        @Test
        @DisplayName("Un User con id null no es igual a otro con id null (sin persistir)")
        void equals_ambosIdNull_noSonIguales() {
            User user1 = buildValidUser(); // id = null
            User user2 = buildValidUser(); // id = null

            // Ambos sin id (no persistidos): equals devuelve false porque id == null
            assertNotEquals(user1, user2,
                    "Dos entidades sin id no deben considerarse iguales");
        }

        @Test
        @DisplayName("User no es igual a null")
        void equals_vsNull_noEsIgual() {
            User user = buildValidUser();
            assertNotEquals(null, user);
        }

        @Test
        @DisplayName("User no es igual a un objeto de otra clase")
        void equals_otraClase_noEsIgual() {
            User user = buildValidUser();
            assertNotEquals("string", user);
        }

        @Test
        @DisplayName("hashCode es consistente: mismo objeto, mismo hash siempre")
        void hashCode_esConsistente() {
            User user = buildValidUser();
            int hash1 = user.hashCode();
            int hash2 = user.hashCode();
            assertEquals(hash1, hash2);
        }

        @Test
        @DisplayName("Dos Users con mismo id tienen el mismo hashCode")
        void hashCode_mismoId_mismoHash() {
            User user1 = buildValidUser();
            User user2 = buildValidUser();
            user1.setId(5L);
            user2.setId(5L);

            // Ambos son instancias de User: hashCode = getClass().hashCode() → mismo resultado
            assertEquals(user1.hashCode(), user2.hashCode());
        }
    }

    // =========================================================================
    // 10. TOSTRING
    // =========================================================================

    @Nested
    @DisplayName("10. toString()")
    class ToStringTest {

        @Test
        @DisplayName("toString() no retorna null")
        void toString_noRetornaNull() {
            User user = buildValidUser();
            assertNotNull(user.toString());
        }

        @Test
        @DisplayName("toString() contiene el DNI del usuario")
        void toString_contieneDni() {
            User user = buildValidUser();
            assertTrue(user.toString().contains("12345678A"),
                    "toString debe incluir el DNI");
        }

        @Test
        @DisplayName("toString() contiene el email del usuario")
        void toString_contieneEmail() {
            User user = buildValidUser();
            assertTrue(user.toString().contains("juan.garcia@example.com"),
                    "toString debe incluir el email");
        }

        @Test
        @DisplayName("toString() contiene el rol del usuario")
        void toString_contieneRole() {
            User user = buildValidUser();
            assertTrue(user.toString().contains("CLIENT"),
                    "toString debe incluir el rol");
        }

        @Test
        @DisplayName("toString() NO expone el passwordHash (seguridad)")
        void toString_noExponePassword() {
            User user = buildValidUser();
            assertFalse(user.toString().contains("$2a$10$hashedpassword"),
                    "toString NO debe exponer el hash de la contraseña por seguridad");
        }
    }

    // =========================================================================
    // 11. RELACIÓN CON CARVER
    // =========================================================================

    @Nested
    @DisplayName("11. Relación con Carver")
    class RelacionCarver {

        @Test
        @DisplayName("Un User nuevo no tiene Carver asociado (null)")
        void carver_porDefecto_esNull() {
            User user = buildValidUser();
            assertNull(user.getCarver(),
                    "Un usuario nuevo no tiene perfil de cortador");
        }

        @Test
        @DisplayName("Se puede asignar un Carver a un User")
        void setCarver_asignaCarverCorrectamente() {
            User user = buildValidUser();
            Carver carver = new Carver();

            user.setCarver(carver);

            assertEquals(carver, user.getCarver());
        }
    }
}