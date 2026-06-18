package com.hambooking.backend.repository;

import com.hambooking.backend.model.entity.Carver;
import com.hambooking.backend.model.entity.User;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.Optional;

/**
 * Repositorio para la gestión de persistencia de la entidad {@link Carver}.
 * Gestiona los perfiles profesionales de los cortadores vinculados a los usuarios.
 */
@Repository
public interface CarverRepository extends JpaRepository<Carver, Long> {

    /**
     * Localiza el perfil de cortador asociado a un usuario específico.
     * @param user El usuario vinculado al perfil profesional.
     * @return Un Optional con el Carver si existe.
     */
    Optional<Carver> findByUser(User user);

    /**
     * Comprueba si un usuario ya dispone de un perfil de cortador registrado.
     * @param user El usuario a verificar.
     * @return true si el usuario ya es cortador.
     */
    boolean existsByUser(User user);

    /**
     * Obtiene el listado de todos los cortadores habilitados para recibir reservas.
     * @return Lista de cortadores activos.
     */
    List<Carver> findByIsActiveTrue();

    /**
     * Obtiene cortadores filtrados por su estado de actividad.
     * @param isActive Estado de actividad a filtrar.
     * @return Lista de cortadores con el estado especificado.
     */
    List<Carver> findByIsActive(Boolean isActive);

    /**
     * Recupera cortadores que poseen una especialidad técnica concreta.
     * @param specialty Especialidad a buscar (ej. Jamón, Paleta).
     * @return Lista de cortadores especializados.
     */
    List<Carver> findBySpecialty(String specialty);

    /**
     * Recupera cortadores activos filtrados por una especialidad técnica.
     * @param specialty Especialidad a filtrar.
     * @return Lista de cortadores activos y especializados.
     */
    List<Carver> findBySpecialtyAndIsActiveTrue(String specialty);
}
