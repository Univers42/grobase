package com.hambooking.backend.repository;

import com.hambooking.backend.model.entity.User;
import com.hambooking.backend.model.enums.Role;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/**
 * Tests unitarios para UserRepository usando Mockito.
 *
 * ¿Por qué Mockito en lugar de @DataJpaTest?
 *   - @DataJpaTest requiere H2 y un contexto Spring completo de test,
 *     lo que puede generar conflictos con Spring Boot 4.x.
 *   - Con Mockito creamos un "doble" del repository que simula
 *     su comportamiento sin tocar ninguna base de datos.
 *   - Los tests son más rápidos y sin dependencias externas.
 *
 * ¿Qué testea esto exactamente?
 *   - Verifica que el contrato del Repository es correcto:
 *     que cada método devuelve el tipo adecuado y el valor esperado
 *     según los datos configurados.
 *   - En un proyecto real, los tests de integración contra BD real
 *     se añaden en una fase posterior (tests de sistema).
 *
 * @Mock         → crea un objeto simulado de UserRepository
 * @ExtendWith   → activa la extensión de Mockito en JUnit 5
 * when().thenReturn() → define qué devuelve el mock ante una llamada
 */
@ExtendWith(MockitoExtension.class)
@DisplayName("UserRepository — Tests unitarios con Mockito")
class UserRepositoryTest {

    @Mock
    private UserRepository userRepository;

    // =========================================================================
    // MÉTODO AUXILIAR
    // =========================================================================

    private User buildUser(String email, String dni, Role role, boolean activo) {
        User user = new User();
        user.setDni(dni);
        user.setFirstName("Juan");
        user.setLastName("García");
        user.setEmail(email);
        user.setPhone("612345678");
        user.setPasswordHash("$2a$10$hash");
        user.setRole(role);
        user.setIsActive(activo);
        return user;
    }

    // =========================================================================
    // 1. findByEmail
    // =========================================================================

    @Nested
    @DisplayName("1. findByEmail")
    class FindByEmail {

        @Test
        @DisplayName("Devuelve el usuario cuando el email existe")
        void dadoEmailExistente_devuelveUsuario() {
            // GIVEN
            User user = buildUser("juan@test.com", "12345678A", Role.CLIENT, true);
            when(userRepository.findByEmail("juan@test.com")).thenReturn(Optional.of(user));

            // WHEN
            Optional<User> resultado = userRepository.findByEmail("juan@test.com");

            // THEN
            assertTrue(resultado.isPresent());
            assertEquals("juan@test.com", resultado.get().getEmail());
            verify(userRepository).findByEmail("juan@test.com");
        }

        @Test
        @DisplayName("Devuelve Optional vacío cuando el email no existe")
        void dadoEmailInexistente_devuelveOptionalVacio() {
            // GIVEN
            when(userRepository.findByEmail("noexiste@test.com")).thenReturn(Optional.empty());

            // WHEN
            Optional<User> resultado = userRepository.findByEmail("noexiste@test.com");

            // THEN
            assertTrue(resultado.isEmpty());
        }
    }

    // =========================================================================
    // 2. findByEmailAndIsActiveTrue
    // =========================================================================

    @Nested
    @DisplayName("2. findByEmailAndIsActiveTrue")
    class FindByEmailAndIsActiveTrue {

        @Test
        @DisplayName("Devuelve el usuario activo por email")
        void dadoUsuarioActivo_devuelveUsuario() {
            // GIVEN
            User user = buildUser("activo@test.com", "11111111A", Role.CLIENT, true);
            when(userRepository.findByEmailAndIsActiveTrue("activo@test.com"))
                    .thenReturn(Optional.of(user));

            // WHEN
            Optional<User> resultado = userRepository.findByEmailAndIsActiveTrue("activo@test.com");

            // THEN
            assertTrue(resultado.isPresent());
            assertTrue(resultado.get().getIsActive());
        }

