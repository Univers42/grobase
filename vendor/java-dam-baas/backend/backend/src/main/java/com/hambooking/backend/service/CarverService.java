package com.hambooking.backend.service;

import com.hambooking.backend.dto.carver.CarverDTO;
import com.hambooking.backend.exception.BusinessRuleException;
import com.hambooking.backend.exception.ResourceNotFoundException;
import com.hambooking.backend.model.entity.Carver;
import com.hambooking.backend.model.entity.User;
import com.hambooking.backend.repository.CarverRepository;
import com.hambooking.backend.repository.UserRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.stream.Collectors;

/**
 * Servicio encargado de la gestión de cortadores.
 * Implementa la lógica para crear, actualizar, listar y modificar el estado de los cortadores de jamón.
 */
@Service
@RequiredArgsConstructor
public class CarverService {

    /** Repositorio de cortadores para operaciones de persistencia. */
    private final CarverRepository carverRepository;
    
    /** Repositorio de usuarios para validar existencias al asociar perfiles. */
    private final UserRepository userRepository;

    /**
     * Crea un nuevo cortador asociado a un usuario existente.
     *
     * @param request DTO con la información del cortador a crear.
     * @return DTO con los datos del cortador guardado.
     * @throws ResourceNotFoundException Si el usuario referenciado no existe.
     * @throws BusinessRuleException Si el usuario ya posee un perfil de cortador.
     */
    @Transactional
    public CarverDTO createCarver(CarverDTO request) {

        User user = userRepository.findById(request.getUserId())
                .orElseThrow(() -> new ResourceNotFoundException("Usuario no encontrado"));

        if (carverRepository.existsByUser(user)) {
            throw new BusinessRuleException("Este usuario ya tiene perfil de cortador");
        }

        Carver carver = new Carver();
        carver.setUser(user);
        carver.setSpecialty(request.getSpecialty());
        carver.setExperienceYears(
                request.getExperienceYears() != null ? request.getExperienceYears() : 0);
        carver.setMaxHamsPerDay(request.getMaxHamsPerDay());
        carver.setIsActive(true);

        return toDTO(carverRepository.save(carver));
    }

    /**
     * Actualiza la información de un cortador existente.
     *
     * @param id Identificador único del cortador.
     * @param request DTO con los datos actualizados.
     * @return DTO con la información del cortador tras la actualización.
     * @throws ResourceNotFoundException Si el cortador no existe.
     */
    @Transactional
    public CarverDTO updateCarver(Long id, CarverDTO request) {

        Carver carver = carverRepository.findById(id)
                .orElseThrow(() -> new ResourceNotFoundException("Cortador no encontrado"));

        if (request.getSpecialty() != null) {
            carver.setSpecialty(request.getSpecialty());
        }
        if (request.getExperienceYears() != null) {
            carver.setExperienceYears(request.getExperienceYears());
        }
        if (request.getMaxHamsPerDay() != null) {
            carver.setMaxHamsPerDay(request.getMaxHamsPerDay());
        }

        return toDTO(carverRepository.save(carver));
    }

    /**
     * Modifica el estado de activación de un cortador.
     *
     * @param id Identificador del cortador.
     * @param active Nuevo estado de activación.
     * @throws ResourceNotFoundException Si el cortador no se encuentra.
     * @throws BusinessRuleException Si se intenta desactivar al último cortador activo.
     */
    @Transactional
    public void setCarverActive(Long id, boolean active) {

        Carver carver = carverRepository.findById(id)
                .orElseThrow(() -> new ResourceNotFoundException("Cortador no encontrado"));

        /* Si se va a desactivar, verificar que no sea el último activo en el sistema. */
        if (!active) {
            long activosActuales = carverRepository.findByIsActiveTrue().stream()
                    .filter(c -> !c.getId().equals(id))
                    .count();
            if (activosActuales < 1) {
                throw new BusinessRuleException(
                        "No se puede desactivar el último cortador activo");
            }
        }

        carver.setIsActive(active);
        carverRepository.save(carver);
    }

    /**
     * Desactiva un cortador específico. Se mantiene para compatibilidad.
     *
     * @param id Identificador del cortador a desactivar.
     */
    @Transactional
    public void deactivateCarver(Long id) {
        setCarverActive(id, false);
    }

    /**
     * Obtiene la lista de todos los cortadores registrados.
     *
     * @return Lista de DTOs con la información de los cortadores.
     */
    @Transactional(readOnly = true)
    public List<CarverDTO> listAllCarvers() {
        return carverRepository.findAll().stream()
                .map(this::toDTO)
                .collect(Collectors.toList());
    }

    /**
     * Obtiene la lista de todos los cortadores que se encuentran activos.
     *
     * @return Lista de DTOs de los cortadores activos.
     */
    @Transactional(readOnly = true)
    public List<CarverDTO> listActiveCarvers() {
        return carverRepository.findByIsActiveTrue().stream()
                .map(this::toDTO)
                .collect(Collectors.toList());
    }

    /**
     * Convierte una entidad Carver en su correspondiente DTO.
     *
     * @param carver Entidad a convertir.
     * @return Objeto CarverDTO poblado con los datos de la entidad.
     */
    private CarverDTO toDTO(Carver carver) {
        return new CarverDTO(
                carver.getId(),
                carver.getUser().getId(),
                carver.getUser().getFirstName(),
                carver.getUser().getLastName(),
                carver.getUser().getDni(),
                carver.getUser().getEmail(),
                carver.getUser().getPhone(),
                carver.getSpecialty(),
                carver.getExperienceYears(),
                carver.getMaxHamsPerDay(),
                carver.getIsActive()
        );
    }
}
