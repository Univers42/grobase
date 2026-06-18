package com.hambooking.frontend.util;

import com.hambooking.frontend.SessionManager;
import javafx.application.Platform;
import javafx.fxml.FXMLLoader;
import javafx.scene.Parent;
import javafx.scene.Scene;
import javafx.stage.Stage;

import java.io.IOException;
import java.net.URL;

/**
 * Gestor centralizado de navegación para la aplicación HamBooking.
 * Centraliza las rutas FXML y gestiona la lógica de transición entre pantallas.
 */
public final class ViewManager {

    private static final String FXML_LOGIN = "/com/hambooking/frontend/fxml/login.fxml";
    private static final String FXML_REGISTER = "/com/hambooking/frontend/fxml/register.fxml";
    private static final String FXML_ADMIN_DASHBOARD = "/com/hambooking/frontend/fxml/admin-dashboard.fxml";
    private static final String FXML_CLIENT_DASHBOARD = "/com/hambooking/frontend/fxml/client-dashboard.fxml";
    private static final String FXML_PROFILE = "/com/hambooking/frontend/fxml/profile.fxml";
    private static final String FXML_NOTIFICATIONS = "/com/hambooking/frontend/fxml/notifications.fxml";
    private static final String FXML_CALENDAR = "/com/hambooking/frontend/fxml/calendar.fxml";

    private Stage mainStage;

    private ViewManager() {}

    private static class Holder {
        private static final ViewManager INSTANCE = new ViewManager();
    }

    public static ViewManager getInstance() {
        return Holder.INSTANCE;
    }

    public void setMainStage(final Stage mainStage) {
        this.mainStage = mainStage;
    }

    public Stage getMainStage() {
        return mainStage;
    }

    // ── Métodos de Navegación Semántica ─────────────────────────

    public void showLogin() throws IOException {
        navigateTo(FXML_LOGIN, "HamBooking - Iniciar sesión");
    }

    public void showRegister() throws IOException {
        navigateTo(FXML_REGISTER, "HamBooking - Crear cuenta");
    }

    public void showProfile() throws IOException {
        navigateTo(FXML_PROFILE, "HamBooking - Mi Perfil");
    }

    public void showNotifications() throws IOException {
        navigateTo(FXML_NOTIFICATIONS, "HamBooking - Notificaciones");
    }

    public void showCalendar() throws IOException {
        navigateTo(FXML_CALENDAR, "HamBooking - Nueva Reserva");
    }

    /**
     * Dirige al usuario a su panel correspondiente según su rol de sesión.
     */
    public void showMainDashboard() throws IOException {
        SessionManager session = SessionManager.getInstance();
        if (session.isAdmin()) {
            navigateTo(FXML_ADMIN_DASHBOARD, "HamBooking - Panel de Administración");
        } else {
            navigateTo(FXML_CLIENT_DASHBOARD, "HamBooking - Mi Panel");
        }
    }

    // ── Lógica de carga base ─────────────────────────────────────

    public void navigateTo(final String fxmlPath, final String title) throws IOException {
        if (mainStage == null) {
            throw new IllegalStateException("ViewManager: El Stage principal no ha sido configurado.");
        }

        URL resource = getClass().getResource(fxmlPath);
        if (resource == null) {
            throw new IOException("No se pudo encontrar el archivo FXML en: " + fxmlPath);
        }

        FXMLLoader loader = new FXMLLoader(resource);
        Parent root = loader.load();

        Platform.runLater(() -> {
            Scene scene = mainStage.getScene();
            if (scene == null) {
                scene = new Scene(root);
                mainStage.setScene(scene);
            } else {
                scene.setRoot(root);
            }
            mainStage.setTitle(title);
            mainStage.centerOnScreen();
        });
    }
}
