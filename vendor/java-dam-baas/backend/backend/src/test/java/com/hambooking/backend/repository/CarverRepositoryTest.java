package com.hambooking.backend.repository;

import com.hambooking.backend.model.entity.Carver;
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
 * Tests unitarios para CarverRepository usando Mockito.
 *
 * CarverRepository tiene una característica especial respecto a
 * UserRepository: sus métodos más importantes reciben un objeto
 * User como parámetro (findByUser, existsByUser), porque la
 * relación principal de Carver es la FK hacia User.
 *
 * Esto ejercita un tipo de query method distinto al de UserRepository:
 * en lugar de filtrar por un campo primitivo (String, Boolean),
 * filtramos por una entidad completa — Spring Data traduce esto
 * automáticamente a WHERE user_id = ?.
 */
@ExtendWith(MockitoExtension.class)
@DisplayName("CarverRepository — Tests unitarios con Mockito")
class CarverRepositoryTest {

    @Mock
    private CarverRepository carverRepository;

    // =========================================================================
    // MÉTODOS AUXILIARES
    // =========================================================================

    private User buildUser(String email) {
        User user = new User();
        user.setId(1L);
        user.setDni("12345678A");
        user.setFirstName("Juan");
        user.setLastName("García");
        user.setEmail(email);
        user.setPhone("612345678");
        user.setPasswordHash("$2a$10$hash");
        user.setRole(Role.CLIENT);
        user.setIsActive(true);
        return user;
    }

    private Carver buildCarver(User user, String specialty, boolean activo) {
        Carver carver = new Carver();
        carver.setId(1L);
        carver.setUser(user);
        carver.setSpecialty(specialty);
        carver.setExperienceYears(5);
        carver.setMaxHamsPerDay(3);
        carver.setIsActive(activo);
        return carver;
    }

    // =========================================================================
    // 1. findByUser
    // =========================================================================

    @Nested
    @DisplayName("1. findByUser")
    class FindByUser {

        @Test
        @DisplayName("Devuelve el Carver cuando el User tiene perfil de cortador")
        void dadoUserConCarver_devuelveCarver() {
            // GIVEN
            User user = buildUser("cortador@test.com");
            Carver carver = buildCarver(user, "Jamón", true);
            when(carverRepository.findByUser(user)).thenReturn(Optional.of(carver));

            // WHEN
            Optional<Carver> resultado = carverRepository.findByUser(user);

            // THEN
            assertTrue(resultado.isPresent());
            assertEquals(user, resultado.get().getUser());
            assertEquals("Jamón", resultado.get().getSpecialty());
            verify(carverRepository).findByUser(user);
        }

        @Test
        @DisplayName("Devuelve Optional vacío cuando el User no tiene perfil de cortador")
        void dadoUserSinCarver_devuelveOptionalVacio() {
            // GIVEN — usuario normal sin perfil de cortador
            User user = buildUser("cliente@test.com");
            when(carverRepository.findByUser(user)).thenReturn(Optional.empty());

            // WHEN
            Optional<Carver> resultado = carverRepository.findByUser(user);

            // THEN
            assertTrue(resultado.isEmpty(),
                    "Un usuario sin perfil de cortador no debe devolver ningún Carver");
        }
    }

    // =========================================================================
    // 2. existsByUser
    // =========================================================================

    @Nested
    @DisplayName("2. existsByUser")
    class ExistsByUser {

        @Test
        @DisplayName("Devuelve true cuando el User ya tiene perfil de cortador")
        void dadoUserConCarver_devuelveTrue() {
            // GIVEN
            User user = buildUser("cortador2@test.com");
            when(carverRepository.existsByUser(user)).thenReturn(true);

            // WHEN + THEN
            assertTrue(carverRepository.existsByUser(user));
        }

