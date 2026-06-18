package com.hambooking.backend.controller;

import com.hambooking.backend.dto.carver.CarverDTO;
import com.hambooking.backend.service.CarverService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;

/**
 * Controlador REST para la gestión de cortadores de jamón.
 * Ofrece funcionalidades para listar, crear, actualizar y gestionar el estado de los cortadores.
 */
@RestController
@RequestMapping("/api/carvers")
@RequiredArgsConstructor
public class CarverController {

    private final CarverService carverService;

    /**
     * Lista todos los cortadores registrados en el sistema (incluyendo inactivos).
     *
     * @return ResponseEntity con la lista de DTOs de todos los cortadores.
     */
    @GetMapping
    public ResponseEntity<List<CarverDTO>> listAllCarvers() {
        return ResponseEntity.ok(carverService.listAllCarvers());
    }

    /**
     * Lista únicamente los cortadores que están marcados como activos.
     *
     * @return ResponseEntity con la lista de DTOs de cortadores activos.
     */
    @GetMapping("/active")
    public ResponseEntity<List<CarverDTO>> listActiveCarvers() {
        return ResponseEntity.ok(carverService.listActiveCarvers());
    }

    /**
     * Crea un nuevo cortador en el sistema.
     *
     * @param request DTO con la información del cortador a crear.
     * @return ResponseEntity con el DTO del cortador creado y estado HTTP 201.
     */
    @PostMapping
    public ResponseEntity<CarverDTO> createCarver(@Valid @RequestBody CarverDTO request) {
        return ResponseEntity.status(HttpStatus.CREATED)
                .body(carverService.createCarver(request));
    }

    /**
     * Actualiza la información de un cortador existente.
     *
     * @param id ID del cortador a actualizar.
     * @param request DTO con los nuevos datos del cortador.
     * @return ResponseEntity con el DTO del cortador actualizado.
     */
    @PutMapping("/{id}")
    public ResponseEntity<CarverDTO> updateCarver(@PathVariable Long id,
                                                  @Valid @RequestBody CarverDTO request) {
        return ResponseEntity.ok(carverService.updateCarver(id, request));
    }

    /**
     * Activa un cortador que estaba inactivo.
     *
     * @param id ID del cortador a activar.
     * @return ResponseEntity sin contenido (HTTP 204).
     */
    @PatchMapping("/{id}/activate")
    public ResponseEntity<Void> activateCarver(@PathVariable Long id) {
        carverService.setCarverActive(id, true);
        return ResponseEntity.noContent().build();
    }

    /**
     * Desactiva un cortador del sistema.
     *
     * @param id ID del cortador a desactivar.
     * @return ResponseEntity sin contenido (HTTP 204).
     */
    @PatchMapping("/{id}/deactivate")
    public ResponseEntity<Void> deactivateCarver(@PathVariable Long id) {
        carverService.deactivateCarver(id);
        return ResponseEntity.noContent().build();
    }
}