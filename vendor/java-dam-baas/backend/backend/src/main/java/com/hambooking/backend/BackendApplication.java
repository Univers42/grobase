package com.hambooking.backend;

import com.hambooking.backend.service.ReservationStatusService;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.ConfigurableApplicationContext;

@SpringBootApplication
public class BackendApplication {

    public static void main(String[] args) {
        ConfigurableApplicationContext ctx = SpringApplication.run(BackendApplication.class, args);

        // Actualizar estados de reservas pasadas al arrancar
        // (fuera del contexto de eventos para garantizar la transacción)
        ReservationStatusService statusService =
                ctx.getBean(ReservationStatusService.class);
        statusService.actualizarEstadosPasados();
    }
}