package com.hambooking.backend.controller;

import com.hambooking.backend.dto.auth.LoginRequestDTO;
import com.hambooking.backend.dto.auth.LoginResponseDTO;
import com.hambooking.backend.dto.auth.RegisterRequestDTO;
import com.hambooking.backend.service.AuthService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

/**
 * Controlador REST para gestionar las operaciones de autenticación y registro de usuarios.
 * Provee endpoints para que los usuarios puedan iniciar sesión y crear nuevas cuentas.
 */
@RestController
@RequestMapping("/api/auth")
@RequiredArgsConstructor
public class AuthController {

    private final AuthService authService;

    /**
     * Gestiona el inicio de sesión de un usuario.
     *
     * @param request DTO con las credenciales de acceso (email y password).
     * @return ResponseEntity con el DTO de respuesta que incluye el token y datos del usuario.
     */
    @PostMapping("/login")
    public ResponseEntity<LoginResponseDTO> login(@Valid @RequestBody LoginRequestDTO request) {
        LoginResponseDTO response = authService.login(request);
        return ResponseEntity.ok(response);
    }

    /**
     * Gestiona el registro de un nuevo usuario en el sistema.
     *
     * @param request DTO con la información necesaria para crear el usuario.
     * @return ResponseEntity con el DTO de respuesta y estado HTTP 201 (Created).
     */
    @PostMapping("/register")
    public ResponseEntity<LoginResponseDTO> register(@Valid @RequestBody RegisterRequestDTO request) {
        LoginResponseDTO response = authService.register(request);
        return ResponseEntity.status(HttpStatus.CREATED).body(response);
    }
}