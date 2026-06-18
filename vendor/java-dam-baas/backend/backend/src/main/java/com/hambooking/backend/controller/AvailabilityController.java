package com.hambooking.backend.controller;

import com.hambooking.backend.service.AvailabilityService;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.time.LocalTime;
import java.util.List;

/**
 * Controlador REST para consultar la disponibilidad de horarios.
 * Permite obtener las franjas horarias libres para un cortador, fecha y servicio específicos.
 */
@RestController
@RequestMapping("/api/availability")
@RequiredArgsConstructor
public class AvailabilityController {

    private final AvailabilityService availabilityService;

    /**
     * Obtiene la lista de horarios disponibles según los criterios proporcionados.
     *
     * @param carverId ID del cortador de jamón.
     * @param date Fecha para la cual se consulta la disponibilidad.
     * @param serviceId ID del servicio solicitado.
     * @return ResponseEntity con la lista de objetos LocalTime que representan los huecos disponibles.
     */
    @GetMapping
    public ResponseEntity<List<LocalTime>> getAvailableSlots(
            @RequestParam Long carverId,
            @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate date,
            @RequestParam Long serviceId) {

        List<LocalTime> slots = availabilityService.getAvailableSlots(carverId, date, serviceId);
        return ResponseEntity.ok(slots);
    }
}