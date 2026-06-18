package com.hambooking.backend.model.entity;

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
 * Batería de tests unitarios para la entidad Carver.
 *
 * Cubre:
 *   - Construcción mediante Builder y constructor vacío
 *   - Valores por defecto (@Builder.Default)
 *   - Getters y Setters (Lombok)
 *   - Validaciones Bean Validation (@Size, @Min, @Max)
 *   - Métodos de utilidad (addReservation / removeReservation)
 *   - Relación bidireccional con User (OneToOne)
 *   - equals() y hashCode()
 *   - toString() (incluye verificación de que no vuelca la entidad User entera)
 */
@DisplayName("Carver — Tests unitarios")
class CarverTest {

    // =========================================================================
    // INFRAESTRUCTURA DE VALIDACIÓN
    // =========================================================================

    private static Validator validator;

    @BeforeAll
    static void setUpValidator() {
        ValidatorFactory factory = Validation.buildDefaultValidatorFactory();
        validator = factory.getValidator();
    }

    // =========================================================================
    // MÉTODO AUXILIAR: construye un Carver válido para reutilizar en los tests
    // =========================================================================

    private Carver buildValidCarver() {
        return Carver.builder()
                .specialty("Jamón Ibérico")
                .experienceYears(5)
                .maxHamsPerDay(3)
                .isActive(true)
                .build();
    }

    private User buildValidUser() {
        return User.builder()
                .dni("12345678A")
                .firstName("Pedro")
                .lastName("Cortador")
                .email("pedro@example.com")
                .phone("612345678")
                .passwordHash("$2a$10$hash")
                .build();
    }

    // =========================================================================
    // 1. CONSTRUCCIÓN — Builder y NoArgsConstructor
    // =========================================================================

    @Nested
    @DisplayName("1. Construcción del objeto")
    class Construccion {

        @Test
        @DisplayName("Builder crea Carver con todos los campos correctamente")
        void builder_conCamposValidos_creaCarverCorrectamente() {
            Carver carver = buildValidCarver();

            assertAll("Todos los campos deben coincidir con los valores del Builder",
                    () -> assertEquals("Jamón Ibérico", carver.getSpecialty()),
                    () -> assertEquals(5, carver.getExperienceYears()),
                    () -> assertEquals(3, carver.getMaxHamsPerDay()),
                    () -> assertTrue(carver.getIsActive())
            );
        }

        @Test
        @DisplayName("NoArgsConstructor crea una instancia no nula")
        void noArgsConstructor_creaInstanciaNoNula() {
            Carver carver = new Carver();
            assertNotNull(carver);
        }

        @Test
        @DisplayName("NoArgsConstructor: id es null antes de persistir")
        void noArgsConstructor_idEsNullAntesDePersistir() {
            Carver carver = new Carver();
            assertNull(carver.getId());
        }

        @Test
        @DisplayName("Builder sin user asignado: user es null")
        void builder_sinUser_userEsNull() {
            Carver carver = buildValidCarver();
            assertNull(carver.getUser(),
                    "El user debe ser null si no se asigna explícitamente en el Builder");
        }

        @Test
        @DisplayName("Builder con user asignado: user queda correctamente referenciado")
        void builder_conUser_userEsReferenciado() {
            User user = buildValidUser();
            Carver carver = Carver.builder()
                    .user(user)
                    .specialty("Paleta")
                    .build();

            assertEquals(user, carver.getUser());
        }
    }

    // =========================================================================
    // 2. VALORES POR DEFECTO (@Builder.Default)
    // =========================================================================

    @Nested
    @DisplayName("2. Valores por defecto")
    class ValoresPorDefecto {

        @Test
        @DisplayName("experienceYears por defecto es 0")
        void experienceYears_porDefecto_esCero() {
            Carver carver = Carver.builder().build();
            assertEquals(0, carver.getExperienceYears(),
                    "Los años de experiencia deben ser 0 por defecto");
        }

        @Test
        @DisplayName("maxHamsPerDay por defecto es 3")
        void maxHamsPerDay_porDefecto_esTres() {
            Carver carver = Carver.builder().build();
            assertEquals(3, carver.getMaxHamsPerDay(),
                    "El límite por defecto de servicios/día debe ser 3");
        }