        @Test
        @DisplayName("Devuelve false cuando el User no tiene perfil de cortador")
        void dadoUserSinCarver_devuelveFalse() {
            // GIVEN
            User user = buildUser("cliente2@test.com");
            when(carverRepository.existsByUser(user)).thenReturn(false);

            // WHEN + THEN
            assertFalse(carverRepository.existsByUser(user),
                    "Un usuario sin perfil de cortador debe devolver false");
        }
    }

    // =========================================================================
    // 3. findByIsActiveTrue
    // =========================================================================

    @Nested
    @DisplayName("3. findByIsActiveTrue")
    class FindByIsActiveTrue {

        @Test
        @DisplayName("Devuelve solo los cortadores activos")
        void hayActivosEInactivos_devuelveSoloActivos() {
            // GIVEN — el mock solo devuelve el activo (simula el filtro WHERE is_active = true)
            User u1 = buildUser("activo@test.com");
            Carver activo = buildCarver(u1, "Jamón", true);
            when(carverRepository.findByIsActiveTrue()).thenReturn(List.of(activo));

            // WHEN
            List<Carver> resultado = carverRepository.findByIsActiveTrue();

            // THEN
            assertEquals(1, resultado.size());
            assertTrue(resultado.get(0).getIsActive());
        }

        @Test
        @DisplayName("Devuelve lista vacía cuando no hay cortadores activos")
        void noHayActivos_devuelveListaVacia() {
            // GIVEN
            when(carverRepository.findByIsActiveTrue()).thenReturn(List.of());

            // WHEN
            List<Carver> resultado = carverRepository.findByIsActiveTrue();

            // THEN
            assertTrue(resultado.isEmpty());
        }
    }

    // =========================================================================
    // 4. findByIsActive
    // =========================================================================

    @Nested
    @DisplayName("4. findByIsActive")
    class FindByIsActive {

        @Test
        @DisplayName("Con true devuelve cortadores activos")
        void dadoTrue_devuelveActivos() {
            // GIVEN
            User u1 = buildUser("a1@test.com");
            User u2 = buildUser("a2@test.com");
            Carver c1 = buildCarver(u1, "Paleta", true);
            Carver c2 = buildCarver(u2, "Todos", true);
            when(carverRepository.findByIsActive(true)).thenReturn(List.of(c1, c2));

            // WHEN
            List<Carver> resultado = carverRepository.findByIsActive(true);

            // THEN
            assertEquals(2, resultado.size());
            assertTrue(resultado.stream().allMatch(Carver::getIsActive));
        }

        @Test
        @DisplayName("Con false devuelve cortadores inactivos")
        void dadoFalse_devuelveInactivos() {
            // GIVEN
            User u1 = buildUser("inactivo@test.com");
            Carver inactivo = buildCarver(u1, "Embutidos", false);
            when(carverRepository.findByIsActive(false)).thenReturn(List.of(inactivo));

            // WHEN
            List<Carver> resultado = carverRepository.findByIsActive(false);

            // THEN
            assertEquals(1, resultado.size());
            assertFalse(resultado.get(0).getIsActive());
        }
    }

    // =========================================================================
    // 5. findBySpecialty
    // =========================================================================

    @Nested
    @DisplayName("5. findBySpecialty")
    class FindBySpecialty {

        @Test
        @DisplayName("Devuelve los cortadores de una especialidad concreta")
        void dadoEspecialidadExistente_devuelveCortadores() {
            // GIVEN
            User u1 = buildUser("jamon1@test.com");
            User u2 = buildUser("jamon2@test.com");
            Carver c1 = buildCarver(u1, "Jamón", true);
            Carver c2 = buildCarver(u2, "Jamón", true);
            when(carverRepository.findBySpecialty("Jamón")).thenReturn(List.of(c1, c2));

            // WHEN
            List<Carver> resultado = carverRepository.findBySpecialty("Jamón");

            // THEN
            assertEquals(2, resultado.size());
            assertTrue(resultado.stream().allMatch(c -> "Jamón".equals(c.getSpecialty())));
        }

