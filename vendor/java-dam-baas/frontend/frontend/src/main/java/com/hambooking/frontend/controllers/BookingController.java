package com.hambooking.frontend.controllers;

import com.hambooking.frontend.SessionManager;
import com.hambooking.frontend.dto.AppDTO;
import com.hambooking.frontend.service.ApiClient;
import com.hambooking.frontend.service.ApiException;
import com.hambooking.frontend.util.AlertHelper;
import com.hambooking.frontend.util.ViewManager;
import javafx.concurrent.Task;
import javafx.fxml.FXML;
import javafx.fxml.Initializable;
import javafx.scene.control.Button;
import javafx.scene.control.Label;
import javafx.scene.control.TextArea;

import java.io.IOException;
import java.net.URL;
import java.time.Duration;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.format.DateTimeFormatter;
import java.util.Locale;
import java.util.ResourceBundle;

/**
 * Controlador Senior para la vista de confirmación de reserva.
 * Gestiona el paso final antes de persistir una cita, mostrando el resumen
 * y controlando de forma segura la concurrencia y la navegación.
 */
public final class BookingController implements Initializable {

    @FXML private Label lblServicio;
    @FXML private Label lblPrecio;
    @FXML private Label lblCortador;
    @FXML private Label lblEspecialidad;
    @FXML private Label lblFecha;
    @FXML private Label lblHora;
    @FXML private TextArea notasField;
    @FXML private Label errorLabel;
    @FXML private Button btnConfirmar;

    // ── Datos inyectados del Slot ─────────────────────────────
    private String servicio;
    private String precio;
    private String cortador;
    private String especialidad;
    private LocalDate fecha;
    private LocalTime horaInicio;
    private LocalTime horaFin;
    private Long cortadorId;
    private Long servicioId;

    private static final DateTimeFormatter FMT_FECHA =
            DateTimeFormatter.ofPattern("EEEE, d 'de' MMMM 'de' yyyy", new Locale("es", "ES"));
    private static final DateTimeFormatter FMT_HORA =
            DateTimeFormatter.ofPattern("HH:mm");

    @Override
    public void initialize(final URL location, final ResourceBundle resources) {
        ocultarError();
        
        // UX: Limpiar mensaje de error si el usuario decide escribir algo nuevo
        notasField.textProperty().addListener((obs, oldV, newV) -> ocultarError());
    }

    /**
     * Inyecta los datos del servicio y horario seleccionado desde el calendario.
     */
    public void initData(final String servicio, final String precio,
                         final String cortador, final String especialidad,
                         final LocalDate fecha, final LocalTime horaInicio, final LocalTime horaFin,
                         final Long cortadorId, final Long servicioId) {
        
        this.servicio = servicio;
        this.precio = precio;
        this.cortador = cortador;
        this.especialidad = especialidad;
        this.fecha = fecha;
        this.horaInicio = horaInicio;
        this.horaFin = horaFin;
        this.cortadorId = cortadorId;
        this.servicioId = servicioId;

        actualizarVistaResumen();
    }

    private void actualizarVistaResumen() {
        lblServicio.setText(servicio);
        lblPrecio.setText(precio);
        lblCortador.setText(cortador);
        lblEspecialidad.setText("Especialidad: " + especialidad);
        lblFecha.setText(fecha.format(FMT_FECHA));
        lblHora.setText("De " + horaInicio.format(FMT_HORA) + " a " + horaFin.format(FMT_HORA)
                + "  (" + calcularDuracion() + ")");
    }

    /**
     * Confirma la reserva mediante una petición asíncrona al servidor.
     */
    @FXML
    private void handleConfirmar() {
        if (servicio == null || cortadorId == null || fecha == null) {
            mostrarError("Faltan datos de la reserva. Por favor, vuelve al calendario.");
            return;
        }

        setLoadingState(true);
        final Task<AppDTO.ReservationResponse> bookingTask = createBookingTask();

        bookingTask.setOnSucceeded(event -> {
            AlertHelper.showInfo("Reserva Confirmada", "Tu cita con " + cortador + " ha sido registrada con éxito.");
            navigateToDashboard();
        });

        bookingTask.setOnFailed(event -> {
            setLoadingState(false);
            gestionarFalloReserva(bookingTask.getException());
        });

        final Thread thread = new Thread(bookingTask);
        thread.setDaemon(true);
        thread.start();
    }

    private Task<AppDTO.ReservationResponse> createBookingTask() {
        final String notas = notasField.getText().trim();
        final Long clientId = SessionManager.getInstance().getUserId();

        final AppDTO.CreateReservationRequest request = new AppDTO.CreateReservationRequest(
                clientId, cortadorId, servicioId,
                fecha, horaInicio,
                notas.isEmpty() ? null : notas
        );

        return new Task<>() {
            @Override
            protected AppDTO.ReservationResponse call() throws ApiException {
                return ApiClient.getInstance().post("/reservations", request, AppDTO.ReservationResponse.class);
            }
        };
    }

    private void gestionarFalloReserva(final Throwable ex) {
        if (ex instanceof ApiException apiEx) {
            if (apiEx.isConflict()) {
                // Caso crítico: El slot acaba de ser reservado por otro usuario o el cliente ya tiene cita
                AlertHelper.showWarning("Reserva No Disponible", 
                    "Lo sentimos, ha habido un problema con la disponibilidad (el horario acaba de ser reservado por otra persona o ya tienes una cita que se solapa). Por favor, selecciona otro hueco.");
                handleCancelar(); // Volvemos al calendario automáticamente
            } else if (apiEx.isConnectionError()) {
                mostrarError("Error de conexión: El servidor no responde.");
            } else {
                mostrarError(apiEx.getMessage());
            }
        } else {
            mostrarError("Ocurrió un fallo inesperado al confirmar la reserva.");
        }
    }

    @FXML
    private void handleCancelar() {
        try {
            ViewManager.getInstance().showCalendar();
        } catch (IOException e) {
            AlertHelper.showError("Error de Navegación", "No se pudo regresar al calendario.");
        }
    }

    private void navigateToDashboard() {
        try {
            ViewManager.getInstance().showMainDashboard();
        } catch (IOException e) {
            AlertHelper.showError("Error de Sistema", "No se pudo cargar el panel principal tras la reserva.");
        }
    }

    private String calcularDuracion() {
        if (horaInicio == null || horaFin == null) {
            return "";
        }
        
        final long minutos = Duration.between(horaInicio, horaFin).toMinutes();
        if (minutos >= 60 && minutos % 60 == 0) {
            final long horas = minutos / 60;
            return horas + " hora" + (horas > 1 ? "s" : "");
        } else if (minutos >= 60) {
            return (minutos / 60) + "h " + (minutos % 60) + "min";
        }
        return minutos + " minutos";
    }

    private void setLoadingState(final boolean loading) {
        btnConfirmar.setDisable(loading);
        btnConfirmar.setText(loading ? "Procesando reserva..." : "Confirmar reserva");
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
