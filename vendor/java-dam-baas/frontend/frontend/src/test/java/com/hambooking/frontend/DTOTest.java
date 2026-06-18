package com.hambooking.frontend;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.hambooking.frontend.dto.AppDTO;
import com.hambooking.frontend.dto.AuthDTO;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.junit.jupiter.api.Assertions.*;

@DisplayName("DTOs - Tests de Mapeo y Lógica")
class DTOTest {

    private final ObjectMapper mapper = new ObjectMapper();

    @Test
    @DisplayName("LoginRequest serializa a JSON con propiedades explícitas")
    void testLoginRequestSerialization() throws JsonProcessingException {
        AuthDTO.LoginRequest request = new AuthDTO.LoginRequest("test@test.com", "1234");
        String json = mapper.writeValueAsString(request);
        
        assertTrue(json.contains("\"email\":\"test@test.com\""));
        assertTrue(json.contains("\"password\":\"1234\""));
    }

    @Test
    @DisplayName("LoginResponse deserializa JSON con propiedades desconocidas gracias a @JsonIgnoreProperties")
    void testLoginResponseDeserializationWithUnknownProperties() throws JsonProcessingException {
        String json = "{\"id\":1, \"email\":\"user@test.com\", \"role\":\"CLIENT\", \"new_unknown_field\":\"ignored\"}";
        
        AuthDTO.LoginResponse response = mapper.readValue(json, AuthDTO.LoginResponse.class);
        
        assertNotNull(response);
        assertEquals(1L, response.id);
        assertEquals("user@test.com", response.email);
        assertEquals("CLIENT", response.role);
    }

    @Test
    @DisplayName("AppDTO.ServiceResponse.getDisplayName() formatea correctamente horas y minutos")
    void testServiceDisplayNameFormatting() {
        AppDTO.ServiceResponse service = new AppDTO.ServiceResponse();
        service.name = "Corte Básico";
        service.basePrice = new BigDecimal("15.50");

        // 30 min (sin horas)
        service.durationMinutes = 30;
        assertEquals("Corte Básico (30min) - 15.50 EUR", service.getDisplayName());

        // 60 min (1 hora exacta)
        service.durationMinutes = 60;
        assertEquals("Corte Básico (1h) - 15.50 EUR", service.getDisplayName());

        // 90 min (1 hora y media)
        service.durationMinutes = 90;
        assertEquals("Corte Básico (1h30min) - 15.50 EUR", service.getDisplayName());
    }

    @Test
    @DisplayName("AppDTO.CarverResponse.getDisplayName() usa el nombre o la especialidad como fallback")
    void testCarverDisplayNameFallback() {
        AppDTO.CarverResponse carver = new AppDTO.CarverResponse();
        carver.id = 10L;

        // Si no hay nada, usa ID
        assertEquals("Cortador #10", carver.getDisplayName());

        // Si hay especialidad, la usa de fallback
        carver.specialty = "Corte a cuchillo";
        assertEquals("Corte a cuchillo", carver.getDisplayName());

        // Si hay nombre, prevalece
        carver.firstName = "Paco";
        carver.lastName = "Gómez";
        assertEquals("Paco Gómez", carver.getDisplayName());
    }
}
