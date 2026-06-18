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
import javafx.geometry.Insets;
import javafx.scene.control.*;
import javafx.scene.layout.HBox;
import javafx.util.Callback;

import java.io.IOException;
import java.net.URL;
import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.Locale;
import java.util.ResourceBundle;
import java.util.stream.Collectors;

/**
 * Controlador Senior para el panel principal del cliente (Dashboard).
 * Gestiona de forma asíncrona y segura la visualización de reservas, 
 * historial, KPIs y la lógica de cancelación de citas.
 */
public final class ClientDashboard implements Initializable {

    // ── Sidebar ──────────────────────────────────────────────────
    @FXML private Label sidebarUserName;
    @FXML private Label sidebarUserRole;

    // ── Cabecera ─────────────────────────────────────────────────
    @FXML private Label fechaHoyLabel;

    // ── KPIs ─────────────────────────────────────────────────────
    @FXML private Label kpiSemana;
    @FXML private Label kpiCupoHoy;
    @FXML private Label kpiRealizadas;

    // ── Tabla próximas ───────────────────────────────────────────
    @FXML private TableView<AppDTO.ReservationResponse> proximasTable;
    @FXML private TableColumn<AppDTO.ReservationResponse, String> colFecha;
    @FXML private TableColumn<AppDTO.ReservationResponse, String> colServicio;
    @FXML private TableColumn<AppDTO.ReservationResponse, String> colCortador;
    @FXML private TableColumn<AppDTO.ReservationResponse, String> colHora;
    @FXML private TableColumn<AppDTO.ReservationResponse, String> colEstado;
    @FXML private TableColumn<AppDTO.ReservationResponse, String> colAcciones;

    // ── Tabla historial ──────────────────────────────────────────
    @FXML private TableView<AppDTO.ReservationResponse> historialTable;
    @FXML private TableColumn<AppDTO.ReservationResponse, String> hColFecha;
    @FXML private TableColumn<AppDTO.ReservationResponse, String> hColServicio;
    @FXML private TableColumn<AppDTO.ReservationResponse, String> hColCortador;
    @FXML private TableColumn<AppDTO.ReservationResponse, String> hColHora;
    @FXML private TableColumn<AppDTO.ReservationResponse, String> hColEstado;

    private static final DateTimeFormatter FMT_FECHA =
            DateTimeFormatter.ofPattern("dd MMM yyyy", new Locale("es", "ES"));

    @Override
    public void initialize(final URL location, final ResourceBundle resources) {
        final SessionManager session = SessionManager.getInstance();
        sidebarUserName.setText(session.getFullName());
        sidebarUserRole.setText("Cliente");

        final String fechaHoy = LocalDate.now().format(
                DateTimeFormatter.ofPattern("EEEE, d 'de' MMMM 'de' yyyy", new Locale("es", "ES")));
        fechaHoyLabel.setText("Hoy es " + fechaHoy);

        configurarTablaProximas();
        configurarTablaHistorial();
        cargarReservas();
    }

    // ── Configuración de tablas ──────────────────────────────────

