package com.hambooking.backend.service;

import com.hambooking.backend.dto.carver.CarverDTO;
import com.hambooking.backend.exception.BusinessRuleException;
import com.hambooking.backend.exception.ResourceNotFoundException;
import com.hambooking.backend.model.entity.Carver;
import com.hambooking.backend.model.entity.User;
import com.hambooking.backend.repository.CarverRepository;
import com.hambooking.backend.repository.UserRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
@DisplayName("CarverService - Tests Unitarios")
class CarverServiceTest {

    @Mock
    private CarverRepository carverRepository;

    @Mock
    private UserRepository userRepository;

    @InjectMocks
    private CarverService carverService;

    private User user;
    private Carver carver;

    @BeforeEach
    void setUp() {
        user = new User();
        user.setId(1L);
        user.setFirstName("Cortador");

        carver = new Carver();
        carver.setId(10L);
        carver.setUser(user);
        carver.setSpecialty("Jamon");
        carver.setExperienceYears(5);
        carver.setMaxHamsPerDay(3);
        carver.setIsActive(true);
    }

    @Nested
    @DisplayName("1. createCarver")
    class CreateCarver {

        @Test
        @DisplayName("Crea cortador con exito")
        void success() {
            CarverDTO request = new CarverDTO();
            request.setUserId(1L);
            request.setSpecialty("Jamon");
            request.setExperienceYears(5);
            request.setMaxHamsPerDay(3);

            when(userRepository.findById(1L)).thenReturn(Optional.of(user));
            when(carverRepository.existsByUser(user)).thenReturn(false);
            when(carverRepository.save(any(Carver.class))).thenReturn(carver);

            CarverDTO response = carverService.createCarver(request);

            assertNotNull(response);
            assertEquals("Jamon", response.getSpecialty());
            verify(carverRepository).save(any(Carver.class));
        }

        @Test
        @DisplayName("Falla si el usuario ya es cortador")
        void alreadyCarver() {
            CarverDTO request = new CarverDTO();
            request.setUserId(1L);

            when(userRepository.findById(1L)).thenReturn(Optional.of(user));
            when(carverRepository.existsByUser(user)).thenReturn(true);

            assertThrows(BusinessRuleException.class, () -> carverService.createCarver(request));
        }
    }

    @Nested
    @DisplayName("2. updateCarver")
    class UpdateCarver {

        @Test
        @DisplayName("Actualiza cortador con exito")
        void success() {
            CarverDTO request = new CarverDTO();
            request.setSpecialty("Paleta");

            when(carverRepository.findById(10L)).thenReturn(Optional.of(carver));
            when(carverRepository.save(any(Carver.class))).thenReturn(carver);

            CarverDTO response = carverService.updateCarver(10L, request);

            assertEquals("Paleta", carver.getSpecialty());
            assertNotNull(response);
        }
    }

    @Nested
    @DisplayName("3. setCarverActive")
    class SetCarverActive {

        @Test
        @DisplayName("Activa cortador con exito")
        void activateSuccess() {
            carver.setIsActive(false);
            when(carverRepository.findById(10L)).thenReturn(Optional.of(carver));
            
            carverService.setCarverActive(10L, true);
            
            assertTrue(carver.getIsActive());
            verify(carverRepository).save(carver);
        }

        @Test
        @DisplayName("Desactiva cortador si no es el ultimo")
        void deactivateSuccess() {
            Carver otherActive = new Carver();
            otherActive.setId(11L);
            when(carverRepository.findById(10L)).thenReturn(Optional.of(carver));
            when(carverRepository.findByIsActiveTrue()).thenReturn(List.of(carver, otherActive));

            carverService.setCarverActive(10L, false);

            assertFalse(carver.getIsActive());
            verify(carverRepository).save(carver);
        }

        @Test
        @DisplayName("Falla al desactivar si es el ultimo activo")
        void deactivateFailsIfLast() {
            when(carverRepository.findById(10L)).thenReturn(Optional.of(carver));
            when(carverRepository.findByIsActiveTrue()).thenReturn(List.of(carver));

            assertThrows(BusinessRuleException.class, () -> carverService.setCarverActive(10L, false));
        }
    }

    @Nested
    @DisplayName("4. Listas")
    class Lists {

        @Test
        @DisplayName("Lista todos")
        void listAll() {
            when(carverRepository.findAll()).thenReturn(List.of(carver));
            List<CarverDTO> list = carverService.listAllCarvers();
            assertEquals(1, list.size());
        }

        @Test
        @DisplayName("Lista activos")
        void listActive() {
            when(carverRepository.findByIsActiveTrue()).thenReturn(List.of(carver));
            List<CarverDTO> list = carverService.listActiveCarvers();
            assertEquals(1, list.size());
        }
    }
}