        @Test
        @DisplayName("isActive por defecto es true")
        void isActive_porDefecto_esTrue() {
            Carver carver = Carver.builder().build();
            assertTrue(carver.getIsActive(),
                    "El carver debe estar activo por defecto");
        }

        @Test
        @DisplayName("La lista de reservations se inicializa vacía, no null")
        void reservations_porDefecto_esListaVaciaNoNull() {
            Carver carver = buildValidCarver();
            assertNotNull(carver.getReservations());
            assertTrue(carver.getReservations().isEmpty());
        }
    }

    // =========================================================================
    // 3. GETTERS Y SETTERS (Lombok)
    // =========================================================================

    @Nested
    @DisplayName("3. Getters y Setters")
    class GettersSetters {

        @Test
        @DisplayName("Setter de specialty actualiza el valor correctamente")
        void setSpecialty_actualizaElValor() {
            Carver carver = buildValidCarver();
            carver.setSpecialty("Embutidos");
            assertEquals("Embutidos", carver.getSpecialty());
        }

        @Test
        @DisplayName("Setter de experienceYears actualiza el valor correctamente")
        void setExperienceYears_actualizaElValor() {
            Carver carver = buildValidCarver();
            carver.setExperienceYears(10);
            assertEquals(10, carver.getExperienceYears());
        }

        @Test
        @DisplayName("Setter de maxHamsPerDay actualiza el valor correctamente")
        void setMaxHamsPerDay_actualizaElValor() {
            Carver carver = buildValidCarver();
            carver.setMaxHamsPerDay(5);
            assertEquals(5, carver.getMaxHamsPerDay());
        }

        @Test
        @DisplayName("Setter de isActive permite desactivar el carver")
        void setIsActive_permiteDesactivar() {
            Carver carver = buildValidCarver();
            carver.setIsActive(false);
            assertFalse(carver.getIsActive());
        }

        @Test
        @DisplayName("Setter de id permite asignar un valor")
        void setId_asignaValorCorrectamente() {
            Carver carver = new Carver();
            carver.setId(42L);
            assertEquals(42L, carver.getId());
        }

        @Test
        @DisplayName("specialty puede ser null (campo opcional)")
        void setSpecialty_puedeSerNull() {
            Carver carver = buildValidCarver();
            carver.setSpecialty(null);
            // No debe lanzar excepción — specialty es opcional
            assertNull(carver.getSpecialty());
        }
    }

    // =========================================================================
    // 4. VALIDACIONES — specialty (@Size)
    // =========================================================================

    @Nested
    @DisplayName("4. Validaciones — specialty")
    class ValidacionesSpecialty {

        @Test
        @DisplayName("specialty null no genera violación (campo opcional)")
        void specialty_null_noGeneraViolacion() {
            Carver carver = buildValidCarver();
            carver.setSpecialty(null);
            assertTrue(validator.validateProperty(carver, "specialty").isEmpty(),
                    "specialty es opcional, null no debe generar violación");
        }

        @Test
        @DisplayName("specialty vacía no genera violación (no tiene @NotBlank)")
        void specialty_vacia_noGeneraViolacion() {
            Carver carver = buildValidCarver();
            carver.setSpecialty("");
            assertTrue(validator.validateProperty(carver, "specialty").isEmpty());
        }

        @Test
        @DisplayName("specialty con 100 caracteres exactos no genera violación")
        void specialty_100Caracteres_noGeneraViolacion() {
            Carver carver = buildValidCarver();
            carver.setSpecialty("J".repeat(100));
            assertTrue(validator.validateProperty(carver, "specialty").isEmpty());
        }

        @Test
        @DisplayName("specialty con 101 caracteres genera violación @Size")
        void specialty_101Caracteres_generaViolacion() {
            Carver carver = buildValidCarver();
            carver.setSpecialty("J".repeat(101));
            assertFalse(validator.validateProperty(carver, "specialty").isEmpty(),
                    "specialty de 101 caracteres debe violar @Size(max=100)");
        }
    }

    // =========================================================================
    // 5. VALIDACIONES — experienceYears (@Min)
    // =========================================================================

    @Nested
    @DisplayName("5. Validaciones — experienceYears")
    class ValidacionesExperienceYears {

