package com.hambooking.backend.model.enums;

/**
 * Define las categorías de usuarios que pueden recibir notificaciones.
 */
public enum RecipientType {

    /** El usuario que realizó la reserva. */
    CLIENT("Cliente"),

    /** El cortador profesional asignado a la reserva. */
    CARVER("Cortador"),

    /** Personal de gestión de la plataforma. */
    ADMIN("Administrador");

    private final String displayName;

    /**
     * Constructor del enum con nombre legible.
     * @param displayName Nombre amigable para mostrar en la interfaz.
     */
    RecipientType(String displayName) {
        this.displayName = displayName;
    }

    /**
     * Obtiene el nombre legible del tipo de destinatario.
     * @return Cadena de texto con el nombre del destinatario.
     */
    public String getDisplayName() {
        return displayName;
    }
}
