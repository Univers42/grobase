package com.hambooking.frontend.controllers;

import com.hambooking.frontend.SessionManager;
import com.hambooking.frontend.dto.AppDTO;
import com.hambooking.frontend.service.ApiClient;
import com.hambooking.frontend.service.ApiException;
import com.hambooking.frontend.util.AlertHelper;
import com.hambooking.frontend.util.ValidationHelper;
import com.hambooking.frontend.util.ViewManager;
import javafx.concurrent.Task;
import javafx.fxml.FXML;
import javafx.fxml.Initializable;
import javafx.scene.control.Control;
import javafx.scene.control.Label;
import javafx.scene.control.PasswordField;

import java.io.IOException;
import java.net.URL;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.ResourceBundle;

/**
 * Controlador Senior para la gestión del perfil de usuario y cambio de contraseña.
 * Refactorizado para usar Task de JavaFX, navegación semántica y UX proactiva
 * (feedback visual de errores en el formulario).
 */
public final class ProfileController implements Initializable {

    @FXML private Label sidebarUserName;
    @FXML private Label lblNombre;
    @FXML private Label lblApellidos;
    @FXML private Label lblDni;
    @FXML private Label lblEmail;
    @FXML private Label lblTelefono;
    
    @FXML private PasswordField pfActual;
    @FXML private PasswordField pfNueva;
    @FXML private PasswordField pfConfirmar;
    @FXML private Label lblError;

    private static final String ERROR_CLASS = "error-field";

    @Override
    public void initialize(final URL location, final ResourceBundle resources) {
        final SessionManager session = SessionManager.getInstance();
        sidebarUserName.setText(session.getFullName());
        ocultarError();
        configurarListenersLimpieza();
        cargarDatosUsuario();
    }

    /**
     * Configura listeners para limpiar dinámicamente el estado de error (texto y bordes rojos)
     * en cuanto el usuario empiece a interactuar con los campos de contraseña.
     */
    private void configurarListenersLimpieza() {
        limpiarErrorAlEscribir(pfActual);
        limpiarErrorAlEscribir(pfNueva);
        limpiarErrorAlEscribir(pfConfirmar);
    }

    private void limpiarErrorAlEscribir(final Control control) {
        if (control instanceof PasswordField pf) {
            pf.textProperty().addListener((obs, oldV, newV) -> {
                ocultarError();
                control.getStyleClass().remove(ERROR_CLASS);
            });
        }
    }

    /**
     * Tarea asíncrona segura (Task) para cargar los datos del perfil desde la API.
     */
    private void cargarDatosUsuario() {
        final Long userId = SessionManager.getInstance().getUserId();
        
        final Task<AppDTO.UserResponse> loadTask = new Task<>() {
            @Override
            protected AppDTO.UserResponse call() throws ApiException {
                return ApiClient.getInstance().get("/users/" + userId, AppDTO.UserResponse.class);
            }
        };

        loadTask.setOnSucceeded(e -> {
            final AppDTO.UserResponse user = loadTask.getValue();
            lblNombre.setText(user.firstName != null ? user.firstName : "");
            lblApellidos.setText(user.lastName != null ? user.lastName : "");
            lblDni.setText(user.dni != null ? user.dni : "");
            lblEmail.setText(user.email != null ? user.email : "");
            lblTelefono.setText(user.phone != null ? user.phone : "");
        });

        loadTask.setOnFailed(e -> {
            final Throwable ex = loadTask.getException();
            if (ex instanceof ApiException apiEx) {
                mostrarErrorGlobal("Error al cargar perfil: " + apiEx.getMessage());
            } else {
                mostrarErrorGlobal("Error interno al cargar los datos del perfil.");
            }
        });

        final Thread thread = new Thread(loadTask);
        thread.setDaemon(true);
        thread.start();
    }

