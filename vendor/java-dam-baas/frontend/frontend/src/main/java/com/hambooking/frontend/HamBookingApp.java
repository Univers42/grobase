package com.hambooking.frontend;

import com.hambooking.frontend.util.AlertHelper;
import com.hambooking.frontend.util.ViewManager;
import javafx.application.Application;
import javafx.stage.Stage;

import java.io.IOException;

/**
 * Clase principal de la aplicación HamBooking.
 * Configura el escenario inicial y lanza la vista de inicio de sesión de forma semántica.
 */
public class HamBookingApp extends Application {

    @Override
    public void start(final Stage stage) {
        ViewManager.getInstance().setMainStage(stage);

        stage.setMinWidth(900);
        stage.setMinHeight(560);
        stage.setResizable(true);

        try {
            // Uso de navegación semántica: el controlador ya no conoce la ruta FXML
            ViewManager.getInstance().showLogin();
            stage.show();
        } catch (IOException e) {
            AlertHelper.showError("Error de Inicio", "No se pudo cargar la interfaz de usuario inicial.");
            e.printStackTrace();
        }
    }

    public static void main(String[] args) {
        launch(args);
    }
}
