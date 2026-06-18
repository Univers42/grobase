package com.hambooking.backend.controller;

import com.hambooking.backend.dto.notification.NotificationResponseDTO;
import com.hambooking.backend.service.NotificationService;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;

/**
 * Controlador REST para la gestión y consulta de notificaciones.
 * Permite listar notificaciones de forma global para administración o por usuario específico.
 */
@RestController
@RequestMapping("/api/notifications")
@RequiredArgsConstructor
public class NotificationController {

    private final NotificationService notificationService;

    /**
     * Recupera todas las notificaciones registradas en el sistema.
     *
     * @return ResponseEntity con la lista completa de notificaciones.
     */
    @GetMapping
    public ResponseEntity<List<NotificationResponseDTO>> listAllNotifications() {
        return ResponseEntity.ok(notificationService.listAllNotifications());
    }

    /**
     * Recupera las notificaciones pertenecientes a un usuario específico.
     *
     * @param userId ID del usuario cuyas notificaciones se desean consultar.
     * @return ResponseEntity con la lista de notificaciones del usuario.
     */
    @GetMapping("/user/{userId}")
    public ResponseEntity<List<NotificationResponseDTO>> listByUser(
            @PathVariable Long userId) {
        return ResponseEntity.ok(notificationService.listByUser(userId));
    }
}