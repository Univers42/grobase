package com.hambooking.backend.dto.carver;

import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

/**
 * Objeto de transferencia de datos para el perfil de cortador.
 * Consolida la información profesional del cortador junto con los datos personales
 * heredados de su cuenta de usuario para facilitar el consumo desde el frontend.
 */
public class CarverDTO {

    /** Identificador único del perfil de cortador. */
    private Long id;

    /** Identificador del usuario asociado. */
    private Long userId;

    /** Nombre del profesional (solo lectura en este contexto). */
    private String firstName;

    /** Apellidos del profesional (solo lectura en este contexto). */
    private String lastName;

    /** DNI del profesional (solo lectura en este contexto). */
    private String dni;

    /** Email de contacto (solo lectura en este contexto). */
    private String email;

    /** Teléfono de contacto (solo lectura en este contexto). */
    private String phone;

    /** Estado de disponibilidad del cortador. */
    private Boolean isActive;

    /** Especialidad técnica del cortador (ej. Jamón de Bellota). */
    @Size(max = 100, message = "La especialidad no puede exceder 100 caracteres")
    private String specialty;

    /** Años de experiencia acumulada. */
    @Min(value = 0, message = "Los años de experiencia no pueden ser negativos")
    private Integer experienceYears;

    /** Límite diario de piezas de jamón que el profesional puede atender. */
    @NotNull(message = "El límite diario de servicios es obligatorio")
    @Min(value = 1, message = "Debe permitir al menos 1 servicio por día")
    @Max(value = 10, message = "El límite máximo de servicios por día es 10")
    private Integer maxHamsPerDay;

    /**
     * Constructor por defecto para la deserialización JSON.
     */
    public CarverDTO() {}

    /**
     * Constructor completo utilizado para mapear la entidad Carver y su User asociado a un DTO de respuesta.
     * @param id ID Carver.
     * @param userId ID User.
     * @param firstName Nombre.
     * @param lastName Apellidos.
     * @param dni DNI.
     * @param email Email.
     * @param phone Teléfono.
     * @param specialty Especialidad.
     * @param experienceYears Experiencia.
     * @param maxHamsPerDay Límite diario.
     * @param isActive Estado.
     */
    public CarverDTO(Long id, Long userId,
                     String firstName, String lastName, String dni, String email, String phone,
                     String specialty, Integer experienceYears, Integer maxHamsPerDay,
                     Boolean isActive) {
        this.id = id;
        this.userId = userId;
        this.firstName = firstName;
        this.lastName = lastName;
        this.dni = dni;
        this.email = email;
        this.phone = phone;
        this.specialty = specialty;
        this.experienceYears = experienceYears;
        this.maxHamsPerDay = maxHamsPerDay;
        this.isActive = isActive;
    }

    /** @return ID Carver. */
    public Long getId() { return id; }
    /** @param id Nuevo ID. */
    public void setId(Long id) { this.id = id; }

    /** @return ID Usuario. */
    public Long getUserId() { return userId; }
    /** @param userId Nuevo ID Usuario. */
    public void setUserId(Long userId) { this.userId = userId; }

    /** @return Nombre. */
    public String getFirstName() { return firstName; }
    /** @param firstName Nuevo nombre. */
    public void setFirstName(String firstName) { this.firstName = firstName; }

    /** @return Apellidos. */
    public String getLastName() { return lastName; }
    /** @param lastName Nuevos apellidos. */
    public void setLastName(String lastName) { this.lastName = lastName; }

    /** @return DNI. */
    public String getDni() { return dni; }
    /** @param dni Nuevo DNI. */
    public void setDni(String dni) { this.dni = dni; }

    /** @return Email. */
    public String getEmail() { return email; }
    /** @param email Nuevo email. */
    public void setEmail(String email) { this.email = email; }

    /** @return Teléfono. */
    public String getPhone() { return phone; }
    /** @param phone Nuevo teléfono. */
    public void setPhone(String phone) { this.phone = phone; }

    /** @return Especialidad. */
    public String getSpecialty() { return specialty; }
    /** @param specialty Nueva especialidad. */
    public void setSpecialty(String specialty) { this.specialty = specialty; }

    /** @return Años de experiencia. */
    public Integer getExperienceYears() { return experienceYears; }
    /** @param experienceYears Nueva experiencia. */
    public void setExperienceYears(Integer experienceYears) { this.experienceYears = experienceYears; }

    /** @return Límite diario de servicios. */
    public Integer getMaxHamsPerDay() { return maxHamsPerDay; }
    /** @param maxHamsPerDay Nuevo límite diario. */
    public void setMaxHamsPerDay(Integer maxHamsPerDay) { this.maxHamsPerDay = maxHamsPerDay; }

    /** @return Estado de actividad. */
    public Boolean getIsActive() { return isActive; }
    /** @param isActive Nuevo estado. */
    public void setIsActive(Boolean isActive) { this.isActive = isActive; }
}
