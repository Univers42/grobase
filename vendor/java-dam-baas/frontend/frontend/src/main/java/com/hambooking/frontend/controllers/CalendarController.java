package com.hambooking.frontend.controllers;

import com.hambooking.frontend.SessionManager;
import com.hambooking.frontend.dto.AppDTO;
import com.hambooking.frontend.service.ApiClient;
import com.hambooking.frontend.service.ApiException;
import com.hambooking.frontend.util.AlertHelper;
import com.hambooking.frontend.util.ViewManager;
import javafx.application.Platform;
import javafx.concurrent.Task;
import javafx.fxml.FXML;
import javafx.fxml.FXMLLoader;
import javafx.fxml.Initializable;
import javafx.scene.Parent;
import javafx.scene.control.Button;
import javafx.scene.control.ComboBox;
import javafx.scene.control.DateCell;
import javafx.scene.control.DatePicker;
import javafx.scene.control.Label;
import javafx.scene.layout.GridPane;
import javafx.scene.layout.VBox;
import javafx.stage.Stage;

import java.io.IOException;
import java.net.URL;
import java.time.DayOfWeek;
import java.time.LocalDate;
import java.time.LocalTime;
import java.util.List;
import java.util.ResourceBundle;

/**
 * Controlador Senior para el Calendario de Disponibilidad.
 * Gestiona consultas asíncronas concurrentes, renderizado dinámico de la cuadrícula
 * y enrutamiento seguro hacia la confirmación de reservas.
 */
public final class CalendarController implements Initializable {

    @FXML private ComboBox<String> servicioCombo;
    @FXML private DatePicker fechaPicker;
    @FXML private GridPane calendarGrid;
    @FXML private Label servicioInfoLabel;
    @FXML private Label legendInfoLabel;
    @FXML private Label sidebarUserName;
    @FXML private Label sidebarUserRole;

    private List<AppDTO.ServiceResponse> servicios;
    private List<AppDTO.CarverResponse> cortadores;

    private static final LocalTime HORA_INICIO = LocalTime.of(10, 0);
    private static final LocalTime HORA_FIN = LocalTime.of(18, 0);

    @Override
    public void initialize(final URL location, final ResourceBundle resources) {
        final SessionManager session = SessionManager.getInstance();
        sidebarUserName.setText(session.getFullName());
        sidebarUserRole.setText(session.isAdmin() ? "Administrador" : "Cliente");

        configurarRestriccionesFecha();
        cargarDatosIniciales();
    }

    /**
     * Limita el DatePicker para bloquear fechas pasadas y fines de semana.
     */
    private void configurarRestriccionesFecha() {
        fechaPicker.setValue(LocalDate.now().plusDays(1));
        fechaPicker.setDayCellFactory(picker -> new DateCell() {
            @Override
            public void updateItem(final LocalDate date, final boolean empty) {
                super.updateItem(date, empty);
                final DayOfWeek day = date.getDayOfWeek();
                final boolean deshabilitado = day == DayOfWeek.SATURDAY
                        || day == DayOfWeek.SUNDAY
                        || date.isBefore(LocalDate.now().plusDays(1));
                
                setDisable(deshabilitado);
                if (deshabilitado) {
                    setStyle("-fx-background-color: #F2F3F4;");
                }
            }
        });
    }

    /**
     * Carga el catálogo de servicios y cortadores activos en segundo plano.
     */
    private void cargarDatosIniciales() {
        servicioInfoLabel.setText("Cargando catálogo...");

        final Task<Void> initTask = new Task<>() {
            @Override
            protected Void call() throws ApiException {
                servicios = ApiClient.getInstance().getList("/services", AppDTO.ServiceResponse.class);
                cortadores = ApiClient.getInstance().getList("/carvers/active", AppDTO.CarverResponse.class);
                return null;
            }
        };

        initTask.setOnSucceeded(e -> {
            poblarComboServicios();
            servicioInfoLabel.setText("Catálogo cargado correctamente.");
        });

        initTask.setOnFailed(e -> {
            final Throwable ex = initTask.getException();
            servicioInfoLabel.setText("Error de red: " + ex.getMessage());
            AlertHelper.showError("Error de Carga", "No se pudo conectar con el servidor para obtener los datos.");
        });

        final Thread thread = new Thread(initTask);
        thread.setDaemon(true);
        thread.start();
    }

