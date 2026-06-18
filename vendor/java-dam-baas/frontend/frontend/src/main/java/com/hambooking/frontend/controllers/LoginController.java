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
import javafx.scene.control.Label;
import javafx.scene.control.PasswordField;
import javafx.scene.control.TextField;

import java.io.IOException;
import java.net.URL;
import java.util.ResourceBundle;

/**
 * Controlador Senior para la vista de inicio de sesión.
 * Implementa validación por Regex, gestión inteligente de excepciones de API
 * y delegación de navegación al ViewManager.
 */
public final class LoginController implements Initializable {

    private static final String EMAIL_REGEX = "^[A-Za-z0-9+_.-]+@(.+)$";

    @FXML private TextField emailField;
    @FXML private PasswordField passwordField;
    @FXML private Label errorLabel;
    @FXML private Button loginBtn;

    @Override
    public void initialize(final URL location, final ResourceBundle resources) {
        ocultarError();
        // Los listeners limpian el estado de error de forma reactiva
        emailField.textProperty().addListener(obs -> ocultarError());
        passwordField.textProperty().addListener(obs -> ocultarError());
    }

    @FXML
    private void handleLogin() {
        final String email = emailField.getText().trim();
        final String password = passwordField.getText();

        if (!validarEntradas(email, password)) {
            return;
        }

        setLoadingState(true);
        final Task<AuthDTO.LoginResponse> loginTask = createLoginTask(email, password);

        loginTask.setOnSucceeded(event -> {
            SessionManager.getInstance().setSession(loginTask.getValue());
            navigateToMain();
        });

        loginTask.setOnFailed(event -> {
            setLoadingState(false);
            final Throwable ex = loginTask.getException();
            
            // Gestión inteligente de errores basada en nuestra ApiException refactorizada
            if (ex instanceof ApiException apiEx) {
                if (apiEx.isConnectionError()) {
                    mostrarError("No se pudo conectar con el servidor. Revisa tu conexión.");
                } else if (apiEx.isUnauthorized()) {
                    mostrarError("Email o contraseña incorrectos.");
                } else {
                    mostrarError(apiEx.getMessage());
                }
            } else {
                mostrarError("Ocurrió un error inesperado al iniciar sesión.");
            }
        });

        final Thread thread = new Thread(loginTask);
        thread.setDaemon(true);
        thread.start();
    }

    private void navigateToMain() {
        try {
            ViewManager.getInstance().showMainDashboard();
        } catch (IOException e) {
            AlertHelper.showError("Error de Sistema", "No se pudo cargar el panel principal.");
        }
    }

    @FXML
    private void goToRegister() {
        try {
            ViewManager.getInstance().showRegister();
        } catch (IOException e) {
            AlertHelper.showError("Error", "No se pudo cargar la vista de registro.");
        }
    }

    private boolean validarEntradas(final String email, final String password) {
        if (ValidationHelper.isNullOrEmpty(email) || ValidationHelper.isNullOrEmpty(password)) {
            mostrarError("Por favor, rellena todos los campos.");
            return false;
        }
        if (!ValidationHelper.isValidEmail(email)) {
            mostrarError("El formato del email no es válido.");
            return false;
        }
        return true;
    }

    private Task<AuthDTO.LoginResponse> createLoginTask(final String email, final String password) {
        return new Task<>() {
            @Override
            protected AuthDTO.LoginResponse call() throws ApiException {
                AuthDTO.LoginRequest request = new AuthDTO.LoginRequest(email, password);
                return ApiClient.getInstance().post("/auth/login", request, AuthDTO.LoginResponse.class);
            }
        };
    }

    private void setLoadingState(final boolean loading) {
        loginBtn.setDisable(loading);
        loginBtn.setText(loading ? "Conectando..." : "Iniciar sesión");
    }

    private void mostrarError(final String msg) {
        errorLabel.setText(msg);
        errorLabel.setVisible(true);
        errorLabel.setManaged(true);
    }

    private void ocultarError() {
        errorLabel.setVisible(false);
        errorLabel.setManaged(false);
    }
}
