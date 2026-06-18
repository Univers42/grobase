package com.hambooking.backend.model.enums;

/**
 * Define los estados posibles por los que puede pasar una reserva en su ciclo de vida.
 */
public enum Status {

    /** La reserva ha sido solicitada pero aún no ha sido confirmada por el cortador. */
    PENDING("Pendiente"),

    /** La reserva ha sido aceptada y está programada para su ejecución. */
    CONFIRMED("Confirmada"),

    /** El servicio de corte se ha realizado con éxito. */
    COMPLETED("Completada"),

    /** La reserva ha sido anulada por el cliente o por el sistema. */
    CANCELLED("Cancelada");

    private final String displayName;

    /**
     * Constructor del enum con nombre legible.
     * @param displayName Nombre amigable del estado.
     */
    Status(String displayName) {
        this.displayName = displayName;
    }

    /**
     * Obtiene el nombre legible del estado actual.
     * @return Cadena de texto con la descripción del estado.
     */
    public String getDisplayName() {
        return displayName;
    }
}
