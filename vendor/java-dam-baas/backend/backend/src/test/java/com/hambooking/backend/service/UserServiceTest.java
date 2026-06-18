package com.hambooking.backend.service;

import com.hambooking.backend.dto.user.UserResponseDTO;
import com.hambooking.backend.exception.BusinessRuleException;
import com.hambooking.backend.exception.ResourceNotFoundException;
import com.hambooking.backend.model.entity.User;
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

import java.util.List;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
@DisplayName("UserService - Tests Unitarios")
class UserServiceTest {

    @Mock
    private UserRepository userRepository;

    @Mock
    private BCryptPasswordEncoder passwordEncoder;

    @InjectMocks
    private UserService userService;

    private User user;

    @BeforeEach
    void setUp() {
        user = new User();
        user.setId(1L);
        user.setFirstName("Juan");
        user.setPasswordHash("hashed_old");
        user.setIsActive(true);
    }

    @Test
    @DisplayName("Lista todos los usuarios")
    void listAllUsers() {
        when(userRepository.findAll()).thenReturn(List.of(user));
        List<UserResponseDTO> list = userService.listAllUsers();
        assertEquals(1, list.size());
        assertEquals("Juan", list.get(0).getFirstName());
    }

    @Test
    @DisplayName("Obtiene usuario por ID")
    void getUserById() {
        when(userRepository.findById(1L)).thenReturn(Optional.of(user));
        UserResponseDTO response = userService.getUserById(1L);
        assertNotNull(response);
        assertEquals(1L, response.getId());
    }

    @Test
    @DisplayName("Activa o desactiva usuario")
    void setUserActive() {
        when(userRepository.findById(1L)).thenReturn(Optional.of(user));
        userService.setUserActive(1L, false);
        assertFalse(user.getIsActive());
        verify(userRepository).save(user);
    }

    @Nested
    @DisplayName("Cambio de contraseña")
    class ChangePassword {

        @Test
        @DisplayName("Cambia contraseña con exito")
        void success() {
            when(userRepository.findById(1L)).thenReturn(Optional.of(user));
            when(passwordEncoder.matches("old_pass", "hashed_old")).thenReturn(true);
            when(passwordEncoder.encode("new_pass")).thenReturn("hashed_new");

            userService.changePassword(1L, "old_pass", "new_pass");

            assertEquals("hashed_new", user.getPasswordHash());
            verify(userRepository).save(user);
        }

        @Test
        @DisplayName("Falla si la contraseña actual es incorrecta")
        void wrongOldPassword() {
            when(userRepository.findById(1L)).thenReturn(Optional.of(user));
            when(passwordEncoder.matches("wrong_old", "hashed_old")).thenReturn(false);

            assertThrows(BusinessRuleException.class, () -> userService.changePassword(1L, "wrong_old", "new_pass"));
        }
    }
}
