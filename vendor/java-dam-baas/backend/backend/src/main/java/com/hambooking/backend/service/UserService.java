package com.hambooking.backend.service;

import com.hambooking.backend.dto.user.UserResponseDTO;
import com.hambooking.backend.exception.BusinessRuleException;
import com.hambooking.backend.exception.ResourceNotFoundException;
import com.hambooking.backend.model.entity.User;
import com.hambooking.backend.repository.UserRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.stream.Collectors;

/**
 * Servicio responsable de la gestión de usuarios del sistema.
 * Contiene la lógica para consultar usuarios, modificar su estado de activación
 * y gestionar el cambio de contraseñas.
 */
@Service
@RequiredArgsConstructor
public class UserService {

    /** Repositorio para la gestión de usuarios en base de datos. */
    private final UserRepository userRepository;
    
    /** Codificador de contraseñas para verificar y encriptar nuevas contraseñas. */
    private final BCryptPasswordEncoder passwordEncoder;

    /**
     * Obtiene la lista completa de todos los usuarios registrados en el sistema.
     *
     * @return Lista de DTOs con la información básica de todos los usuarios.
     */
    @Transactional(readOnly = true)
    public List<UserResponseDTO> listAllUsers() {
        return userRepository.findAll().stream()
                .map(this::toDTO).collect(Collectors.toList());
    }

    /**
     * Busca y retorna la información de un usuario específico por su identificador.
     *
     * @param id Identificador único del usuario.
     * @return DTO con la información del usuario encontrado.
     * @throws ResourceNotFoundException Si no existe ningún usuario con ese ID.
     */
    @Transactional(readOnly = true)
    public UserResponseDTO getUserById(Long id) {
        return userRepository.findById(id).map(this::toDTO)
                .orElseThrow(() -> new ResourceNotFoundException("Usuario no encontrado"));
    }

    /**
     * Modifica el estado de activación de un usuario.
     *
     * @param id Identificador único del usuario.
     * @param active Nuevo estado (true para activar, false para desactivar).
     * @throws ResourceNotFoundException Si el usuario no existe.
     */
    @Transactional
    public void setUserActive(Long id, boolean active) {
        User user = userRepository.findById(id)
                .orElseThrow(() -> new ResourceNotFoundException("Usuario no encontrado"));
        user.setIsActive(active);
        userRepository.save(user);
    }

    /**
     * Permite a un usuario cambiar su contraseña validando previamente la actual.
     *
     * @param id Identificador del usuario que desea cambiar su contraseña.
     * @param currentPassword Contraseña actual sin encriptar ingresada por el usuario.
     * @param newPassword Nueva contraseña sin encriptar que desea establecer.
     * @throws ResourceNotFoundException Si el usuario no existe.
     * @throws BusinessRuleException Si la contraseña actual no coincide con la registrada.
     */
    @Transactional
    public void changePassword(Long id, String currentPassword, String newPassword) {
        User user = userRepository.findById(id)
                .orElseThrow(() -> new ResourceNotFoundException("Usuario no encontrado"));

        if (!passwordEncoder.matches(currentPassword, user.getPasswordHash())) {
            throw new BusinessRuleException("La contraseña actual no es correcta");
        }

        user.setPasswordHash(passwordEncoder.encode(newPassword));
        userRepository.save(user);
    }

    /**
     * Convierte una entidad User en su respectivo DTO de respuesta.
     *
     * @param u Entidad User a convertir.
     * @return DTO con los datos públicos del usuario.
     */
    private UserResponseDTO toDTO(User u) {
        return new UserResponseDTO(u.getId(), u.getDni(), u.getFirstName(),
                u.getLastName(), u.getEmail(), u.getPhone(), u.getRole(), u.getIsActive());
    }
}
