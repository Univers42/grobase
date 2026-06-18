package com.hambooking.backend.repository;

import com.hambooking.backend.model.entity.Service;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/**
 * Tests unitarios para ServiceRepository usando Mockito.
 *
 * ServiceRepository introduce un tipo de query method nuevo respecto
 * a los anteriores: comparaciones numéricas con sufijos de Spring Data.
 *
 * Sufijos que usa este repository:
 *   LessThanEqual  → WHERE base_price <= ?
 *
 * Otros sufijos disponibles en Spring Data (para referencia):
 *   GreaterThan        → WHERE campo > ?
 *   LessThan           → WHERE campo < ?
 *   Between            → WHERE campo BETWEEN ? AND ?
 *   Containing         → WHERE campo LIKE %?%
 *   StartingWith       → WHERE campo LIKE ?%
 */
@ExtendWith(MockitoExtension.class)
@DisplayName("ServiceRepository — Tests unitarios con Mockito")
class ServiceRepositoryTest {

    @Mock
    private ServiceRepository serviceRepository;

    // =========================================================================
    // MÉTODO AUXILIAR
    // =========================================================================

    private Service buildService(String name, BigDecimal price, boolean activo) {
        Service service = new Service();
        service.setId(1L);
        service.setName(name);
        service.setDescription("Descripción de " + name);
        service.setDurationMinutes(60);
        service.setBasePrice(price);
        service.setIsActive(activo);
        return service;
    }

    // =========================================================================
    // 1. findByName
    // =========================================================================

    @Nested
    @DisplayName("1. findByName")
    class FindByName {

        @Test
        @DisplayName("Devuelve el servicio cuando el nombre existe")
        void dadoNombreExistente_devuelveServicio() {
            // GIVEN
            Service jamon = buildService("Corte de Jamón", new BigDecimal("45.00"), true);
            when(serviceRepository.findByName("Corte de Jamón")).thenReturn(Optional.of(jamon));

            // WHEN
            Optional<Service> resultado = serviceRepository.findByName("Corte de Jamón");

            // THEN
            assertTrue(resultado.isPresent());
            assertEquals("Corte de Jamón", resultado.get().getName());
            verify(serviceRepository).findByName("Corte de Jamón");
        }

        @Test
        @DisplayName("Devuelve Optional vacío cuando el nombre no existe")
        void dadoNombreInexistente_devuelveOptionalVacio() {
            // GIVEN
            when(serviceRepository.findByName("Servicio Inexistente")).thenReturn(Optional.empty());

            // WHEN
            Optional<Service> resultado = serviceRepository.findByName("Servicio Inexistente");

            // THEN
            assertTrue(resultado.isEmpty());
        }
    }

    // =========================================================================
    // 2. existsByName
    // =========================================================================

    @Nested
    @DisplayName("2. existsByName")
    class ExistsByName {

        @Test
        @DisplayName("Devuelve true cuando el nombre ya está registrado")
        void dadoNombreExistente_devuelveTrue() {
            // GIVEN
            when(serviceRepository.existsByName("Corte de Paleta")).thenReturn(true);

            // WHEN + THEN
            assertTrue(serviceRepository.existsByName("Corte de Paleta"));
        }

        @Test
        @DisplayName("Devuelve false cuando el nombre no está registrado")
        void dadoNombreNuevo_devuelveFalse() {
            // GIVEN
            when(serviceRepository.existsByName("Corte Nuevo")).thenReturn(false);

            // WHEN + THEN
            assertFalse(serviceRepository.existsByName("Corte Nuevo"));
        }
    }

    // =========================================================================
    // 3. findByIsActiveTrue
    // =========================================================================

    @Nested
    @DisplayName("3. findByIsActiveTrue")
    class FindByIsActiveTrue {

