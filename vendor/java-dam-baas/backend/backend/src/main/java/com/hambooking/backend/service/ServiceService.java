package com.hambooking.backend.service;

import com.hambooking.backend.dto.service.ServiceResponseDTO;
import com.hambooking.backend.repository.ServiceRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.stream.Collectors;

/**
 * Servicio encargado de gestionar el catálogo de servicios ofrecidos.
 * Proporciona métodos para consultar los servicios activos disponibles para reserva.
 */
@Service
@RequiredArgsConstructor
public class ServiceService {

    /** Repositorio de servicios para acceso a la base de datos. */
    private final ServiceRepository serviceRepository;

    /**
     * Obtiene una lista con todos los servicios que actualmente se encuentran activos.
     *
     * @return Lista de DTOs con la información de los servicios activos.
     */
    @Transactional(readOnly = true)
    public List<ServiceResponseDTO> listActiveServices() {
        return serviceRepository.findByIsActiveTrue()
                .stream()
                .map(s -> new ServiceResponseDTO(
                        s.getId(),
                        s.getName(),
                        s.getDescription(),
                        s.getDurationMinutes(),
                        s.getBasePrice(),
                        s.getIsActive()
                ))
                .collect(Collectors.toList());
    }
}
