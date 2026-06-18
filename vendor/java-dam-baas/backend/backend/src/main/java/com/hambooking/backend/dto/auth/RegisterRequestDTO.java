package com.hambooking.backend.dto.auth;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

/**
 * Objeto de transferencia de datos para las solicitudes de registro de nuevos usuarios.
 * Incluye validaciones estrictas para garantizar la calidad de los datos de entrada.
 */
public class RegisterRequestDTO {

    /** Documento Nacional de Identidad (8 números y 1 letra). */
    @NotBlank(message = "El DNI no puede estar vacío")
    @Pattern(
            regexp = "^[0-9]{8}[A-Za-z]$",
            message = "El DNI debe tener formato: 12345678A"
    )
    private String dni;

    /** Nombre de pila del usuario. */
    @NotBlank(message = "El nombre no puede estar vacío")
    @Size(min = 2, max = 100, message = "El nombre debe tener entre 2 y 100 caracteres")
    private String firstName;

    /** Apellidos del usuario. */
    @NotBlank(message = "Los apellidos no pueden estar vacíos")
    @Size(min = 2, max = 150, message = "Los apellidos deben tener entre 2 y 150 caracteres")
    private String lastName;

    /** Dirección de correo electrónico única para el registro. */
    @NotBlank(message = "El email no puede estar vacío")
    @Email(message = "El formato del email no es válido")
    private String email;

    /** Contraseña deseada (mínimo 8 caracteres, una mayúscula y un número). */
    @NotBlank(message = "La contraseña no puede estar vacía")
    @Size(min = 8, message = "La contraseña debe tener mínimo 8 caracteres")
    @Pattern(
            regexp = "^(?=.*[A-Z])(?=.*[0-9]).+$",
            message = "La contraseña debe tener al menos una mayúscula y un número"
    )
    private String password;

    /** Número de teléfono de contacto (9 dígitos). */
    @NotBlank(message = "El teléfono no puede estar vacío")
    @Pattern(
            regexp = "^[0-9]{9}$",
            message = "El teléfono debe tener exactamente 9 dígitos"
    )
    private String phone;

    /**
     * Constructor por defecto para Jackson.
     */
    public RegisterRequestDTO() {}

    /**
     * Constructor completo para facilitar el mapeo y las pruebas.
     * @param dni DNI.
     * @param firstName Nombre.
     * @param lastName Apellidos.
     * @param email Email.
     * @param password Password.
     * @param phone Teléfono.
     */
    public RegisterRequestDTO(String dni, String firstName, String lastName,
                              String email, String password, String phone) {
        this.dni = dni;
        this.firstName = firstName;
        this.lastName = lastName;
        this.email = email;
        this.password = password;
        this.phone = phone;
    }

    /** @return DNI del usuario. */
    public String getDni() { return dni; }
    /** @param dni Nuevo DNI. */
    public void setDni(String dni) { this.dni = dni; }

    /** @return Nombre. */
    public String getFirstName() { return firstName; }
    /** @param firstName Nuevo nombre. */
    public void setFirstName(String firstName) { this.firstName = firstName; }

    /** @return Apellidos. */
    public String getLastName() { return lastName; }
    /** @param lastName Nuevos apellidos. */
    public void setLastName(String lastName) { this.lastName = lastName; }

    /** @return Email. */
    public String getEmail() { return email; }
    /** @param email Nuevo email. */
    public void setEmail(String email) { this.email = email; }

    /** @return Password. */
    public String getPassword() { return password; }
    /** @param password Nueva password. */
    public void setPassword(String password) { this.password = password; }

    /** @return Teléfono. */
    public String getPhone() { return phone; }
    /** @param phone Nuevo teléfono. */
    public void setPhone(String phone) { this.phone = phone; }
}