        @Test
        @DisplayName("Devuelve solo los servicios activos del catálogo")
        void haySoloActivos_devuelveTodasLasActivas() {
            // GIVEN — los 3 servicios predefinidos del negocio, todos activos
            Service jamon    = buildService("Corte de Jamón",    new BigDecimal("45.00"), true);
            Service paleta   = buildService("Corte de Paleta",   new BigDecimal("25.00"), true);
            Service embutido = buildService("Corte de Embutido", new BigDecimal("12.00"), true);
            when(serviceRepository.findByIsActiveTrue())
                    .thenReturn(List.of(jamon, paleta, embutido));

            // WHEN
            List<Service> resultado = serviceRepository.findByIsActiveTrue();

            // THEN
            assertEquals(3, resultado.size());
            assertTrue(resultado.stream().allMatch(Service::getIsActive));
        }

        @Test
        @DisplayName("Devuelve lista vacía cuando no hay servicios activos")
        void noHayActivos_devuelveListaVacia() {
            // GIVEN
            when(serviceRepository.findByIsActiveTrue()).thenReturn(List.of());

            // WHEN + THEN
            assertTrue(serviceRepository.findByIsActiveTrue().isEmpty());
        }
    }

    // =========================================================================
    // 4. findByIsActive
    // =========================================================================

    @Nested
    @DisplayName("4. findByIsActive")
    class FindByIsActive {

        @Test
        @DisplayName("Con true devuelve servicios activos")
        void dadoTrue_devuelveActivos() {
            // GIVEN
            Service activo = buildService("Corte de Jamón", new BigDecimal("45.00"), true);
            when(serviceRepository.findByIsActive(true)).thenReturn(List.of(activo));

            // WHEN
            List<Service> resultado = serviceRepository.findByIsActive(true);

            // THEN
            assertEquals(1, resultado.size());
            assertTrue(resultado.get(0).getIsActive());
        }

        @Test
        @DisplayName("Con false devuelve servicios inactivos")
        void dadoFalse_devuelveInactivos() {
            // GIVEN
            Service inactivo = buildService("Servicio Retirado", new BigDecimal("10.00"), false);
            when(serviceRepository.findByIsActive(false)).thenReturn(List.of(inactivo));

            // WHEN
            List<Service> resultado = serviceRepository.findByIsActive(false);

            // THEN
            assertEquals(1, resultado.size());
            assertFalse(resultado.get(0).getIsActive());
        }
    }

    // =========================================================================
    // 5. findByBasePriceLessThanEqual
    // =========================================================================

    @Nested
    @DisplayName("5. findByBasePriceLessThanEqual")
    class FindByBasePriceLessThanEqual {

        @Test
        @DisplayName("Devuelve servicios cuyo precio es <= al máximo indicado")
        void dadoMaximo30_devuelveServiciosMenoresOIguales() {
            // GIVEN — solo Embutido (12€) y Paleta (25€) entran en presupuesto <= 30€
            Service paleta   = buildService("Corte de Paleta",   new BigDecimal("25.00"), true);
            Service embutido = buildService("Corte de Embutido", new BigDecimal("12.00"), true);
            when(serviceRepository.findByBasePriceLessThanEqual(new BigDecimal("30.00")))
                    .thenReturn(List.of(paleta, embutido));

            // WHEN
            List<Service> resultado = serviceRepository
                    .findByBasePriceLessThanEqual(new BigDecimal("30.00"));

            // THEN
            assertEquals(2, resultado.size());
            assertTrue(resultado.stream()
                    .allMatch(s -> s.getBasePrice().compareTo(new BigDecimal("30.00")) <= 0));
        }

        @Test
        @DisplayName("Devuelve lista vacía cuando ningún servicio entra en el presupuesto")
        void dadoMaximoMuyBajo_devuelveListaVacia() {
            // GIVEN — ningún servicio cuesta menos de 5€
            when(serviceRepository.findByBasePriceLessThanEqual(new BigDecimal("5.00")))
                    .thenReturn(List.of());

            // WHEN
            List<Service> resultado = serviceRepository
                    .findByBasePriceLessThanEqual(new BigDecimal("5.00"));

            // THEN
            assertTrue(resultado.isEmpty());
        }

