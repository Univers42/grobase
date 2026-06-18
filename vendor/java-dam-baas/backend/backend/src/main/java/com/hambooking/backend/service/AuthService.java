package com.hambooking.backend.service;

import com.hambooking.backend.dto.auth.LoginRequestDTO;
import com.hambooking.backend.dto.auth.LoginResponseDTO;
import com.hambooking.backend.dto.auth.RegisterRequestDTO;
import com.hambooking.backend.exception.InvalidCredentialsException;
import com.hambooking.backend.model.entity.User;
import com.hambooking.backend.model.enums.Role;
import com.hambooking.backend.repository.UserRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Servicio encargado de la gestión de autenticación y registro de usuarios.
 * Implementa la lógica de verificación de credenciales y el cifrado de contraseñas.
 */
@Service
@RequiredArgsConstructor
public class AuthService {

    /** Repositorio de usuarios para realizar consultas y persistencia. */
    private final UserRepository userRepository;

    /** Codificador de contraseñas BCrypt para verificar y encriptar credenciales. */
    private final BCryptPasswordEncoder passwordEncoder;

    /**
     * Realiza el proceso de inicio de sesión verificando las credenciales y el estado del usuario.
     *
     * @param request DTO con email y contraseña.
     * @return DTO con la información de perfil tras el login exitoso.
     * @throws InvalidCredentialsException Si las credenciales son incorrectas o la cuenta está desactivada.
     */
    public LoginResponseDTO login(LoginRequestDTO request) {
        User user = userRepository.findByEmail(request.getEmail())
                .orElseThrow(() -> new InvalidCredentialsException("Email o contraseña incorrectos"));

        if (!passwordEncoder.matches(request.getPassword(), user.getPasswordHash())) {
            throw new InvalidCredentialsException("Email o contraseña incorrectos");
        }

        if (!user.getIsActive()) {
            throw new InvalidCredentialsException("Esta cuenta está desactivada");
        }

        return new LoginResponseDTO(
                user.getId(),
                user.getFirstName(),
                user.getLastName(),
                user.getEmail(),
                user.getRole()
        );
    }

    /**
     * Registra un nuevo cliente en el sistema tras validar la unicidad de sus datos.
     *
     * @param request DTO con los datos del formulario de registro.
     * @return DTO con la información del usuario recién creado.
     * @throws InvalidCredentialsException Si el email o el DNI ya están registrados.
     */
    @Transactional
    public LoginResponseDTO register(RegisterRequestDTO request) {
        if (userRepository.findByEmail(request.getEmail()).isPresent()) {
            throw new InvalidCredentialsException("Este email ya está registrado");
        }
        
        if (userRepository.findByDni(request.getDni()).isPresent()) {
            throw new InvalidCredentialsException("Este DNI ya está registrado");
        }

        User newUser = new User();
        newUser.setDni(request.getDni());
        newUser.setFirstName(request.getFirstName());
        newUser.setLastName(request.getLastName());
        newUser.setEmail(request.getEmail());
        newUser.setPasswordHash(passwordEncoder.encode(request.getPassword()));
        newUser.setPhone(request.getPhone());
        newUser.setRole(Role.CLIENT);
        newUser.setIsActive(true);

        User savedUser = userRepository.save(newUser);

        return new LoginResponseDTO(
                savedUser.getId(),
                savedUser.getFirstName(),
                savedUser.getLastName(),
                savedUser.getEmail(),
                savedUser.getRole()
        );
    }
}