        @Test
        @DisplayName("experienceYears = 0 es válido (valor límite mínimo)")
        void experienceYears_cero_esValido() {
            Carver carver = buildValidCarver();
            carver.setExperienceYears(0);
            assertTrue(validator.validateProperty(carver, "experienceYears").isEmpty());
        }

        @Test
        @DisplayName("experienceYears positivo es válido")
        void experienceYears_positivo_esValido() {
            Carver carver = buildValidCarver();
            carver.setExperienceYears(20);
            assertTrue(validator.validateProperty(carver, "experienceYears").isEmpty());
        }

        @Test
        @DisplayName("experienceYears negativo genera violación @Min(0)")
        void experienceYears_negativo_generaViolacion() {
            Carver carver = buildValidCarver();
            carver.setExperienceYears(-1);
            Set<ConstraintViolation<Carver>> violations =
                    validator.validateProperty(carver, "experienceYears");
            assertFalse(violations.isEmpty(),
                    "experienceYears negativo debe violar @Min(value=0)");
        }
    }

    // =========================================================================
    // 6. VALIDACIONES — maxHamsPerDay (@Min + @Max)
    // =========================================================================

    @Nested
    @DisplayName("6. Validaciones — maxHamsPerDay")
    class ValidacionesMaxHamsPerDay {

        @Test
        @DisplayName("maxHamsPerDay = 1 es válido (valor límite mínimo)")
        void maxHamsPerDay_uno_esValido() {
            Carver carver = buildValidCarver();
            carver.setMaxHamsPerDay(1);
            assertTrue(validator.validateProperty(carver, "maxHamsPerDay").isEmpty());
        }

        @Test
        @DisplayName("maxHamsPerDay = 10 es válido (valor límite máximo)")
        void maxHamsPerDay_diez_esValido() {
            Carver carver = buildValidCarver();
            carver.setMaxHamsPerDay(10);
            assertTrue(validator.validateProperty(carver, "maxHamsPerDay").isEmpty());
        }

        @ParameterizedTest(name = "maxHamsPerDay válido: {0}")
        @ValueSource(ints = {1, 2, 3, 5, 7, 10})
        @DisplayName("Valores entre 1 y 10 son válidos")
        void maxHamsPerDay_entreUnoYDiez_esValido(int valor) {
            Carver carver = buildValidCarver();
            carver.setMaxHamsPerDay(valor);
            assertTrue(validator.validateProperty(carver, "maxHamsPerDay").isEmpty(),
                    "maxHamsPerDay=" + valor + " debería ser válido");
        }

        @Test
        @DisplayName("maxHamsPerDay = 0 genera violación @Min(1)")
        void maxHamsPerDay_cero_generaViolacion() {
            Carver carver = buildValidCarver();
            carver.setMaxHamsPerDay(0);
            assertFalse(validator.validateProperty(carver, "maxHamsPerDay").isEmpty(),
                    "maxHamsPerDay=0 debe violar @Min(value=1)");
        }

        @Test
        @DisplayName("maxHamsPerDay negativo genera violación @Min(1)")
        void maxHamsPerDay_negativo_generaViolacion() {
            Carver carver = buildValidCarver();
            carver.setMaxHamsPerDay(-5);
            assertFalse(validator.validateProperty(carver, "maxHamsPerDay").isEmpty());
        }

        @Test
        @DisplayName("maxHamsPerDay = 11 genera violación @Max(10)")
        void maxHamsPerDay_once_generaViolacion() {
            Carver carver = buildValidCarver();
            carver.setMaxHamsPerDay(11);
            assertFalse(validator.validateProperty(carver, "maxHamsPerDay").isEmpty(),
                    "maxHamsPerDay=11 debe violar @Max(value=10)");
        }

        @Test
        @DisplayName("maxHamsPerDay muy alto genera violación @Max(10)")
        void maxHamsPerDay_muyAlto_generaViolacion() {
            Carver carver = buildValidCarver();
            carver.setMaxHamsPerDay(999);
            assertFalse(validator.validateProperty(carver, "maxHamsPerDay").isEmpty());
        }
    }

    // =========================================================================
    // 7. CARVER COMPLETAMENTE VÁLIDO
    // =========================================================================

    @Nested
    @DisplayName("7. Validación global")
    class ValidacionGlobal {

