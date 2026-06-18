package com.hambooking.frontend.controllers;

import com.hambooking.frontend.SessionManager;
import com.hambooking.frontend.dto.AuthDTO;
import com.hambooking.frontend.service.ApiClient;
import com.hambooking.frontend.service.ApiException;
import com.hambooking.frontend.util.AlertHelper;
import com.hambooking.frontend.util.ValidationHelper;
import com.hambooking.frontend.util.ViewManager;
import javafx.concurrent.Task;
import javafx.fxml.FXML;
import javafx.fxml.Initializable;
import javafx.scene.control.Button;
import javafx.scene.control.Control;
import javafx.scene.control.Label;
import javafx.scene.control.PasswordField;
import javafx.scene.control.TextField;

import java.io.IOException;
import java.net.URL;
import java.util.ResourceBundle;

/**
 * Controlador Senior para la vista de registro de usuarios.
 * Gestiona la creación de cuentas de cliente con validación exhaustiva,
 * feedback visual avanzado (UX) y navegación semántica.
 */
public final class RegisterController implements Initializable {

    @FXML private TextField firstNameField;
    @FXML private TextField lastNameField;
    @FXML private TextField dniField;
    @FXML private TextField phoneField;
    @FXML private TextField emailField;
    @FXML private PasswordField passwordField;
    @FXML private PasswordField confirmPasswordField;
    @FXML private Label errorLabel;
    @FXML private Button registerBtn;

    private static final String ERROR_CLASS = "error-field";

    @Override
    public void initialize(final URL location, final ResourceBundle resources) {
        ocultarError();
        configurarListenersLimpieza();
    }

    /**
     * Configura listeners para limpiar dinámicamente el estado de error 
     * (texto y bordes rojos) en cuanto el usuario empiece a interactuar.
     */
    private void configurarListenersLimpieza() {
        limpiarErrorAlEscribir(firstNameField);
        limpiarErrorAlEscribir(lastNameField);
        limpiarErrorAlEscribir(dniField);
        limpiarErrorAlEscribir(phoneField);
        limpiarErrorAlEscribir(emailField);
        limpiarErrorAlEscribir(passwordField);
        limpiarErrorAlEscribir(confirmPasswordField);
    }

    private void limpiarErrorAlEscribir(final Control control) {
        if (control instanceof TextField) {
            ((TextField) control).textProperty().addListener((obs, oldV, newV) -> {
                ocultarError();
                control.getStyleClass().remove(ERROR_CLASS);
            });
        }
    }

    /**
     * Gestiona la acción de registro. Valida los datos localmente antes
     * de iniciar la comunicación asíncrona con el servidor.
     */
    @FXML
    private void handleRegister() {
        // 1. Limpiamos estilos previos antes de la nueva validación
        limpiarEstilosErrorGlobal();

        // 2. Validación de negocio y UX
        if (!validarFormulario()) {
            return;
        }

        // 3. Bloqueo de UI y ejecución asíncrona (Task)
        setLoadingState(true);
        final Task<AuthDTO.LoginResponse> registerTask = createRegisterTask();

        registerTask.setOnSucceeded(event -> {
            final AuthDTO.LoginResponse response = registerTask.getValue();
            SessionManager.getInstance().setSession(response);
            navigateToDashboard();
        });

        registerTask.setOnFailed(event -> {
            setLoadingState(false);
            gestionarFalloRegistro(registerTask.getException());
        });

        final Thread thread = new Thread(registerTask);
        thread.setDaemon(true);
        thread.start();
    }

