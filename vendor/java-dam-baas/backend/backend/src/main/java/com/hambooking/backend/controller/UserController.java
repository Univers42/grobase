package com.hambooking.backend.controller;

import com.hambooking.backend.dto.user.UserResponseDTO;
import com.hambooking.backend.service.UserService;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Map;

/**
 * Controlador REST para la gestión de usuarios del sistema.
 * Permite consultar información de usuarios, activar/desactivar cuentas y gestionar contraseñas.
 */
@RestController
@RequestMapping("/api/users")
@RequiredArgsConstructor
public class UserController {

    private final UserService userService;

    /**
     * Obtiene la lista completa de todos los usuarios registrados.
     *
     * @return ResponseEntity con la lista de DTOs de todos los usuarios.
     */
    @GetMapping
    public ResponseEntity<List<UserResponseDTO>> listAllUsers() {
        return ResponseEntity.ok(userService.listAllUsers());
    }

    /**
     * Obtiene los detalles de un usuario específico a partir de su ID.
     *
     * @param id ID del usuario a consultar.
     * @return ResponseEntity con la información detallada del usuario.
     */
    @GetMapping("/{id}")
    public ResponseEntity<UserResponseDTO> getUserById(@PathVariable Long id) {
        return ResponseEntity.ok(userService.getUserById(id));
    }

    /**
     * Activa una cuenta de usuario.
     *
     * @param id ID del usuario a activar.
     * @return ResponseEntity sin contenido (HTTP 204).
     */
    @PatchMapping("/{id}/activate")
    public ResponseEntity<Void> activateUser(@PathVariable Long id) {
        userService.setUserActive(id, true);
        return ResponseEntity.noContent().build();
    }

    /**
     * Desactiva una cuenta de usuario.
     *
     * @param id ID del usuario a desactivar.
     * @return ResponseEntity sin contenido (HTTP 204).
     */
    @PatchMapping("/{id}/deactivate")
    public ResponseEntity<Void> deactivateUser(@PathVariable Long id) {
        userService.setUserActive(id, false);
        return ResponseEntity.noContent().build();
    }

    /**
     * Permite a un usuario cambiar su contraseña actual por una nueva.
     *
     * @param id ID del usuario que solicita el cambio.
     * @param body Mapa que contiene 'currentPassword' y 'newPassword'.
     * @return ResponseEntity sin contenido (HTTP 204).
     */
    @PutMapping("/{id}/password")
    public ResponseEntity<Void> changePassword(
            @PathVariable Long id,
            @RequestBody Map<String, String> body) {
        userService.changePassword(id,
                body.get("currentPassword"),
                body.get("newPassword"));
        return ResponseEntity.noContent().build();
    }
}