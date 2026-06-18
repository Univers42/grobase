package com.hambooking.backend.controller;

import com.hambooking.backend.dto.service.ServiceResponseDTO;
import com.hambooking.backend.service.ServiceService;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * Controlador REST para gestionar los servicios de corte ofrecidos.
 * Proporciona endpoints para consultar el catálogo de servicios disponibles.
 */
@RestController
@RequestMapping("/api/services")
@RequiredArgsConstructor
public class ServiceController {

    private final ServiceService serviceService;

    /**
     * Lista todos los servicios que se encuentran actualmente activos.
     *
     * @return ResponseEntity con la lista de DTOs de servicios activos.
     */
    @GetMapping
    public ResponseEntity<List<ServiceResponseDTO>> listActiveServices() {
        return ResponseEntity.ok(serviceService.listActiveServices());
    }
}