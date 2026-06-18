package com.hambooking.backend.repository;

import com.hambooking.backend.model.entity.Service;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;

/**
 * Repositorio para la gestión de persistencia de la entidad {@link Service}.
 * Administra el catálogo de servicios de corte disponibles en la plataforma.
 */
@Repository
public interface ServiceRepository extends JpaRepository<Service, Long> {

    /**
     * Localiza un servicio mediante su nombre descriptivo exacto.
     * @param name Nombre del servicio.
     * @return Un Optional con el servicio si se encuentra.
     */
    Optional<Service> findByName(String name);

    /**
     * Verifica si ya existe un servicio registrado con un nombre determinado.
     * @param name Nombre a comprobar.
     * @return true si el nombre ya está en uso.
     */
    boolean existsByName(String name);

    /**
     * Obtiene todos los servicios habilitados actualmente en el catálogo.
     * @return Lista de servicios activos.
     */
    List<Service> findByIsActiveTrue();

    /**
     * Recupera el catálogo de servicios filtrado por su estado de actividad.
     * @param isActive true para activos, false para inactivos.
     * @return Lista de servicios con el estado especificado.
     */
    List<Service> findByIsActive(Boolean isActive);

    /**
     * Obtiene servicios cuyo precio base es inferior o igual a un importe máximo.
     * @param maxPrice Precio máximo permitido.
     * @return Lista de servicios dentro del rango de precio.
     */
    List<Service> findByBasePriceLessThanEqual(BigDecimal maxPrice);

    /**
     * Obtiene servicios activos con un precio inferior o igual a un importe máximo.
     * @param maxPrice Precio máximo permitido.
     * @return Lista de servicios activos dentro del presupuesto.
     */
    List<Service> findByBasePriceLessThanEqualAndIsActiveTrue(BigDecimal maxPrice);
}