    private void configurarTablaProximas() {
        colFecha.setCellValueFactory(d -> new SimpleStringProperty(formatFecha(d.getValue().reservationDate)));
        colServicio.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().serviceName != null ? d.getValue().serviceName : ""));
        colCortador.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().getCarverFullName()));
        colHora.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().getHoraStr()));
        colEstado.setCellValueFactory(d -> new SimpleStringProperty(traducirEstado(d.getValue().status)));
        colAcciones.setCellFactory(accionesFactory());
    }

    private void configurarTablaHistorial() {
        hColFecha.setCellValueFactory(d -> new SimpleStringProperty(formatFecha(d.getValue().reservationDate)));
        hColServicio.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().serviceName != null ? d.getValue().serviceName : ""));
        hColCortador.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().getCarverFullName()));
        hColHora.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().getHoraStr()));
        hColEstado.setCellValueFactory(d -> new SimpleStringProperty(traducirEstado(d.getValue().status)));
    }

    /**
     * Factoría para inyectar el botón de cancelación en las reservas activas.
     */
    private Callback<TableColumn<AppDTO.ReservationResponse, String>,
            TableCell<AppDTO.ReservationResponse, String>> accionesFactory() {

        return col -> new TableCell<>() {
            private final Button btnCancelar = new Button("Cancelar");
            private final HBox box = new HBox(6, btnCancelar);

            {
                box.setPadding(new Insets(2, 0, 2, 0));
                // TODO: En el futuro, mover este estilo a hambooking.css como .button-danger-small
                btnCancelar.setStyle("-fx-font-size:11px; -fx-padding:3 8 3 8; -fx-background-color:#e74c3c; -fx-text-fill:white;");
                btnCancelar.setOnAction(e -> {
                    final AppDTO.ReservationResponse r = getTableView().getItems().get(getIndex());
                    if (r != null) {
                        solicitarCancelacionReserva(r);
                    }
                });
            }

            @Override
            protected void updateItem(final String item, final boolean empty) {
                super.updateItem(item, empty);
                if (empty || getIndex() < 0 || getIndex() >= getTableView().getItems().size()) {
                    setGraphic(null);
                    return;
                }
                
                final AppDTO.ReservationResponse r = getTableView().getItems().get(getIndex());
                // Lógica de negocio: Solo cancelar PENDING o CONFIRMED en fechas futuras o de hoy
                final boolean cancelable = ("PENDING".equals(r.status) || "CONFIRMED".equals(r.status))
                        && r.reservationDate != null && !r.reservationDate.isBefore(LocalDate.now());
                
                setGraphic(cancelable ? box : null);
            }
        };
    }

    // ── Lógica de negocio (Concurrencia) ─────────────────────────

    private void solicitarCancelacionReserva(final AppDTO.ReservationResponse reserva) {
        AlertHelper.showConfirmation("Cancelar reserva",
                "¿Estás seguro de cancelar tu reserva de " + reserva.serviceName + "?",
                "Fecha: " + formatFecha(reserva.reservationDate) + "\nHora: " + reserva.getHoraStr() + "\n\nEsta acción no se puede deshacer.")
        .ifPresent(btn -> {
            if (btn == ButtonType.OK) {
                ejecutarTareaCancelacion(reserva.id);
            }
        });
    }

    private void ejecutarTareaCancelacion(final Long reservationId) {
        final Task<Void> cancelTask = new Task<>() {
            @Override
            protected Void call() throws ApiException {
                ApiClient.getInstance().patch("/reservations/" + reservationId + "/cancel");
                return null;
            }
        };

        cancelTask.setOnSucceeded(e -> {
            AlertHelper.showInfo("Éxito", "La reserva ha sido cancelada correctamente.");
            cargarReservas(); // Refrescar los datos tras la cancelación
        });

        cancelTask.setOnFailed(e -> {
            final Throwable ex = cancelTask.getException();
            if (ex instanceof ApiException apiEx) {
                AlertHelper.showError("No se pudo cancelar", apiEx.getMessage());
            } else {
                AlertHelper.showError("Error de Sistema", "Ocurrió un fallo inesperado al cancelar la reserva.");
            }
        });

        final Thread thread = new Thread(cancelTask);
        thread.setDaemon(true);
        thread.start();
    }

    private void cargarReservas() {
        final Long clientId = SessionManager.getInstance().getUserId();

        final Task<List<AppDTO.ReservationResponse>> loadTask = new Task<>() {
            @Override
            protected List<AppDTO.ReservationResponse> call() throws ApiException {
                return ApiClient.getInstance().getList("/reservations/client/" + clientId, AppDTO.ReservationResponse.class);
            }
        };

        // setOnSucceeded se ejecuta de forma segura en el JavaFX Application Thread
        loadTask.setOnSucceeded(e -> procesarDatosReservas(loadTask.getValue()));
        
        loadTask.setOnFailed(e -> {
            final Throwable ex = loadTask.getException();
            if (ex instanceof ApiException apiEx) {
                fechaHoyLabel.setText("Error de red al cargar las reservas.");
                AlertHelper.showError("Error de Conexión", apiEx.getMessage());
            } else {
                fechaHoyLabel.setText("Fallo crítico al acceder a los datos.");
            }
        });

        final Thread thread = new Thread(loadTask);
        thread.setDaemon(true);
        thread.start();
    }

    private void procesarDatosReservas(final List<AppDTO.ReservationResponse> todas) {
        final LocalDate hoy = LocalDate.now();

        final List<AppDTO.ReservationResponse> proximas = todas.stream()
                .filter(r -> r.reservationDate != null && !r.reservationDate.isBefore(hoy)
                        && !"CANCELLED".equals(r.status) && !"COMPLETED".equals(r.status))
                .collect(Collectors.toList());

        final List<AppDTO.ReservationResponse> historial = todas.stream()
                .filter(r -> r.reservationDate != null && (r.reservationDate.isBefore(hoy)
                        || "CANCELLED".equals(r.status) || "COMPLETED".equals(r.status)))
                .collect(Collectors.toList());

        final long semana = proximas.stream().filter(r -> !r.reservationDate.isAfter(hoy.plusDays(6))).count();
        final long hoyCount = proximas.stream().filter(r -> r.reservationDate.equals(hoy)).count();
        final long realizadas = todas.stream().filter(r -> "COMPLETED".equals(r.status)).count();

        proximasTable.getItems().setAll(proximas);
        historialTable.getItems().setAll(historial);
        kpiSemana.setText(String.valueOf(semana));
        kpiCupoHoy.setText(hoyCount + " / 2");
        kpiRealizadas.setText(String.valueOf(realizadas));
    }

    // ── Navegación Semántica Desacoplada ───────────────────────

    @FXML private void goToCalendar() { navegarSemantico("Calendario", () -> ViewManager.getInstance().showCalendar()); }
    
    @FXML private void goToReservations() { 
        historialTable.requestFocus(); 
        historialTable.scrollTo(0); 
    }
    
    @FXML private void goToProfile() { navegarSemantico("Perfil", () -> ViewManager.getInstance().showProfile()); }
    
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

    /** Metodo auxiliar para envolver las llamadas a ViewManager de forma limpia. */
    private void navegarSemantico(final String contexto, final Navegador runnable) {
        try {
            runnable.navegar();
        } catch (IOException e) {
            AlertHelper.showError("Error de Redirección", "No se pudo acceder a la vista: " + contexto);
        }
    }

    // ── Utilidades de Presentación ───────────────────────────────

    private String traducirEstado(final String status) {
        if (status == null) {
            return "";
        }
        return switch (status) {
            case "PENDING"   -> "Pendiente";
            case "CONFIRMED" -> "Confirmada";
            case "COMPLETED" -> "Realizada";
            case "CANCELLED" -> "Cancelada";
            default          -> status;
        };
    }

    private String formatFecha(final LocalDate date) {
        return date != null ? date.format(FMT_FECHA) : "";
    }
}