        @Test
        @DisplayName("Devuelve lista vacía cuando no hay cortadores con esa especialidad")
        void dadoEspecialidadSinCortadores_devuelveListaVacia() {
            // GIVEN
            when(carverRepository.findBySpecialty("Embutidos")).thenReturn(List.of());

            // WHEN
            List<Carver> resultado = carverRepository.findBySpecialty("Embutidos");

            // THEN
            assertTrue(resultado.isEmpty());
        }
    }

    // =========================================================================
    // 6. findBySpecialtyAndIsActiveTrue
    // =========================================================================

    @Nested
    @DisplayName("6. findBySpecialtyAndIsActiveTrue")
    class FindBySpecialtyAndIsActiveTrue {

        @Test
        @DisplayName("Devuelve solo cortadores activos de esa especialidad")
        void dadoEspecialidad_devuelveSoloActivos() {
            // GIVEN — hay un activo y un inactivo de "Paleta", el mock solo devuelve el activo
            User u1 = buildUser("paleta.activo@test.com");
            Carver activo = buildCarver(u1, "Paleta", true);
            when(carverRepository.findBySpecialtyAndIsActiveTrue("Paleta"))
                    .thenReturn(List.of(activo));

            // WHEN
            List<Carver> resultado = carverRepository.findBySpecialtyAndIsActiveTrue("Paleta");

            // THEN
            assertEquals(1, resultado.size());
            assertEquals("Paleta", resultado.get(0).getSpecialty());
            assertTrue(resultado.get(0).getIsActive());
        }

        @Test
        @DisplayName("Devuelve lista vacía si no hay activos con esa especialidad")
        void sinActivosConEsaEspecialidad_devuelveListaVacia() {
            // GIVEN
            when(carverRepository.findBySpecialtyAndIsActiveTrue("Jamón"))
                    .thenReturn(List.of());

            // WHEN
            List<Carver> resultado = carverRepository.findBySpecialtyAndIsActiveTrue("Jamón");

            // THEN
            assertTrue(resultado.isEmpty());
        }
    }

    // =========================================================================
    // 7. OPERACIONES CRUD heredadas de JpaRepository (smoke tests)
    // =========================================================================

    @Nested
    @DisplayName("7. Operaciones CRUD heredadas")
    class OperacionesCrud {

        @Test
        @DisplayName("save() devuelve el Carver con id asignado")
        void save_devuelveCarverConId() {
            // GIVEN
            User user = buildUser("nuevo.cortador@test.com");
            Carver sinId = buildCarver(user, "Todos", true);
            sinId.setId(null);
            Carver conId = buildCarver(user, "Todos", true);
            conId.setId(10L);
            when(carverRepository.save(sinId)).thenReturn(conId);

            // WHEN
            Carver guardado = carverRepository.save(sinId);

            // THEN
            assertNotNull(guardado.getId());
            assertEquals(10L, guardado.getId());
        }

        @Test
        @DisplayName("findById() devuelve el Carver cuando el id existe")
        void findById_devuelveCarverCuandoExiste() {
            // GIVEN
            User user = buildUser("porId@test.com");
            Carver carver = buildCarver(user, "Jamón", true);
            carver.setId(7L);
            when(carverRepository.findById(7L)).thenReturn(Optional.of(carver));

            // WHEN
            Optional<Carver> resultado = carverRepository.findById(7L);

            // THEN
            assertTrue(resultado.isPresent());
            assertEquals(7L, resultado.get().getId());
        }

        @Test
        @DisplayName("deleteById() se invoca exactamente una vez")
        void deleteById_seInvocaUnaVez() {
            // GIVEN
            doNothing().when(carverRepository).deleteById(1L);

            // WHEN
            carverRepository.deleteById(1L);

            // THEN
            verify(carverRepository, times(1)).deleteById(1L);
        }

        @Test
        @DisplayName("count() devuelve el número de cortadores registrados")
        void count_devuelveNumeroDeCortadores() {
            // GIVEN
            when(carverRepository.count()).thenReturn(4L);

            // WHEN + THEN
            assertEquals(4L, carverRepository.count());
        }
    }
}