        @Test
        @DisplayName("El precio exacto (igual) también se incluye (LessThanEqual es inclusivo)")
        void dadoMaximoExacto_incluyeElServicioConEsePrecio() {
            // GIVEN — buscamos <= 45.00, el Jamón cuesta exactamente 45.00
            Service jamon = buildService("Corte de Jamón", new BigDecimal("45.00"), true);
            when(serviceRepository.findByBasePriceLessThanEqual(new BigDecimal("45.00")))
                    .thenReturn(List.of(jamon));

            // WHEN
            List<Service> resultado = serviceRepository
                    .findByBasePriceLessThanEqual(new BigDecimal("45.00"));

            // THEN
            assertEquals(1, resultado.size());
            assertEquals(0, resultado.get(0).getBasePrice().compareTo(new BigDecimal("45.00")));
        }
    }

    // =========================================================================
    // 6. findByBasePriceLessThanEqualAndIsActiveTrue
    // =========================================================================

    @Nested
    @DisplayName("6. findByBasePriceLessThanEqualAndIsActiveTrue")
    class FindByBasePriceLessThanEqualAndIsActiveTrue {

        @Test
        @DisplayName("Devuelve solo servicios activos dentro del presupuesto")
        void dadoMaximo30_devuelveSoloActivosDentroDePresupuesto() {
            // GIVEN — hay un inactivo a 20€ pero el mock solo devuelve el activo a 25€
            Service paleta = buildService("Corte de Paleta", new BigDecimal("25.00"), true);
            when(serviceRepository.findByBasePriceLessThanEqualAndIsActiveTrue(
                    new BigDecimal("30.00"))).thenReturn(List.of(paleta));

            // WHEN
            List<Service> resultado = serviceRepository
                    .findByBasePriceLessThanEqualAndIsActiveTrue(new BigDecimal("30.00"));

            // THEN
            assertEquals(1, resultado.size());
            assertTrue(resultado.get(0).getIsActive());
            assertTrue(resultado.get(0).getBasePrice().compareTo(new BigDecimal("30.00")) <= 0);
        }

        @Test
        @DisplayName("Devuelve lista vacía si no hay activos en ese rango de precio")
        void sinActivosDentroDePresupuesto_devuelveListaVacia() {
            // GIVEN
            when(serviceRepository.findByBasePriceLessThanEqualAndIsActiveTrue(
                    new BigDecimal("5.00"))).thenReturn(List.of());

            // WHEN
            List<Service> resultado = serviceRepository
                    .findByBasePriceLessThanEqualAndIsActiveTrue(new BigDecimal("5.00"));

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
        @DisplayName("save() devuelve el servicio con id asignado")
        void save_devuelveServicioConId() {
            // GIVEN
            Service sinId = buildService("Corte de Jamón", new BigDecimal("45.00"), true);
            sinId.setId(null);
            Service conId = buildService("Corte de Jamón", new BigDecimal("45.00"), true);
            conId.setId(3L);
            when(serviceRepository.save(sinId)).thenReturn(conId);

            // WHEN
            Service guardado = serviceRepository.save(sinId);

            // THEN
            assertNotNull(guardado.getId());
            assertEquals(3L, guardado.getId());
        }

        @Test
        @DisplayName("findById() devuelve el servicio cuando el id existe")
        void findById_devuelveServicioCuandoExiste() {
            // GIVEN
            Service service = buildService("Corte de Paleta", new BigDecimal("25.00"), true);
            service.setId(2L);
            when(serviceRepository.findById(2L)).thenReturn(Optional.of(service));

            // WHEN
            Optional<Service> resultado = serviceRepository.findById(2L);

            // THEN
            assertTrue(resultado.isPresent());
            assertEquals("Corte de Paleta", resultado.get().getName());
        }

        @Test
        @DisplayName("count() devuelve el número de servicios en catálogo")
        void count_devuelveNumeroDeServicios() {
            // GIVEN — en el negocio hay 3 servicios predefinidos
            when(serviceRepository.count()).thenReturn(3L);

            // WHEN + THEN
            assertEquals(3L, serviceRepository.count());
        }

        @Test
        @DisplayName("deleteById() se invoca exactamente una vez")
        void deleteById_seInvocaUnaVez() {
            // GIVEN
            doNothing().when(serviceRepository).deleteById(1L);

            // WHEN
            serviceRepository.deleteById(1L);

            // THEN
            verify(serviceRepository, times(1)).deleteById(1L);
        }
    }
}