    private void poblarComboServicios() {
        servicioCombo.getItems().clear();
        for (final AppDTO.ServiceResponse s : servicios) {
            servicioCombo.getItems().add(s.getDisplayName());
        }
        if (!servicioCombo.getItems().isEmpty()) {
            servicioCombo.getSelectionModel().selectFirst();
            actualizarInfoServicio();
        }
        servicioCombo.setOnAction(e -> actualizarInfoServicio());
    }

    /**
     * Inicia la búsqueda de huecos lanzando peticiones concurrentes por cada cortador.
     */
    @FXML
    private void handleBuscarDisponibilidad() {
        final LocalDate fecha = fechaPicker.getValue();
        final int idx = servicioCombo.getSelectionModel().getSelectedIndex();

        if (fecha == null || servicios == null || cortadores == null || idx < 0) {
            return;
        }

        final AppDTO.ServiceResponse servicio = servicios.get(idx);

        if (cortadores.isEmpty()) {
            legendInfoLabel.setText("⚠ No hay cortadores activos en el sistema.");
            return;
        }

        limpiarCuadricula();
        prepararCabecerasCuadricula(servicio);

        // Lanzar consultas concurrentes por cada cortador para máxima velocidad
        for (int col = 0; col < cortadores.size(); col++) {
            consultarDisponibilidadCortador(col, cortadores.get(col), servicio, fecha);
        }
    }

    /**
     * Consulta la API asíncronamente para obtener las horas ocupadas de un cortador.
     */
    private void consultarDisponibilidadCortador(final int col, final AppDTO.CarverResponse carver, 
                                                 final AppDTO.ServiceResponse servicio, final LocalDate fecha) {
        
        final Task<List<LocalTime>> task = new Task<>() {
            @Override
            protected List<LocalTime> call() throws ApiException {
                final String endpoint = "/availability?carverId=" + carver.id
                        + "&date=" + fecha
                        + "&serviceId=" + servicio.id;
                return ApiClient.getInstance().getList(endpoint, LocalTime.class);
            }
        };

        task.setOnSucceeded(e -> {
            final List<LocalTime> horasOcupadas = task.getValue();
            // Asegurar que la manipulación de nodos visuales se hace en el hilo de JavaFX
            Platform.runLater(() -> renderColumnaSlots(col, carver, servicio, horasOcupadas, fecha));
        });

        task.setOnFailed(e -> {
            Platform.runLater(() -> legendInfoLabel.setText(
                    "Error al cargar cortador " + carver.firstName + ": " + task.getException().getMessage()));
        });

        final Thread thread = new Thread(task);
        thread.setDaemon(true);
        thread.start();
    }

    /**
     * Renderiza dinámicamente los botones (slots) para la columna de un cortador.
     */
    private void renderColumnaSlots(final int col, final AppDTO.CarverResponse carver, final AppDTO.ServiceResponse servicio,
                                    final List<LocalTime> horasLibres, final LocalDate fecha) {
        LocalTime slot = HORA_INICIO;
        int row = 1;
        
        while (slot.isBefore(HORA_FIN)) {
            final boolean suficiente = !slot.plusMinutes(servicio.durationMinutes).isAfter(HORA_FIN);
            // La API nos devuelve las horas que ESTÁN LIBRES según el AvailabilityService.
            // Por tanto, está libre si SÍ está en la lista de horas devueltas.
            final boolean libre = horasLibres.contains(slot);

            final LocalTime slotFinal = slot;
            final Button btn = buildSlotButton(suficiente, libre, () ->
                    handleSlotSeleccionado(slotFinal, slotFinal.plusMinutes(servicio.durationMinutes), carver, servicio, fecha)
            );
            calendarGrid.add(btn, col + 1, row);

            slot = slot.plusMinutes(30);
            row++;
        }
    }

    private void prepararCabecerasCuadricula(final AppDTO.ServiceResponse servicio) {
        legendInfoLabel.setText("Cargando disponibilidad...");

        final Label emptyHeader = new Label();
        emptyHeader.setPrefWidth(55);
        calendarGrid.add(emptyHeader, 0, 0);

        for (int col = 0; col < cortadores.size(); col++) {
            calendarGrid.add(buildCarverHeader(cortadores.get(col)), col + 1, 0);
        }

        LocalTime h = HORA_INICIO;
        int r = 1;
        while (h.isBefore(HORA_FIN)) {
            final Label horaLabel = new Label(h.toString());
            horaLabel.getStyleClass().add("calendar-hour-label");
            horaLabel.setPrefWidth(55);
            calendarGrid.add(horaLabel, 0, r);
            h = h.plusMinutes(30);
            r++;
        }

        legendInfoLabel.setText("Servicio seleccionado: " + servicio.name + " | " + servicio.getPrecioStr());
    }

