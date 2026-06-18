package com.hambooking.backend.model.enums;

/**
 * Representa los niveles de acceso y permisos (Roles) dentro del sistema HamBooking.
 */
public enum Role {

    /** Rol con privilegios totales de gestión y administración. */
    ADMIN("Administrador"),

    /** Rol para usuarios finales que realizan reservas de servicios. */
    CLIENT("Cliente");

    private final String displayName;

    /**
     * Constructor del enum con nombre legible.
     * @param displayName Nombre amigable del rol para humanos.
     */
    Role(String displayName) {
        this.displayName = displayName;
    }

    /**
     * Obtiene el nombre amigable del rol.
     * @return Cadena de texto representativa del rol.
     */
    public String getDisplayName() {
        return displayName;
    }
}
