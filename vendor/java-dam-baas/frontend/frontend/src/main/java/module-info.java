module com.hambooking.frontend {
    requires javafx.controls;
    requires javafx.fxml;
    requires javafx.graphics;

    requires org.controlsfx.controls;
    requires com.fasterxml.jackson.databind;
    requires com.fasterxml.jackson.datatype.jsr310;

    // Necesario para HttpClient (ApiClient.java)
    requires java.net.http;

    // Jackson necesita acceso para serializar/deserializar los DTOs
    opens com.hambooking.frontend.dto to com.fasterxml.jackson.databind;

    // javafx.fxml necesita acceso por reflexion para cargar controladores
    opens com.hambooking.frontend to javafx.fxml;
    opens com.hambooking.frontend.controllers to javafx.fxml;

    // Abrir paquetes para pruebas unitarias (TestFX y JUnit)
    // Se usa un export/open general para facilitar la ejecución de tests modulares
    opens com.hambooking.frontend.util;

    exports com.hambooking.frontend;
    exports com.hambooking.frontend.util;
}