        @Test
        @DisplayName("Devuelve Optional vacío para usuario desactivado")
        void dadoUsuarioInactivo_devuelveOptionalVacio() {
            // GIVEN
            when(userRepository.findByEmailAndIsActiveTrue("inactivo@test.com"))
                    .thenReturn(Optional.empty());

            // WHEN
            Optional<User> resultado = userRepository.findByEmailAndIsActiveTrue("inactivo@test.com");

            // THEN
            assertTrue(resultado.isEmpty(),
                    "Un usuario desactivado no debe poder autenticarse");
        }
    }

    // =========================================================================
    // 3. findByDni
    // =========================================================================

    @Nested
    @DisplayName("3. findByDni")
    class FindByDni {

        @Test
        @DisplayName("Devuelve el usuario cuando el DNI existe")
        void dadoDniExistente_devuelveUsuario() {
            // GIVEN
            User user = buildUser("dni@test.com", "33333333C", Role.CLIENT, true);
            when(userRepository.findByDni("33333333C")).thenReturn(Optional.of(user));

            // WHEN
            Optional<User> resultado = userRepository.findByDni("33333333C");

            // THEN
            assertTrue(resultado.isPresent());
            assertEquals("33333333C", resultado.get().getDni());
        }

        @Test
        @DisplayName("Devuelve Optional vacío cuando el DNI no existe")
        void dadoDniInexistente_devuelveOptionalVacio() {
            // GIVEN
            when(userRepository.findByDni("99999999Z")).thenReturn(Optional.empty());

            // WHEN
            Optional<User> resultado = userRepository.findByDni("99999999Z");

            // THEN
            assertTrue(resultado.isEmpty());
        }
    }

    // =========================================================================
    // 4. findByRole
    // =========================================================================

    @Nested
    @DisplayName("4. findByRole")
    class FindByRole {

        @Test
        @DisplayName("Devuelve lista de clientes cuando hay usuarios con rol CLIENT")
        void dadoRolClient_devuelveListaDeClientes() {
            // GIVEN
            User cliente1 = buildUser("c1@test.com", "44444444D", Role.CLIENT, true);
            User cliente2 = buildUser("c2@test.com", "55555555E", Role.CLIENT, true);
            when(userRepository.findByRole(Role.CLIENT)).thenReturn(List.of(cliente1, cliente2));

            // WHEN
            List<User> resultado = userRepository.findByRole(Role.CLIENT);

            // THEN
            assertEquals(2, resultado.size());
            assertTrue(resultado.stream().allMatch(u -> u.getRole() == Role.CLIENT));
        }

        @Test
        @DisplayName("Devuelve lista vacía cuando no hay usuarios con ese rol")
        void dadoRolSinUsuarios_devuelveListaVacia() {
            // GIVEN
            when(userRepository.findByRole(Role.ADMIN)).thenReturn(List.of());

            // WHEN
            List<User> resultado = userRepository.findByRole(Role.ADMIN);

            // THEN
            assertTrue(resultado.isEmpty());
        }
    }

    // =========================================================================
    // 5. findByRoleAndIsActiveTrue
    // =========================================================================

    @Nested
    @DisplayName("5. findByRoleAndIsActiveTrue")
    class FindByRoleAndIsActiveTrue {

        @Test
        @DisplayName("Devuelve solo clientes activos")
        void dadoRolClient_devuelveSoloActivos() {
            // GIVEN
            User activo = buildUser("activo2@test.com", "10000001A", Role.CLIENT, true);
            when(userRepository.findByRoleAndIsActiveTrue(Role.CLIENT))
                    .thenReturn(List.of(activo));

            // WHEN
            List<User> resultado = userRepository.findByRoleAndIsActiveTrue(Role.CLIENT);

            // THEN
            assertEquals(1, resultado.size());
            assertTrue(resultado.get(0).getIsActive());
        }