    /**
     * Realiza una validación secuencial. Al usar 'return false' inmediato evitamos
     * sobrecargar al usuario con múltiples mensajes a la vez, guiándole paso a paso,
     * pero destacando el campo exacto que requiere atención.
     */
    private boolean validarFormulario() {
        if (ValidationHelper.isNullOrEmpty(firstNameField.getText())) {
            return fallarValidacion(firstNameField, "El nombre es obligatorio.");
        }
        if (ValidationHelper.isNullOrEmpty(lastNameField.getText())) {
            return fallarValidacion(lastNameField, "Los apellidos son obligatorios.");
        }
        if (!ValidationHelper.isValidDNI(dniField.getText())) {
            return fallarValidacion(dniField, "Formato de DNI no válido (ej: 12345678A).");
        }
        if (!ValidationHelper.isValidPhone(phoneField.getText())) {
            return fallarValidacion(phoneField, "El teléfono debe tener 9 dígitos numéricos.");
        }
        if (!ValidationHelper.isValidEmail(emailField.getText())) {
            return fallarValidacion(emailField, "Introduce un correo electrónico válido.");
        }
        
        final String pass = passwordField.getText();
        if (!ValidationHelper.isStrongPassword(pass)) {
            return fallarValidacion(passwordField, "La contraseña debe tener 8 caracteres, 1 mayúscula y 1 número.");
        }
        
        if (!pass.equals(confirmPasswordField.getText())) {
            return fallarValidacion(confirmPasswordField, "Las contraseñas no coinciden.");
        }
        
        return true;
    }

    /**
     * Aplica el feedback visual negativo a un campo específico y muestra el mensaje.
     */
    private boolean fallarValidacion(final Control campo, final String mensaje) {
        mostrarError(mensaje);
        if (!campo.getStyleClass().contains(ERROR_CLASS)) {
            campo.getStyleClass().add(ERROR_CLASS);
        }
        campo.requestFocus(); // Foco automático para mejorar la UX
        return false;
    }

    private void limpiarEstilosErrorGlobal() {
        firstNameField.getStyleClass().remove(ERROR_CLASS);
        lastNameField.getStyleClass().remove(ERROR_CLASS);
        dniField.getStyleClass().remove(ERROR_CLASS);
        phoneField.getStyleClass().remove(ERROR_CLASS);
        emailField.getStyleClass().remove(ERROR_CLASS);
        passwordField.getStyleClass().remove(ERROR_CLASS);
        confirmPasswordField.getStyleClass().remove(ERROR_CLASS);
    }

    private Task<AuthDTO.LoginResponse> createRegisterTask() {
        final AuthDTO.RegisterRequest request = new AuthDTO.RegisterRequest(
                dniField.getText().trim(),
                firstNameField.getText().trim(),
                lastNameField.getText().trim(),
                emailField.getText().trim(),
                passwordField.getText(),
                phoneField.getText().trim()
        );

        return new Task<>() {
            @Override
            protected AuthDTO.LoginResponse call() throws ApiException {
                return ApiClient.getInstance().post("/auth/register", request, AuthDTO.LoginResponse.class);
            }
        };
    }

    private void gestionarFalloRegistro(final Throwable ex) {
        if (ex instanceof ApiException apiEx) {
            if (apiEx.isConflict()) {
                // Conflicto típico: el email o DNI ya existen
                fallarValidacion(emailField, "El DNI o el Email ya se encuentran registrados.");
                fallarValidacion(dniField, "El DNI o el Email ya se encuentran registrados.");
            } else if (apiEx.isConnectionError()) {
                mostrarError("Error de conexión: El servidor no responde.");
            } else {
                mostrarError(apiEx.getMessage());
            }
        } else {
            mostrarError("Ocurrió un fallo inesperado durante el registro.");
        }
    }

    private void navigateToDashboard() {
        try {
            ViewManager.getInstance().showMainDashboard();
        } catch (IOException e) {
            AlertHelper.showError("Error de Navegación", "Registro completado, pero no se pudo cargar el panel.");
        }
    }

    @FXML
    private void goToLogin() {
        try {
            ViewManager.getInstance().showLogin();
        } catch (IOException e) {
            AlertHelper.showError("Error", "No se pudo cargar la vista de inicio de sesión.");
        }
    }

    private void setLoadingState(final boolean loading) {
        registerBtn.setDisable(loading);
        registerBtn.setText(loading ? "Procesando..." : "Crear cuenta");
    }

    private void mostrarError(final String msg) {
        errorLabel.setText(msg);
        errorLabel.setVisible(true);
        errorLabel.setManaged(true);
    }

    private void ocultarError() {
        errorLabel.setVisible(false);
        errorLabel.setManaged(false);
        errorLabel.setText("");
    }
}