        @Test
        @DisplayName("Carver completamente válido: sin ninguna violación")
        void carver_completamenteValido_sinViolaciones() {
            Carver carver = buildValidCarver();
            Set<ConstraintViolation<Carver>> violations = validator.validate(carver);
            assertTrue(violations.isEmpty(),
                    "Un Carver válido no debe tener ninguna violación");
        }

        @Test
        @DisplayName("Carver solo con defaults (sin especialidad) es válido")
        void carver_soloConDefaults_esValido() {
            // specialty es opcional, por lo que un Carver sin ella debe ser válido
            Carver carver = Carver.builder().build();
            Set<ConstraintViolation<Carver>> violations = validator.validate(carver);
            assertTrue(violations.isEmpty(),
                    "Un Carver con valores por defecto y sin specialty debe ser válido");
        }
    }

    // =========================================================================
    // 8. MÉTODOS DE UTILIDAD — addReservation / removeReservation
    // =========================================================================

    @Nested
    @DisplayName("8. Métodos de utilidad — addReservation / removeReservation")
    class MetodosUtilidad {

        @Test
        @DisplayName("addReservation: añade la reserva a la lista del carver")
        void addReservation_anadeReservaALista() {
            Carver carver = buildValidCarver();
            Reservation reservation = new Reservation();

            carver.addReservation(reservation);

            assertEquals(1, carver.getReservations().size());
        }

        @Test
        @DisplayName("addReservation: establece el carver en la reserva (bidireccional)")
        void addReservation_estableceCarverEnReserva() {
            Carver carver = buildValidCarver();
            Reservation reservation = new Reservation();

            carver.addReservation(reservation);

            assertEquals(carver, reservation.getCarver(),
                    "La reserva debe apuntar al carver (relación bidireccional)");
        }

        @Test
        @DisplayName("removeReservation: elimina la reserva de la lista del carver")
        void removeReservation_eliminaReservaDeLista() {
            Carver carver = buildValidCarver();
            Reservation reservation = new Reservation();
            carver.addReservation(reservation);

            carver.removeReservation(reservation);

            assertTrue(carver.getReservations().isEmpty());
        }

        @Test
        @DisplayName("removeReservation: pone el carver de la reserva a null")
        void removeReservation_poneCarverANull() {
            Carver carver = buildValidCarver();
            Reservation reservation = new Reservation();
            carver.addReservation(reservation);

            carver.removeReservation(reservation);

            assertNull(reservation.getCarver(),
                    "El carver de la reserva debe ser null tras removeReservation");
        }

        @Test
        @DisplayName("addReservation: se pueden añadir múltiples reservas")
        void addReservation_variasReservas_listaCreceCorrectamente() {
            Carver carver = buildValidCarver();

            carver.addReservation(new Reservation());
            carver.addReservation(new Reservation());
            carver.addReservation(new Reservation());

            assertEquals(3, carver.getReservations().size());
        }
    }

    // =========================================================================
    // 9. RELACIÓN BIDIRECCIONAL CON USER (OneToOne)
    // =========================================================================

    @Nested
    @DisplayName("9. Relación con User (OneToOne)")
    class RelacionUser {

        @Test
        @DisplayName("Carver nuevo sin user: user es null")
        void carver_sinUser_userEsNull() {
            Carver carver = new Carver();
            assertNull(carver.getUser());
        }

        @Test
        @DisplayName("Asignar user al carver: referencia queda establecida")
        void setUser_asignaUserCorrectamente() {
            Carver carver = buildValidCarver();
            User user = buildValidUser();

            carver.setUser(user);

            assertEquals(user, carver.getUser());
        }

        @Test
        @DisplayName("La relación User-Carver es bidireccional: user.carver apunta de vuelta")
        void relacion_esBidireccional() {
            User user = buildValidUser();
            Carver carver = buildValidCarver();

            // Establecer ambos lados de la relación (como haría el service layer)
            carver.setUser(user);
            user.setCarver(carver);

            assertAll("La relación debe ser navegable en ambas direcciones",
                    () -> assertEquals(user, carver.getUser()),
                    () -> assertEquals(carver, user.getCarver())
            );
        }

        @Test
        @DisplayName("Desasignar user del carver: user queda null")
        void setUser_null_desasignaUser() {
            Carver carver = buildValidCarver();
            carver.setUser(buildValidUser());

            carver.setUser(null);

            assertNull(carver.getUser());
        }
    }

