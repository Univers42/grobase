package com.hambooking.frontend.controllers;

import com.hambooking.frontend.SessionManager;
import com.hambooking.frontend.dto.AppDTO;
import com.hambooking.frontend.service.ApiClient;
import com.hambooking.frontend.service.ApiException;
import com.hambooking.frontend.util.AlertHelper;
import com.hambooking.frontend.util.ViewManager;
import javafx.beans.property.SimpleStringProperty;
import javafx.concurrent.Task;
import javafx.fxml.FXML;
import javafx.fxml.Initializable;
import javafx.scene.control.*;
import javafx.scene.text.Text;

import java.io.IOException;
import java.net.URL;
import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.Locale;
import java.util.ResourceBundle;

/**
 * Controlador Senior para la vista de notificaciones del cliente.
 * Muestra el historial de avisos de forma segura y tipada, 
 * utilizando concurrencia gestionada por Task y navegación semántica.
 */
public final class NotificationsController implements Initializable {

    @FXML private Label sidebarUserName;

    @FXML private TableView<AppDTO.NotificationResponse>           notifTable;
    @FXML private TableColumn<AppDTO.NotificationResponse, String> nColFecha;
    @FXML private TableColumn<AppDTO.NotificationResponse, String> nColTipo;
    @FXML private TableColumn<AppDTO.NotificationResponse, String> nColAsunto;
    @FXML private TableColumn<AppDTO.NotificationResponse, String> nColMensaje;

    private static final DateTimeFormatter FMT =
            DateTimeFormatter.ofPattern("dd MMM yyyy HH:mm", new Locale("es", "ES"));

    @Override
    public void initialize(final URL location, final ResourceBundle resources) {
        final SessionManager session = SessionManager.getInstance();
        sidebarUserName.setText(session.getFullName());
        configurarTabla();
        cargarNotificaciones();
    }

    private void configurarTabla() {
        nColFecha.setCellValueFactory(d -> new SimpleStringProperty(
                d.getValue().sentAt != null ? d.getValue().sentAt.format(FMT) : ""));
        nColTipo.setCellValueFactory(d -> new SimpleStringProperty(
                traducirTipo(d.getValue().notificationType)));
        nColAsunto.setCellValueFactory(d -> new SimpleStringProperty(
                d.getValue().subject != null ? d.getValue().subject : ""));
        
        nColMensaje.setCellValueFactory(d -> new SimpleStringProperty(
                d.getValue().message != null ? d.getValue().message : ""));
                
        nColMensaje.setCellFactory(col -> new TableCell<>() {
            private final Text text = new Text();
            {
                text.wrappingWidthProperty().bind(nColMensaje.widthProperty().subtract(10));
                text.setStyle("-fx-font-size: 11px;");
                setGraphic(text);
                setPrefHeight(Control.USE_COMPUTED_SIZE);
            }
            @Override
            protected void updateItem(final String item, final boolean empty) {
                super.updateItem(item, empty);
                text.setText(empty || item == null ? "" : item);
            }
        });
    }

    /**
     * Carga el historial de notificaciones de forma asíncrona mediante un Task,
     * actualizando la tabla y gestionando errores de forma segura en el UI Thread.
     */
    private void cargarNotificaciones() {
        final Long userId = SessionManager.getInstance().getUserId();
        
        final Task<List<AppDTO.NotificationResponse>> loadTask = new Task<>() {
            @Override
            protected List<AppDTO.NotificationResponse> call() throws ApiException {
                return ApiClient.getInstance().getList("/notifications/user/" + userId, AppDTO.NotificationResponse.class);
            }
        };

        loadTask.setOnSucceeded(e -> {
            final List<AppDTO.NotificationResponse> notifs = loadTask.getValue();
            notifTable.getItems().setAll(notifs);
        });

        loadTask.setOnFailed(e -> {
            final Throwable ex = loadTask.getException();
            if (ex instanceof ApiException apiEx) {
                AlertHelper.showError("Error de Carga", "No se pudieron obtener las notificaciones: " + apiEx.getMessage());
            } else {
                AlertHelper.showError("Error Crítico", "Fallo interno al acceder a las notificaciones.");
            }
        });

        final Thread thread = new Thread(loadTask);
        thread.setDaemon(true);
        thread.start();
    }

    // ── Navegación Semántica Desacoplada ───────────────────────

    @FXML private void goToCalendar() { navegarSemantico("Calendario", () -> ViewManager.getInstance().showCalendar()); }
    @FXML private void goToDashboard() { navegarSemantico("Dashboard", () -> ViewManager.getInstance().showMainDashboard()); }
    @FXML private void goToProfile() { navegarSemantico("Perfil", () -> ViewManager.getInstance().showProfile()); }
    
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
            AlertHelper.showError("Error de Redirección", "No se pudo cargar la vista de " + contexto);
        }
    }

    // ── Utilidades ───────────────────────────────────────────────

    private String traducirTipo(final String tipo) {
        if (tipo == null) {
            return "";
        }
        return switch (tipo) {
            case "CREATED"   -> "Creación";
            case "MODIFIED"  -> "Modificación";
            case "CANCELLED" -> "Cancelación";
            case "REMINDER"  -> "Recordatorio";
            default          -> tipo;
        };
    }
}
