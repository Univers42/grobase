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
import javafx.scene.layout.VBox;
import javafx.util.Callback;

import java.io.IOException;
import java.net.URL;
import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.ResourceBundle;

/**
 * Controlador Senior para el panel de administración.
 * Centraliza la gestión global de cortadores, usuarios, reservas y notificaciones.
 * Refactorizado para seguridad de tipos, inmutabilidad y concurrencia segura.
 */
public final class AdminDashboardController implements Initializable {

    // ── Sidebar ──────────────────────────────────────────────────────────
    @FXML private Label sidebarUserName;

    // ── Cabecera y Controles Globales ────────────────────────────────────
    @FXML private Label pageTitle;
    @FXML private Label pageBreadcrumb;
    @FXML private TextField searchField;
    @FXML private Button btnNuevo;

    // ── KPIs (Indicadores Clave) ─────────────────────────────────────────
    @FXML private Label kpiCortadores;
    @FXML private Label kpiReservasHoy;
    @FXML private Label kpiClientes;
    @FXML private Label kpiPendientes;

    // ── TabPane y Secciones ──────────────────────────────────────────────
    @FXML private TabPane mainTabPane;
    @FXML private Tab tabCortadores;
    @FXML private Tab tabUsuarios;
    @FXML private Tab tabReservas;
    @FXML private Tab tabNotificaciones;
    @FXML private Tab tabEstadisticas;

    // ── Tabla de Cortadores ──────────────────────────────────────────────
    @FXML private TableView<AppDTO.CarverResponse>           cortadoresTable;
    @FXML private TableColumn<AppDTO.CarverResponse, String> cColNombre;
    @FXML private TableColumn<AppDTO.CarverResponse, String> cColDni;
    @FXML private TableColumn<AppDTO.CarverResponse, String> cColEmail;
    @FXML private TableColumn<AppDTO.CarverResponse, String> cColEspecialidad;
    @FXML private TableColumn<AppDTO.CarverResponse, String> cColExperiencia;
    @FXML private TableColumn<AppDTO.CarverResponse, String> cColEstado;
    @FXML private TableColumn<AppDTO.CarverResponse, String> cColAcciones;

    // ── Tabla de Usuarios ────────────────────────────────────────────────
    @FXML private TableView<AppDTO.UserResponse>           usuariosTable;
    @FXML private TableColumn<AppDTO.UserResponse, String> uColNombre;
    @FXML private TableColumn<AppDTO.UserResponse, String> uColDni;
    @FXML private TableColumn<AppDTO.UserResponse, String> uColEmail;
    @FXML private TableColumn<AppDTO.UserResponse, String> uColTelefono;
    @FXML private TableColumn<AppDTO.UserResponse, String> uColEstado;
    @FXML private TableColumn<AppDTO.UserResponse, String> uColAcciones;

    // ── Tabla de Reservas ────────────────────────────────────────────────
    @FXML private TableView<AppDTO.ReservationResponse>           reservasTable;
    @FXML private TableColumn<AppDTO.ReservationResponse, String> rColFecha;
    @FXML private TableColumn<AppDTO.ReservationResponse, String> rColCliente;
    @FXML private TableColumn<AppDTO.ReservationResponse, String> rColCortador;
    @FXML private TableColumn<AppDTO.ReservationResponse, String> rColServicio;
    @FXML private TableColumn<AppDTO.ReservationResponse, String> rColHora;
    @FXML private TableColumn<AppDTO.ReservationResponse, String> rColEstado;
    @FXML private TableColumn<AppDTO.ReservationResponse, String> rColAcciones;

    // ── Tabla de Notificaciones ──────────────────────────────────────────
    @FXML private TableView<AppDTO.NotificationResponse>           notificacionesTable;
    @FXML private TableColumn<AppDTO.NotificationResponse, String> nColFecha;
    @FXML private TableColumn<AppDTO.NotificationResponse, String> nColDestinatario;
    @FXML private TableColumn<AppDTO.NotificationResponse, String> nColTipo;
    @FXML private TableColumn<AppDTO.NotificationResponse, String> nColAsunto;