    private void limpiarCuadricula() {
        calendarGrid.getChildren().clear();
        calendarGrid.getColumnConstraints().clear();
        calendarGrid.getRowConstraints().clear();
    }

    /**
     * Intercepta la selección de un slot libre e inyecta los datos en el controlador de reservas.
     */
    private void handleSlotSeleccionado(final LocalTime horaInicio, final LocalTime horaFin,
                                        final AppDTO.CarverResponse carver, final AppDTO.ServiceResponse servicio,
                                        final LocalDate fecha) {
        try {
            final FXMLLoader loader = new FXMLLoader(getClass().getResource("/com/hambooking/frontend/fxml/booking-form.fxml"));
            final Parent root = loader.load();

            final BookingController ctrl = loader.getController();
            ctrl.initData(servicio.name, servicio.getPrecioStr(), carver.getDisplayName(),
                    carver.specialty != null ? carver.specialty : "General",
                    fecha, horaInicio, horaFin, carver.id, servicio.id);

            final Stage stage = ViewManager.getInstance().getMainStage();
            stage.getScene().setRoot(root);
            stage.setTitle("HamBooking - Confirmar Reserva");

        } catch (IOException e) {
            AlertHelper.showError("Error Crítico", "No se pudo inicializar el formulario de reserva.");
            legendInfoLabel.setText("Fallo interno del sistema (UI).");
        }
    }

    // ── Navegación Semántica Desacoplada ───────────────────────

    @FXML private void goToDashboard() { navegarSemantico("Dashboard", () -> ViewManager.getInstance().showMainDashboard()); }
    @FXML private void goToReservations() { navegarSemantico("Reservas", () -> ViewManager.getInstance().showMainDashboard()); }
    @FXML private void goToProfile() { navegarSemantico("Perfil", () -> ViewManager.getInstance().showProfile()); }
    @FXML private void goToNotifications() { navegarSemantico("Notificaciones", () -> ViewManager.getInstance().showNotifications()); }
    
    @FXML private void handleLogout() {
        SessionManager.getInstance().clear();
        navegarSemantico("Login", () -> ViewManager.getInstance().showLogin());
    }

    /** Metodo auxiliar para envolver las llamadas a ViewManager de forma limpia. */
    private void navegarSemantico(final String contexto, final Navegador runnable) {
        try {
            runnable.navegar();
        } catch (IOException e) {
            AlertHelper.showError("Error de Redirección", "No se pudo acceder a la vista: " + contexto);
        }
    }

    /** Interfaz funcional interna para simplificar los bloques try/catch de navegación. */
    @FunctionalInterface
    private interface Navegador {
        void navegar() throws IOException;
    }

    // ── Utilidades de Construcción UI ────────────────────────────

    private VBox buildCarverHeader(final AppDTO.CarverResponse carver) {
        final VBox box = new VBox(2);
        box.getStyleClass().add("calendar-carver-header");
        box.setPrefWidth(140);
        
        final Label nameLabel = new Label(carver.getDisplayName());
        nameLabel.setStyle("-fx-font-weight:bold; -fx-font-size:12px;");
        
        final Label subLabel = new Label(carver.specialty != null ? carver.specialty : "General");
        subLabel.setStyle("-fx-font-size:10px; -fx-text-fill:#9A7B6A;");
        
        box.getChildren().addAll(nameLabel, subLabel);
        return box;
    }

    private Button buildSlotButton(final boolean suficiente, final boolean libre, final Runnable onClick) {
        final Button btn = new Button();
        btn.setPrefWidth(140);
        btn.setPrefHeight(30);

        if (!suficiente) {
            btn.setText("-");
            btn.getStyleClass().add("slot-insufficient");
            btn.setDisable(true);
        } else if (!libre) {
            btn.setText("Ocupado");
            btn.getStyleClass().add("slot-occupied");
            btn.setDisable(true);
        } else {
            btn.setText("Libre");
            btn.getStyleClass().add("slot-available");
            btn.setOnAction(e -> onClick.run());
        }
        return btn;
    }

    private void actualizarInfoServicio() {
        final int idx = servicioCombo.getSelectionModel().getSelectedIndex();
        if (servicios != null && idx >= 0 && idx < servicios.size()) {
            final AppDTO.ServiceResponse s = servicios.get(idx);
            servicioInfoLabel.setText(s.name + " | " + s.getPrecioStr());
        }
    }
}
