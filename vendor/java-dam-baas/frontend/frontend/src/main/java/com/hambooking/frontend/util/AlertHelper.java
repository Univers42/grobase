package com.hambooking.frontend.util;

import javafx.application.Platform;
import javafx.scene.control.Alert;
import javafx.scene.control.ButtonType;

import java.util.Optional;

/**
 * Utilidad estática para gestionar la visualización de diálogos y alertas en JavaFX.
 * Esta clase garantiza la consistencia visual y facilita la comunicación con el usuario.
 * Proporciona métodos seguros para hilos (thread-safe) para alertas informativas.
 */
public final class AlertHelper {

    /**
     * Constructor privado para impedir la instanciación de esta clase utilitaria.
     */
    private AlertHelper() {
        throw new UnsupportedOperationException("Esta es una clase utilitaria y no puede ser instanciada.");
    }

    /**
     * Muestra una alerta informativa. Es seguro llamarlo desde cualquier hilo.
     *
     * @param title   Título de la ventana de diálogo.
     * @param message Mensaje detallado que se mostrará al usuario.
     */
    public static void showInfo(final String title, final String message) {
        runOnFxThread(() -> showAlert(Alert.AlertType.INFORMATION, title, null, message));
    }

    /**
     * Muestra una alerta de error. Es seguro llamarlo desde cualquier hilo.
     * Ideal para notificar fallos de red o errores de validación críticos.
     *
     * @param title   Título descriptivo del error.
     * @param message Explicación del problema para el usuario final.
     */
    public static void showError(final String title, final String message) {
        runOnFxThread(() -> showAlert(Alert.AlertType.ERROR, title, null, message));
    }

    /**
     * Muestra una alerta de advertencia. Es seguro llamarlo desde cualquier hilo.
     *
     * @param title   Título de la advertencia.
     * @param message Motivo por el cual se requiere atención del usuario.
     */
    public static void showWarning(final String title, final String message) {
        runOnFxThread(() -> showAlert(Alert.AlertType.WARNING, title, null, message));
    }

    /**
     * Muestra un diálogo de confirmación bloqueante. 
     * NOTA: Este método debe ser invocado exclusivamente desde el JavaFX Application Thread
     * ya que espera y devuelve un resultado interactivo.
     *
     * @param title   Título del diálogo de confirmación.
     * @param header  Texto de cabecera opcional (puede ser null).
     * @param message Pregunta o acción que el usuario debe confirmar.
     * @return Un {@code Optional<ButtonType>} con la elección del usuario.
     */
    public static Optional<ButtonType> showConfirmation(final String title, final String header, final String message) {
        Alert alert = new Alert(Alert.AlertType.CONFIRMATION);
        alert.setTitle(title);
        alert.setHeaderText(header);
        alert.setContentText(message);
        return alert.showAndWait();
    }

    /**
     * Método interno para construir y mostrar la alerta.
     *
     * @param type    Tipo de alerta.
     * @param title   Título de la ventana.
     * @param header  Encabezado (puede ser null).
     * @param message Contenido del mensaje.
     */
    private static void showAlert(final Alert.AlertType type, final String title, final String header, final String message) {
        Alert alert = new Alert(type);
        alert.setTitle(title);
        alert.setHeaderText(header);
        alert.setContentText(message);
        alert.showAndWait();
    }

    /**
     * Garantiza que la ejecución se realice en el hilo de la interfaz de usuario de JavaFX.
     *
     * @param action Acción a ejecutar.
     */
    private static void runOnFxThread(final Runnable action) {
        if (Platform.isFxApplicationThread()) {
            action.run();
        } else {
            Platform.runLater(action);
        }
    }
}
