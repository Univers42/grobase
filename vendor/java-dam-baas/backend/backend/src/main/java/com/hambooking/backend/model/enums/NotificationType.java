package com.hambooking.backend.model.enums;

/**
 * Define los diferentes tipos de eventos que disparan una notificación en el sistema.
 */
public enum NotificationType {

    /** Notificación enviada al crear una nueva reserva. */
    CREATED("Reserva Creada"),

    /** Notificación enviada al modificar datos de una reserva existente. */
    MODIFIED("Reserva Modificada"),

    /** Notificación enviada cuando una reserva es anulada. */
    CANCELLED("Reserva Cancelada"),

    /** Notificación de cortesía enviada como recordatorio previo a la cita. */
    REMINDER("Recordatorio");

    private final String displayName;

    /**
     * Constructor del enum con nombre legible.
     * @param displayName Nombre amigable para mostrar en la interfaz.
     */
    NotificationType(String displayName) {
        this.displayName = displayName;
    }

    /**
     * Obtiene el nombre legible del tipo de notificación.
     * @return Cadena de texto con el nombre del tipo.
     */
    public String getDisplayName() {
        return displayName;
    }
}
