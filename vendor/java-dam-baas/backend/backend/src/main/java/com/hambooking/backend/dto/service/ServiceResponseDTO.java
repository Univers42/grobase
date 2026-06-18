package com.hambooking.backend.dto.service;

import java.math.BigDecimal;

/**
 * Objeto de transferencia de datos para la visualización del catálogo de servicios.
 * Proporciona información sobre precios y duraciones para la interfaz de usuario.
 */
public class ServiceResponseDTO {

    /** Identificador único del servicio. */
    private Long id;

    /** Nombre descriptivo del servicio (ej. Corte de Jamón). */
    private String name;

    /** Descripción detallada de lo que incluye el servicio. */
    private String description;

    /** Duración estimada en minutos. */
    private Integer durationMinutes;

    /** Precio base del servicio. */
    private BigDecimal basePrice;

    /** Indica si el servicio está ofertado actualmente. */
    private Boolean isActive;

    /**
     * Constructor por defecto para la deserialización JSON.
     */
    public ServiceResponseDTO() {}

    /**
     * Constructor completo para el mapeo desde la entidad de negocio.
     * @param id ID.
     * @param name Nombre.
     * @param description Descripción.
     * @param durationMinutes Duración.
     * @param basePrice Precio.
     * @param isActive Estado.
     */
    public ServiceResponseDTO(Long id, String name, String description,
                              Integer durationMinutes, BigDecimal basePrice, Boolean isActive) {
        this.id = id;
        this.name = name;
        this.description = description;
        this.durationMinutes = durationMinutes;
        this.basePrice = basePrice;
        this.isActive = isActive;
    }

    /** @return ID Servicio. */
    public Long getId() { return id; }
    /** @param id Nuevo ID. */
    public void setId(Long id) { this.id = id; }

    /** @return Nombre. */
    public String getName() { return name; }
    /** @param name Nuevo nombre. */
    public void setName(String name) { this.name = name; }

    /** @return Descripción. */
    public String getDescription() { return description; }
    /** @param description Nueva descripción. */
    public void setDescription(String description) { this.description = description; }

    /** @return Duración en minutos. */
    public Integer getDurationMinutes() { return durationMinutes; }
    /** @param durationMinutes Nueva duración. */
    public void setDurationMinutes(Integer durationMinutes) { this.durationMinutes = durationMinutes; }

    /** @return Precio base. */
    public BigDecimal getBasePrice() { return basePrice; }
    /** @param basePrice Nuevo precio. */
    public void setBasePrice(BigDecimal basePrice) { this.basePrice = basePrice; }

    /** @return true si está activo. */
    public Boolean getIsActive() { return isActive; }
    /** @param isActive Nuevo estado. */
    public void setIsActive(Boolean isActive) { this.isActive = isActive; }
}
