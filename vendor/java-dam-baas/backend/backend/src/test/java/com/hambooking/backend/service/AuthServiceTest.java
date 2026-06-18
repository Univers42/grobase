package com.hambooking.backend.service;

import com.hambooking.backend.dto.auth.LoginRequestDTO;
import com.hambooking.backend.dto.auth.LoginResponseDTO;
import com.hambooking.backend.dto.auth.RegisterRequestDTO;
import com.hambooking.backend.exception.InvalidCredentialsException;
import com.hambooking.backend.model.entity.User;
import com.hambooking.backend.model.enums.Role;
import com.hambooking.backend.repository.UserRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;

import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
@DisplayName("AuthService - Tests Unitarios")
class AuthServiceTest {

    @Mock
    private UserRepository userRepository;

    @Mock
    private BCryptPasswordEncoder passwordEncoder;

    @InjectMocks
    private AuthService authService;

    private User activeUser;
    private User inactiveUser;

    @BeforeEach
    void setUp() {
        activeUser = new User();
        activeUser.setId(1L);
        activeUser.setEmail("test@test.com");
        activeUser.setPasswordHash("hashed_password");
        activeUser.setRole(Role.CLIENT);
        activeUser.setIsActive(true);

        inactiveUser = new User();
        inactiveUser.setId(2L);
        inactiveUser.setEmail("inactive@test.com");
        inactiveUser.setPasswordHash("hashed_password");
        inactiveUser.setRole(Role.CLIENT);
        inactiveUser.setIsActive(false);
    }

    @Nested
    @DisplayName("1. login()")
    class Login {

        @Test
        @DisplayName("Login exitoso con credenciales correctas")
        void loginSuccess() {
            LoginRequestDTO request = new LoginRequestDTO("test@test.com", "password123");

            when(userRepository.findByEmail(request.getEmail())).thenReturn(Optional.of(activeUser));
            when(passwordEncoder.matches("password123", "hashed_password")).thenReturn(true);

            LoginResponseDTO response = authService.login(request);

            assertNotNull(response);
            assertEquals(1L, response.getId());
            assertEquals("test@test.com", response.getEmail());
            assertEquals(Role.CLIENT, response.getRole());
        }

        @Test
        @DisplayName("Falla si el email no existe")
        void emailNotFound() {
            LoginRequestDTO request = new LoginRequestDTO("wrong@test.com", "password123");
            when(userRepository.findByEmail(request.getEmail())).thenReturn(Optional.empty());

            assertThrows(InvalidCredentialsException.class, () -> authService.login(request));
        }

        @Test
        @DisplayName("Falla si la contraseña es incorrecta")
        void wrongPassword() {
            LoginRequestDTO request = new LoginRequestDTO("test@test.com", "wrongpass");
            when(userRepository.findByEmail(request.getEmail())).thenReturn(Optional.of(activeUser));
            when(passwordEncoder.matches("wrongpass", "hashed_password")).thenReturn(false);

            assertThrows(InvalidCredentialsException.class, () -> authService.login(request));
        }

        @Test
        @DisplayName("Falla si la cuenta está desactivada")
        void accountInactive() {
            LoginRequestDTO request = new LoginRequestDTO("inactive@test.com", "password123");
            when(userRepository.findByEmail(request.getEmail())).thenReturn(Optional.of(inactiveUser));
            when(passwordEncoder.matches("password123", "hashed_password")).thenReturn(true);

            assertThrows(InvalidCredentialsException.class, () -> authService.login(request));
        }
    }

    @Nested
    @DisplayName("2. register()")
    class Register {

        @Test
        @DisplayName("Registro exitoso de nuevo cliente")
        void registerSuccess() {
            RegisterRequestDTO request = new RegisterRequestDTO();
            request.setEmail("new@test.com");
            request.setDni("12345678Z");
            request.setPassword("pass123");
            request.setFirstName("New");
            request.setLastName("User");

            when(userRepository.findByEmail(request.getEmail())).thenReturn(Optional.empty());
            when(userRepository.findByDni(request.getDni())).thenReturn(Optional.empty());
            when(passwordEncoder.encode("pass123")).thenReturn("encoded_pass");

            User savedMock = new User();
            savedMock.setId(10L);
            savedMock.setEmail("new@test.com");
            savedMock.setRole(Role.CLIENT);
            when(userRepository.save(any(User.class))).thenReturn(savedMock);

            LoginResponseDTO response = authService.register(request);

            assertNotNull(response);
            assertEquals(10L, response.getId());
            assertEquals("new@test.com", response.getEmail());
            verify(userRepository).save(any(User.class));
            verify(passwordEncoder).encode("pass123");
        }

        @Test
        @DisplayName("Falla si el email ya existe")
        void emailAlreadyExists() {
            RegisterRequestDTO request = new RegisterRequestDTO();
            request.setEmail("test@test.com");
            when(userRepository.findByEmail(request.getEmail())).thenReturn(Optional.of(activeUser));

            assertThrows(InvalidCredentialsException.class, () -> authService.register(request));
            verify(userRepository, never()).save(any(User.class));
        }

        @Test
        @DisplayName("Falla si el DNI ya existe")
        void dniAlreadyExists() {
            RegisterRequestDTO request = new RegisterRequestDTO();
            request.setEmail("new@test.com");
            request.setDni("12345678Z");
            when(userRepository.findByEmail(request.getEmail())).thenReturn(Optional.empty());
            when(userRepository.findByDni(request.getDni())).thenReturn(Optional.of(activeUser));

            assertThrows(InvalidCredentialsException.class, () -> authService.register(request));
            verify(userRepository, never()).save(any(User.class));
        }
    }
}
