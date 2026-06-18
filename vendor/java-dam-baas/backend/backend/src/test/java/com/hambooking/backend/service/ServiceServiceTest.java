package com.hambooking.backend.service;

import com.hambooking.backend.dto.service.ServiceResponseDTO;
import com.hambooking.backend.model.entity.Service;
import com.hambooking.backend.repository.ServiceRepository;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
@DisplayName("ServiceService - Tests Unitarios")
class ServiceServiceTest {

    @Mock
    private ServiceRepository serviceRepository;

    @InjectMocks
    private ServiceService serviceService;

    @Test
    @DisplayName("Lista servicios activos")
    void listActiveServices() {
        Service s = new Service();
        s.setId(1L);
        s.setName("Corte Jamon");
        s.setBasePrice(new BigDecimal("50.00"));
        s.setIsActive(true);

        when(serviceRepository.findByIsActiveTrue()).thenReturn(List.of(s));

        List<ServiceResponseDTO> list = serviceService.listActiveServices();

        assertEquals(1, list.size());
        assertEquals("Corte Jamon", list.get(0).getName());
    }
}