    private static final DateTimeFormatter FMT_DATETIME =
            DateTimeFormatter.ofPattern("dd MMM yyyy HH:mm", new Locale("es", "ES"));
    private static final DateTimeFormatter FMT_FECHA =
            DateTimeFormatter.ofPattern("dd MMM yyyy", new Locale("es", "ES"));

    /**
     * Registro interno (Data Transfer Object local) para encapsular la carga masiva
     * y eliminar las advertencias de compilador (unchecked casts) de Object[].
     */
    private record DashboardData(
            List<AppDTO.CarverResponse> cortadores,
            List<AppDTO.UserResponse> usuarios,
            List<AppDTO.ReservationResponse> reservas,
            List<AppDTO.NotificationResponse> notificaciones
    ) {}

    @Override
    public void initialize(final URL location, final ResourceBundle resources) {
        sidebarUserName.setText(SessionManager.getInstance().getFullName());
        
        configurarTablaCortadores();
        configurarTablaUsuarios();
        configurarTablaReservas();
        configurarTablaNotificaciones();
        
        cargarDatos();
    }

    // ── Región: Configuración de Columnas ────────────────────────────────

    private void configurarTablaCortadores() {
        cColNombre.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().firstName + " " + d.getValue().lastName));
        cColDni.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().dni != null ? d.getValue().dni : ""));
        cColEmail.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().email != null ? d.getValue().email : ""));
        cColEspecialidad.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().specialty != null ? d.getValue().specialty : "-"));
        cColExperiencia.setCellValueFactory(d -> new SimpleStringProperty(
                d.getValue().experienceYears != null ? d.getValue().experienceYears + " años" : "0 años"));
        cColEstado.setCellValueFactory(d -> new SimpleStringProperty(Boolean.TRUE.equals(d.getValue().isActive) ? "Activo" : "Inactivo"));
        cColAcciones.setCellFactory(accionesCortadoresFactory());
    }

    private void configurarTablaUsuarios() {
        uColNombre.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().firstName + " " + d.getValue().lastName));
        uColDni.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().dni != null ? d.getValue().dni : ""));
        uColEmail.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().email != null ? d.getValue().email : ""));
        uColTelefono.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().phone != null ? d.getValue().phone : ""));
        uColEstado.setCellValueFactory(d -> new SimpleStringProperty(Boolean.TRUE.equals(d.getValue().isActive) ? "Activo" : "Inactivo"));
        uColAcciones.setCellFactory(accionesUsuariosFactory());
    }

    private void configurarTablaReservas() {
        rColFecha.setCellValueFactory(d -> new SimpleStringProperty(
                d.getValue().reservationDate != null ? d.getValue().reservationDate.format(FMT_FECHA) : ""));
        rColCliente.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().getClientFullName()));
        rColCortador.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().getCarverFullName()));
        rColServicio.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().serviceName != null ? d.getValue().serviceName : ""));
        rColHora.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().getHoraStr()));
        rColEstado.setCellValueFactory(d -> new SimpleStringProperty(traducirEstado(d.getValue().status)));
        rColAcciones.setCellFactory(accionesReservasFactory());
    }

    private void configurarTablaNotificaciones() {
        nColFecha.setCellValueFactory(d -> new SimpleStringProperty(
                d.getValue().sentAt != null ? d.getValue().sentAt.format(FMT_DATETIME) : ""));
        nColDestinatario.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().recipientEmail != null ? d.getValue().recipientEmail : ""));
        nColTipo.setCellValueFactory(d -> new SimpleStringProperty(traducirTipoNotif(d.getValue().notificationType)));
        nColAsunto.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().subject != null ? d.getValue().subject : ""));
    }

    // ── Región: Factorías de Celdas (Botones) ────────────────────────────

    private Callback<TableColumn<AppDTO.CarverResponse, String>, TableCell<AppDTO.CarverResponse, String>> accionesCortadoresFactory() {
        return col -> new TableCell<>() {
            private final Button btnEditar = new Button("Editar");
            private final Button btnToggle = new Button();
            private final HBox box = new HBox(6, btnEditar, btnToggle);
            {
                box.setPadding(new Insets(2, 0, 2, 0));
                btnEditar.setStyle("-fx-font-size:11px; -fx-padding:3 8 3 8;");
                btnEditar.setOnAction(e -> ejecutarEdicionCortador(getTableView().getItems().get(getIndex())));
                btnToggle.setOnAction(e -> {
                    final AppDTO.CarverResponse c = getTableView().getItems().get(getIndex());
                    if (Boolean.TRUE.equals(c.isActive)) {
                        ejecutarDesactivacionCortador(c);
                    } else {
                        ejecutarActivacionCortador(c);
                    }
                });
            }
            @Override protected void updateItem(final String item, final boolean empty) {
                super.updateItem(item, empty);
                if (empty || getIndex() < 0) { setGraphic(null); return; }
                final AppDTO.CarverResponse c = getTableView().getItems().get(getIndex());
                final boolean activo = Boolean.TRUE.equals(c.isActive);
                btnToggle.setText(activo ? "Desactivar" : "Activar");
                btnToggle.setStyle(activo ? "-fx-background-color:#e74c3c; -fx-text-fill:white; -fx-font-size:11px;" : "-fx-background-color:#27ae60; -fx-text-fill:white; -fx-font-size:11px;");
                setGraphic(box);
            }
        };
    }

    private Callback<TableColumn<AppDTO.UserResponse, String>, TableCell<AppDTO.UserResponse, String>> accionesUsuariosFactory() {
        return col -> new TableCell<>() {
            private final Button btnToggle = new Button();
            private final HBox box = new HBox(6, btnToggle);
            {
                box.setPadding(new Insets(2, 0, 2, 0));
                btnToggle.setOnAction(e -> ejecutarToggleUsuario(getTableView().getItems().get(getIndex())));
            }
            @Override protected void updateItem(final String item, final boolean empty) {
                super.updateItem(item, empty);
                if (empty || getIndex() < 0) { setGraphic(null); return; }
                final boolean activo = Boolean.TRUE.equals(getTableView().getItems().get(getIndex()).isActive);
                btnToggle.setText(activo ? "Desactivar" : "Activar");
                btnToggle.setStyle(activo ? "-fx-background-color:#e74c3c; -fx-text-fill:white; -fx-font-size:11px;" : "-fx-background-color:#27ae60; -fx-text-fill:white; -fx-font-size:11px;");
                setGraphic(box);
            }
        };
    }

    private Callback<TableColumn<AppDTO.ReservationResponse, String>, TableCell<AppDTO.ReservationResponse, String>> accionesReservasFactory() {
        return col -> new TableCell<>() {
            private final Button btnConfirmar = new Button("Confirmar");
            private final Button btnCancelar  = new Button("Cancelar");
            private final HBox box = new HBox(6, btnConfirmar, btnCancelar);
            {
                box.setPadding(new Insets(2, 0, 2, 0));
                btnConfirmar.setStyle("-fx-background-color:#27ae60; -fx-text-fill:white; -fx-font-size:11px;");
                btnCancelar.setStyle("-fx-background-color:#e74c3c; -fx-text-fill:white; -fx-font-size:11px;");
                btnConfirmar.setOnAction(e -> ejecutarConfirmacionReserva(getTableView().getItems().get(getIndex())));
                btnCancelar.setOnAction(e -> ejecutarCancelacionReserva(getTableView().getItems().get(getIndex())));
            }
            @Override protected void updateItem(final String item, final boolean empty) {
                super.updateItem(item, empty);
                if (empty || getIndex() < 0) { setGraphic(null); return; }
                final AppDTO.ReservationResponse r = getTableView().getItems().get(getIndex());
                if (r.reservationDate != null && r.reservationDate.isBefore(LocalDate.now())) { setGraphic(null); return; }
                
                final boolean isPending = "PENDING".equals(r.status);
                btnConfirmar.setVisible(isPending);
                btnConfirmar.setManaged(isPending);
                
                final boolean cancelable = isPending || "CONFIRMED".equals(r.status);
                btnCancelar.setVisible(cancelable);
                btnCancelar.setManaged(cancelable);
                setGraphic(box);
            }
        };
    }

    // ── Región: Lógica de Acciones (Cortadores) ──────────────────────────

    private void ejecutarEdicionCortador(final AppDTO.CarverResponse carver) {
        final Dialog<ButtonType> dialog = new Dialog<>();
        dialog.setTitle("Editar cortador");
        dialog.setHeaderText(carver.firstName + " " + carver.lastName);

        final TextField tfEspecialidad = new TextField(carver.specialty != null ? carver.specialty : "");
        final TextField tfExperiencia  = new TextField(String.valueOf(carver.experienceYears != null ? carver.experienceYears : 0));
        final TextField tfMaxJamones   = new TextField(String.valueOf(carver.maxHamsPerDay != null ? carver.maxHamsPerDay : 3));

        final VBox content = new VBox(8, new Label("Especialidad:"), tfEspecialidad, 
                                   new Label("Años de experiencia:"), tfExperiencia, 
                                   new Label("Máx. jamones por día:"), tfMaxJamones);
        content.setPadding(new Insets(16));
        dialog.getDialogPane().setContent(content);
        dialog.getDialogPane().getButtonTypes().addAll(ButtonType.OK, ButtonType.CANCEL);

        dialog.showAndWait().ifPresent(btn -> {
            if (btn == ButtonType.OK) {
                try {
                    final int exp = Integer.parseInt(tfExperiencia.getText().trim());
                    final int max = Integer.parseInt(tfMaxJamones.getText().trim());
                    
                    final Map<String, Object> body = new LinkedHashMap<>();
                    body.put("specialty", tfEspecialidad.getText().trim());
                    body.put("experienceYears", exp);
                    body.put("maxHamsPerDay", max);

                    final Task<Void> task = new Task<>() {
                        @Override protected Void call() throws ApiException {
                            ApiClient.getInstance().put("/carvers/" + carver.id, body);
                            return null;
                        }
                    };
                    
                    task.setOnSucceeded(e -> { AlertHelper.showInfo("Éxito", "Cortador actualizado."); cargarDatos(); });
                    task.setOnFailed(e -> gestionarFalloAPI("Error al actualizar cortador", task.getException()));
                    new Thread(task).start();

                } catch (NumberFormatException ex) {
                    AlertHelper.showWarning("Datos inválidos", "Introduce números válidos en los campos numéricos.");
                }
            }
        });
    }

    private void ejecutarDesactivacionCortador(final AppDTO.CarverResponse carver) {
        AlertHelper.showConfirmation("Desactivar cortador", "¿Desactivar a " + carver.firstName + " " + carver.lastName + "?",
                "El cortador no aparecerá disponible para nuevas reservas.")
        .ifPresent(btn -> {
            if (btn == ButtonType.OK) {
                lanzarTareaPatch("/carvers/" + carver.id + "/deactivate", "Cortador desactivado.");
            }
        });
    }

    private void ejecutarActivacionCortador(final AppDTO.CarverResponse carver) {
        lanzarTareaPatch("/carvers/" + carver.id + "/activate", "Cortador activado.");
    }

    // ── Región: Lógica de Acciones (Usuarios y Reservas) ─────────────────

    private void ejecutarToggleUsuario(final AppDTO.UserResponse user) {
        final boolean activar = !Boolean.TRUE.equals(user.isActive);
        AlertHelper.showConfirmation((activar ? "Activar" : "Desactivar") + " usuario",
                "¿Deseas " + (activar ? "activar" : "desactivar") + " a " + user.firstName + " " + user.lastName + "?", null)
        .ifPresent(btn -> {
            if (btn == ButtonType.OK) {
                final String endpoint = "/users/" + user.id + (activar ? "/activate" : "/deactivate");
                lanzarTareaPatch(endpoint, "Usuario " + (activar ? "activado" : "desactivado") + ".");
            }
        });
    }

    private void ejecutarConfirmacionReserva(final AppDTO.ReservationResponse reserva) {
        AlertHelper.showConfirmation("Confirmar reserva", "¿Confirmar la reserva de " + reserva.getClientFullName() + "?",
                "Servicio: " + reserva.serviceName + "\nFecha: " + formatFecha(reserva.reservationDate))
        .ifPresent(btn -> {
            if (btn == ButtonType.OK) {
                lanzarTareaPatch("/reservations/" + reserva.id + "/confirm", "Reserva confirmada.");
            }
        });
    }

    private void ejecutarCancelacionReserva(final AppDTO.ReservationResponse reserva) {
        AlertHelper.showConfirmation("Cancelar reserva", "¿Cancelar la reserva de " + reserva.getClientFullName() + "?",
                "Esta acción no se puede deshacer.")
        .ifPresent(btn -> {
            if (btn == ButtonType.OK) {
                lanzarTareaPatch("/reservations/" + reserva.id + "/cancel", "Reserva cancelada.");
            }
        });
    }

    private void lanzarTareaPatch(final String endpoint, final String successMsg) {
        final Task<Void> task = new Task<>() {
            @Override protected Void call() throws ApiException {
                ApiClient.getInstance().patch(endpoint);
                return null;
            }
        };
        task.setOnSucceeded(e -> { AlertHelper.showInfo("Éxito", successMsg); cargarReservasIndependiente(); });
        task.setOnFailed(e -> gestionarFalloAPI("Operación fallida", task.getException()));
        new Thread(task).start();
    }

    private void gestionarFalloAPI(final String titulo, final Throwable ex) {
        if (ex instanceof ApiException apiEx) {
            AlertHelper.showError(titulo, apiEx.getMessage());
        } else {
            AlertHelper.showError("Error Crítico", "Ocurrió un error inesperado al conectar con el servidor.");
        }
    }

    // ── Región: Carga de Datos ───────────────────────────────────────────

    private void cargarDatos() {
        final Task<DashboardData> loadTask = new Task<>() {
            @Override protected DashboardData call() throws ApiException {
                final ApiClient api = ApiClient.getInstance();
                return new DashboardData(
                    api.getList("/carvers", AppDTO.CarverResponse.class),
                    api.getList("/users", AppDTO.UserResponse.class),
                    api.getList("/reservations", AppDTO.ReservationResponse.class),
                    api.getList("/notifications", AppDTO.NotificationResponse.class)
                );
            }
        };

        loadTask.setOnSucceeded(e -> procesarCargaMasiva(loadTask.getValue()));
        loadTask.setOnFailed(e -> {
            final Throwable ex = loadTask.getException();
            if (ex instanceof ApiException apiEx) {
                pageTitle.setText("Error de red: " + apiEx.getMessage());
                AlertHelper.showError("Fallo de Carga", "No se pudieron obtener los datos: " + apiEx.getMessage());
            } else {
                pageTitle.setText("Fallo interno del sistema.");
            }
        });

        final Thread thread = new Thread(loadTask);
        thread.setDaemon(true);
        thread.start();
    }

    private void cargarReservasIndependiente() {
        cargarDatos(); // Reutiliza la carga masiva para asegurar consistencia
    }

    private void procesarCargaMasiva(final DashboardData data) {
        cortadoresTable.getItems().setAll(data.cortadores);
        usuariosTable.getItems().setAll(data.usuarios.stream().filter(u -> !"ADMIN".equals(u.role)).toList());
        reservasTable.getItems().setAll(data.reservas);
        notificacionesTable.getItems().setAll(data.notificaciones);

        actualizarKPIs(data.cortadores, data.usuarios, data.reservas);
    }

    private void actualizarKPIs(final List<AppDTO.CarverResponse> c, final List<AppDTO.UserResponse> u, final List<AppDTO.ReservationResponse> r) {
        final long activos    = c.stream().filter(carver -> Boolean.TRUE.equals(carver.isActive)).count();
        final long clientes   = u.stream().filter(user -> "CLIENT".equals(user.role)).count();
        final long hoy        = r.stream().filter(res -> res.reservationDate != null && res.reservationDate.equals(LocalDate.now())).count();
        final long pendientes = r.stream().filter(res -> "PENDING".equals(res.status)).count();

        kpiCortadores.setText(String.valueOf(activos));
        kpiClientes.setText(String.valueOf(clientes));
        kpiReservasHoy.setText(String.valueOf(hoy));
        kpiPendientes.setText(String.valueOf(pendientes));
    }

    // ── Región: Navegación y Pestañas ────────────────────────────────────

    @FXML private void showTabCortadores() { selectTab(tabCortadores, "Gestión de Cortadores", "Inicio · Cortadores"); }
    @FXML private void showTabUsuarios()   { selectTab(tabUsuarios, "Gestión de Usuarios", "Inicio · Usuarios"); }
    @FXML private void showTabReservas()   { selectTab(tabReservas, "Todas las Reservas", "Inicio · Reservas"); }
    @FXML private void showTabNotificaciones() { selectTab(tabNotificaciones, "Notificaciones", "Inicio · Notificaciones"); }
    @FXML private void showTabEstadisticas()   { selectTab(tabEstadisticas, "Estadísticas", "Inicio · Estadísticas"); }

    private void selectTab(final Tab tab, final String title, final String breadcrumb) {
        mainTabPane.getSelectionModel().select(tab);
        pageTitle.setText(title);
        pageBreadcrumb.setText(breadcrumb);
    }

    @FXML private void handleNuevo() {
        if (mainTabPane.getSelectionModel().getSelectedItem() == tabCortadores) {
            ejecutarNuevoCortador();
        }
    }

    private void ejecutarNuevoCortador() {
        final List<Long> idsYaCortadores = cortadoresTable.getItems().stream().map(c -> c.userId).toList();
        final List<AppDTO.UserResponse> disponibles = usuariosTable.getItems().stream()
                .filter(u -> !idsYaCortadores.contains(u.id) && Boolean.TRUE.equals(u.isActive)).toList();

        if (disponibles.isEmpty()) {
            AlertHelper.showInfo("Sin usuarios", "Todos los usuarios activos ya son cortadores.");
            return;
        }

        final Dialog<ButtonType> dialog = new Dialog<>();
        dialog.setTitle("Nuevo cortador");
        
        final ComboBox<AppDTO.UserResponse> cbUser = new ComboBox<>();
        cbUser.getItems().addAll(disponibles);
        cbUser.setPrefWidth(300);
        
        final VBox content = new VBox(8, new Label("Selecciona Usuario:"), cbUser);
        content.setPadding(new Insets(16));
        dialog.getDialogPane().setContent(content);
        dialog.getDialogPane().getButtonTypes().addAll(ButtonType.OK, ButtonType.CANCEL);

        dialog.showAndWait().ifPresent(btn -> {
            if (btn == ButtonType.OK && cbUser.getValue() != null) {
                final Task<Void> task = new Task<>() {
                    @Override protected Void call() throws ApiException {
                        final Map<String, Object> b = new LinkedHashMap<>();
                        b.put("userId", cbUser.getValue().id);
                        b.put("specialty", "General");
                        b.put("experienceYears", 0);
                        b.put("maxHamsPerDay", 3);
                        ApiClient.getInstance().post("/carvers", b, AppDTO.CarverResponse.class);
                        return null;
                    }
                };
                task.setOnSucceeded(e -> { AlertHelper.showInfo("Éxito", "Cortador creado."); cargarDatos(); });
                task.setOnFailed(e -> gestionarFalloAPI("Error de creación", task.getException()));
                new Thread(task).start();
            }
        });
    }

    @FXML private void handleLogout() {
        SessionManager.getInstance().clear();
        try {
            ViewManager.getInstance().showLogin();
        } catch (IOException e) {
            AlertHelper.showError("Error de Sistema", "No se pudo volver a la pantalla de inicio de sesión.");
        }
    }

    // ── Región: Utilidades ───────────────────────────────────────────────

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

    private String traducirTipoNotif(final String tipo) {
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

    private String formatFecha(final LocalDate date) { 
        return date != null ? date.format(FMT_FECHA) : ""; 
    }
}
