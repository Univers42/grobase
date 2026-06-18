package com.hambooking.backend.repository;

import com.hambooking.backend.model.entity.User;
import com.hambooking.backend.model.enums.Role;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.Optional;

/**
 * Repositorio para la gestión de persistencia de la entidad {@link User}.
 * Proporciona métodos para la autenticación, registro y administración de usuarios.
 */
@Repository
public interface UserRepository extends JpaRepository<User, Long> {

    /**
     * Recupera un usuario basándose en su dirección de correo electrónico.
     * @param email Correo electrónico del usuario.
     * @return Un Optional que contiene el usuario si se encuentra.
     */
    Optional<User> findByEmail(String email);

    /**
     * Recupera un usuario por email únicamente si su cuenta está habilitada.
     * @param email Correo electrónico del usuario.
     * @return Un Optional con el usuario activo si existe.
     */
    Optional<User> findByEmailAndIsActiveTrue(String email);

    /**
     * Localiza un usuario mediante su número de DNI.
     * @param dni Documento Nacional de Identidad.
     * @return Un Optional con el usuario si se encuentra.
     */
    Optional<User> findByDni(String dni);

    /**
     * Obtiene un listado de usuarios filtrado por su rol en el sistema.
     * @param role Rol a filtrar (ADMIN o CLIENT).
     * @return Lista de usuarios con el rol especificado.
     */
    List<User> findByRole(Role role);

    /**
     * Obtiene un listado de usuarios activos que poseen un rol determinado.
     * @param role Rol a filtrar.
     * @return Lista de usuarios activos con el rol especificado.
     */
    List<User> findByRoleAndIsActiveTrue(Role role);

    /**
     * Verifica la existencia de un usuario con un email específico.
     * @param email Correo a comprobar.
     * @return true si el email ya está registrado.
     */
    boolean existsByEmail(String email);

    /**
     * Verifica la existencia de un usuario con un DNI específico.
     * @param dni DNI a comprobar.
     * @return true si el DNI ya está registrado.
     */
    boolean existsByDni(String dni);
}