    /**
     * Gestiona la solicitud de cambio de contraseña con validación local (UX)
     * antes de llamar a la API de forma asíncrona.
     */
    @FXML
    private void handleCambiarPassword() {
        limpiarEstilosErrorGlobal();

        if (!validarFormularioPassword()) {
            return;
        }

        final String actual = pfActual.getText();
        final String nueva = pfNueva.getText();
        final Long userId = SessionManager.getInstance().getUserId();

        final Map<String, Object> body = new LinkedHashMap<>();
        body.put("currentPassword", actual);
        body.put("newPassword", nueva);

        final Task<Void> updateTask = new Task<>() {
            @Override
            protected Void call() throws ApiException {
                ApiClient.getInstance().put("/users/" + userId + "/password", body);
                return null;
            }
        };

        updateTask.setOnSucceeded(e -> {
            pfActual.clear();
            pfNueva.clear();
            pfConfirmar.clear();
            ocultarError();
            AlertHelper.showInfo("Éxito", "Contraseña actualizada correctamente.");
        });

        updateTask.setOnFailed(e -> {
            final Throwable ex = updateTask.getException();
            if (ex instanceof ApiException apiEx) {
                // Si la contraseña actual es incorrecta, mostramos el error específico.
                fallarValidacion(pfActual, apiEx.getMessage());
            } else {
                mostrarErrorGlobal("Ocurrió un error inesperado al cambiar la contraseña.");
            }
        });

        final Thread thread = new Thread(updateTask);
        thread.setDaemon(true);
        thread.start();
    }

    /**
     * Validación secuencial de negocio y UX para el cambio de contraseña.
     */
    private boolean validarFormularioPassword() {
        final String actual = pfActual.getText();
        final String nueva = pfNueva.getText();
        final String confirmar = pfConfirmar.getText();

        if (ValidationHelper.isNullOrEmpty(actual)) {
            return fallarValidacion(pfActual, "La contraseña actual es obligatoria.");
        }
        if (ValidationHelper.isNullOrEmpty(nueva)) {
            return fallarValidacion(pfNueva, "Introduce una nueva contraseña.");
        }
        if (ValidationHelper.isNullOrEmpty(confirmar)) {
            return fallarValidacion(pfConfirmar, "Confirma la nueva contraseña.");
        }
        
        if (!ValidationHelper.isStrongPassword(nueva)) {
            return fallarValidacion(pfNueva, "La contraseña debe tener 8 caracteres, 1 mayúscula y 1 número.");
        }
        
        if (!nueva.equals(confirmar)) {
            return fallarValidacion(pfConfirmar, "Las contraseñas nuevas no coinciden.");
        }
        
        if (actual.equals(nueva)) {
            return fallarValidacion(pfNueva, "La nueva contraseña no puede ser igual a la actual.");
        }

        return true;
    }

    /**
     * Aplica el feedback visual negativo a un campo específico y muestra el mensaje.
     */
    private boolean fallarValidacion(final Control campo, final String mensaje) {
        mostrarErrorGlobal(mensaje);
        if (!campo.getStyleClass().contains(ERROR_CLASS)) {
            campo.getStyleClass().add(ERROR_CLASS);
        }
        campo.requestFocus();
        return false;
    }

    private void limpiarEstilosErrorGlobal() {
        pfActual.getStyleClass().remove(ERROR_CLASS);
        pfNueva.getStyleClass().remove(ERROR_CLASS);
        pfConfirmar.getStyleClass().remove(ERROR_CLASS);
    }

    // ── Navegación Semántica Desacoplada ───────────────────────

    @FXML private void goToCalendar() { navegarSemantico("Calendario", () -> ViewManager.getInstance().showCalendar()); }
    @FXML private void goToDashboard() { navegarSemantico("Dashboard", () -> ViewManager.getInstance().showMainDashboard()); }
    @FXML private void goToNotifications() { navegarSemantico("Notificaciones", () -> ViewManager.getInstance().showNotifications()); }

    @FXML private void handleLogout() {
        SessionManager.getInstance().clear();
        navegarSemantico("Login", () -> ViewManager.getInstance().showLogin());
    }

    /** Interfaz funcional interna para simplificar los bloques try/catch de navegación. */
    @FunctionalInterface
    private interface Navegador {
        void navegar() throws IOException;
    }

    /** Ejecuta la navegación y captura excepciones de forma global y segura. */
    private void navegarSemantico(final String contexto, final Navegador runnable) {
        try {
            runnable.navegar();
        } catch (IOException e) {
            AlertHelper.showError("Error de Sistema", "No se pudo cargar la vista de " + contexto);
        }
    }

    // ── Utilidades de Presentación ───────────────────────────────

    private void mostrarErrorGlobal(final String msg) {
        lblError.setText(msg);
        lblError.setVisible(true);
        lblError.setManaged(true);
    }

    private void ocultarError() {
        lblError.setVisible(false);
        lblError.setManaged(false);
        lblError.setText("");
    }
}
