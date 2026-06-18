package com.hambooking.frontend;

import com.hambooking.frontend.dto.AuthDTO;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Tests unitarios para SessionManager.
 * Al ser un Singleton, es crucial limpiar su estado antes de cada test.
 */
@DisplayName("SessionManager - Tests Unitarios")
class SessionManagerTest {

    @BeforeEach
    void setUp() {
        // Limpiamos el singleton antes de cada test para asegurar aislamiento
        SessionManager.getInstance().clear();
    }

    @Test
    @DisplayName("El patrón Singleton devuelve siempre la misma instancia")
    void testSingletonInstance() {
        SessionManager instance1 = SessionManager.getInstance();
        SessionManager instance2 = SessionManager.getInstance();

        assertNotNull(instance1, "La instancia no debe ser nula");
        assertSame(instance1, instance2, "Ambas llamadas deben devolver exactamente la misma referencia de memoria");
    }

    @Test
    @DisplayName("setSession carga los datos correctamente desde el DTO")
    void testSetSession() {
        // GIVEN
        AuthDTO.LoginResponse mockUser = new AuthDTO.LoginResponse();
        mockUser.id = 1L;
        mockUser.firstName = "Juan";
        mockUser.lastName = "Pérez";
        mockUser.email = "juan@example.com";
        mockUser.role = "CLIENT";

        SessionManager session = SessionManager.getInstance();

        // WHEN
        session.setSession(mockUser);

        // THEN
        assertTrue(session.isLoggedIn(), "El usuario debería estar marcado como logueado");
        assertEquals(1L, session.getUserId());
        assertEquals("Juan", session.getFirstName());
        assertEquals("Pérez", session.getLastName());
        assertEquals("juan@example.com", session.getEmail());
        assertEquals("CLIENT", session.getRole());
        assertEquals("Juan Pérez", session.getFullName());
        assertFalse(session.isAdmin(), "Un rol CLIENT no debería ser administrador");
    }

    @Test
    @DisplayName("setSession maneja valores nulos en nombre y apellidos al pedir FullName")
    void testGetFullNameWithNulls() {
        AuthDTO.LoginResponse mockUser = new AuthDTO.LoginResponse();
        mockUser.id = 2L;
        mockUser.firstName = null;
        mockUser.lastName = null;

        SessionManager session = SessionManager.getInstance();
        session.setSession(mockUser);

        // Debería devolver un espacio (" ") ya que el código hace (null ? "" : firstName) + " " + (null ? "" : lastName)
        assertEquals(" ", session.getFullName(), "Debe manejar valores nulos sin lanzar NullPointerException");
    }

    @Test
    @DisplayName("isAdmin devuelve true únicamente si el rol es ADMIN")
    void testIsAdmin() {
        SessionManager session = SessionManager.getInstance();
        AuthDTO.LoginResponse adminUser = new AuthDTO.LoginResponse();
        adminUser.id = 1L;
        adminUser.role = "ADMIN";

        session.setSession(adminUser);
        assertTrue(session.isAdmin(), "Debe devolver true para el rol ADMIN");

        AuthDTO.LoginResponse clientUser = new AuthDTO.LoginResponse();
        clientUser.id = 2L;
        clientUser.role = "CLIENT";

        session.setSession(clientUser);
        assertFalse(session.isAdmin(), "Debe devolver false para el rol CLIENT");
    }

    @Test
    @DisplayName("clear borra toda la información de la sesión")
    void testClear() {
        // GIVEN
        SessionManager session = SessionManager.getInstance();
        AuthDTO.LoginResponse user = new AuthDTO.LoginResponse();
        user.id = 1L;
        user.firstName = "Test";
        session.setSession(user);

        assertTrue(session.isLoggedIn());

        // WHEN
        session.clear();

        // THEN
        assertFalse(session.isLoggedIn(), "isLoggedIn debe ser false tras limpiar la sesión");
        assertNull(session.getUserId());
        assertNull(session.getFirstName());
        assertNull(session.getLastName());
        assertNull(session.getEmail());
        assertNull(session.getRole());
        // getFullName con nulos devuelve " "
        assertEquals(" ", session.getFullName());
    }
}