    // =========================================================================
    // 10. EQUALS Y HASHCODE
    // =========================================================================

    @Nested
    @DisplayName("10. equals() y hashCode()")
    class EqualsHashCode {

        @Test
        @DisplayName("Un Carver es igual a sí mismo (reflexividad)")
        void equals_mismoObjeto_esIgual() {
            Carver carver = buildValidCarver();
            assertEquals(carver, carver);
        }

        @Test
        @DisplayName("Dos Carvers con el mismo id son iguales")
        void equals_mismoId_sonIguales() {
            Carver c1 = buildValidCarver();
            Carver c2 = buildValidCarver();
            c1.setId(1L);
            c2.setId(1L);

            assertEquals(c1, c2);
        }

        @Test
        @DisplayName("Dos Carvers con distinto id no son iguales")
        void equals_diferenteId_noSonIguales() {
            Carver c1 = buildValidCarver();
            Carver c2 = buildValidCarver();
            c1.setId(1L);
            c2.setId(2L);

            assertNotEquals(c1, c2);
        }

        @Test
        @DisplayName("Carver con id null no es igual a otro con id null (sin persistir)")
        void equals_ambosIdNull_noSonIguales() {
            Carver c1 = buildValidCarver();
            Carver c2 = buildValidCarver();

            assertNotEquals(c1, c2,
                    "Dos entidades sin id no deben considerarse iguales");
        }

        @Test
        @DisplayName("Carver no es igual a null")
        void equals_vsNull_noEsIgual() {
            assertNotEquals(null, buildValidCarver());
        }

        @Test
        @DisplayName("Carver no es igual a un objeto de otra clase")
        void equals_otraClase_noEsIgual() {
            assertNotEquals("string", buildValidCarver());
        }

        @Test
        @DisplayName("hashCode es consistente: mismo objeto, mismo hash siempre")
        void hashCode_esConsistente() {
            Carver carver = buildValidCarver();
            assertEquals(carver.hashCode(), carver.hashCode());
        }

        @Test
        @DisplayName("Dos Carvers distintos tienen el mismo hashCode (getClass().hashCode())")
        void hashCode_dosCaversSinId_mismoHash() {
            // La implementación usa getClass().hashCode(), igual que User
            Carver c1 = buildValidCarver();
            Carver c2 = buildValidCarver();
            assertEquals(c1.hashCode(), c2.hashCode());
        }
    }

    // =========================================================================
    // 11. TOSTRING
    // =========================================================================

    @Nested
    @DisplayName("11. toString()")
    class ToStringTest {

        @Test
        @DisplayName("toString() no retorna null")
        void toString_noRetornaNull() {
            assertNotNull(buildValidCarver().toString());
        }

        @Test
        @DisplayName("toString() contiene la especialidad")
        void toString_contieneSpecialty() {
            Carver carver = buildValidCarver();
            assertTrue(carver.toString().contains("Jamón Ibérico"));
        }

        @Test
        @DisplayName("toString() contiene maxHamsPerDay")
        void toString_contieneMaxHamsPerDay() {
            Carver carver = buildValidCarver();
            assertTrue(carver.toString().contains("3"));
        }

        @Test
        @DisplayName("toString() con user asignado muestra userId, no el objeto User completo")
        void toString_conUser_muestraUserIdNoObjetoCompleto() {
            User user = buildValidUser();
            user.setId(7L);
            Carver carver = buildValidCarver();
            carver.setUser(user);

            String result = carver.toString();

            // Debe contener el id del usuario...
            assertTrue(result.contains("7"),
                    "toString debe incluir el userId");
            // ...pero NO volcar el objeto User completo (evitar recursión)
            assertFalse(result.contains("password"),
                    "toString NO debe exponer datos sensibles del User asociado");
        }

        @Test
        @DisplayName("toString() con user null muestra userId=null sin lanzar excepción")
        void toString_sinUser_noLanzaExcepcion() {
            Carver carver = buildValidCarver(); // user es null
            assertDoesNotThrow(() -> carver.toString(),
                    "toString no debe lanzar NullPointerException cuando user es null");
            assertTrue(carver.toString().contains("null"));
        }
    }
}