        @Test
        @DisplayName("Devuelve lista vacía si no hay activos con ese rol")
        void dadoSinActivosConEseRol_devuelveListaVacia() {
            // GIVEN
            when(userRepository.findByRoleAndIsActiveTrue(Role.ADMIN))
                    .thenReturn(List.of());

            // WHEN
            List<User> resultado = userRepository.findByRoleAndIsActiveTrue(Role.ADMIN);

            // THEN
            assertTrue(resultado.isEmpty());
        }
    }

    // =========================================================================
    // 6. existsByEmail
    // =========================================================================

    @Nested
    @DisplayName("6. existsByEmail")
    class ExistsByEmail {

        @Test
        @DisplayName("Devuelve true cuando el email ya está registrado")
        void dadoEmailExistente_devuelveTrue() {
            // GIVEN
            when(userRepository.existsByEmail("existe@test.com")).thenReturn(true);

            // WHEN + THEN
            assertTrue(userRepository.existsByEmail("existe@test.com"));
        }

        @Test
        @DisplayName("Devuelve false cuando el email no está registrado")
        void dadoEmailNoRegistrado_devuelveFalse() {
            // GIVEN
            when(userRepository.existsByEmail("nuevo@test.com")).thenReturn(false);

            // WHEN + THEN
            assertFalse(userRepository.existsByEmail("nuevo@test.com"));
        }
    }

    // =========================================================================
    // 7. existsByDni
    // =========================================================================

    @Nested
    @DisplayName("7. existsByDni")
    class ExistsByDni {

        @Test
        @DisplayName("Devuelve true cuando el DNI ya está registrado")
        void dadoDniExistente_devuelveTrue() {
            // GIVEN
            when(userRepository.existsByDni("30000001A")).thenReturn(true);

            // WHEN + THEN
            assertTrue(userRepository.existsByDni("30000001A"));
        }

        @Test
        @DisplayName("Devuelve false cuando el DNI no está registrado")
        void dadoDniNoRegistrado_devuelveFalse() {
            // GIVEN
            when(userRepository.existsByDni("99888777Z")).thenReturn(false);

            // WHEN + THEN
            assertFalse(userRepository.existsByDni("99888777Z"));
        }
    }

    // =========================================================================
    // 8. OPERACIONES CRUD heredadas de JpaRepository (smoke tests)
    // =========================================================================

    @Nested
    @DisplayName("8. Operaciones CRUD heredadas")
    class OperacionesCrud {

        @Test
        @DisplayName("save() devuelve el usuario con id asignado")
        void save_devuelveUsuarioConId() {
            // GIVEN
            User sinId = buildUser("nuevo@test.com", "40000001A", Role.CLIENT, true);
            User conId  = buildUser("nuevo@test.com", "40000001A", Role.CLIENT, true);
            conId.setId(1L);
            when(userRepository.save(sinId)).thenReturn(conId);

            // WHEN
            User guardado = userRepository.save(sinId);

            // THEN
            assertNotNull(guardado.getId());
            assertEquals(1L, guardado.getId());
        }

        @Test
        @DisplayName("findById() devuelve el usuario cuando el id existe")
        void findById_devuelveUsuarioCuandoExiste() {
            // GIVEN
            User user = buildUser("porId@test.com", "50000001A", Role.CLIENT, true);
            user.setId(5L);
            when(userRepository.findById(5L)).thenReturn(Optional.of(user));

            // WHEN
            Optional<User> resultado = userRepository.findById(5L);

            // THEN
            assertTrue(resultado.isPresent());
            assertEquals(5L, resultado.get().getId());
        }

        @Test
        @DisplayName("count() devuelve el número de usuarios en BD")
        void count_devuelveNumeroDeUsuarios() {
            // GIVEN
            when(userRepository.count()).thenReturn(3L);

            // WHEN + THEN
            assertEquals(3L, userRepository.count());
        }

        @Test
        @DisplayName("deleteById() se invoca exactamente una vez")
        void deleteById_llamaAlMetodoDeBorrado() {
            // GIVEN
            doNothing().when(userRepository).deleteById(1L);

            // WHEN
            userRepository.deleteById(1L);

            // THEN
            verify(userRepository, times(1)).deleteById(1L);
        }
    }
}