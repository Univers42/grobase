package com.hambooking.backend.service;

import com.hambooking.backend.model.enums.Status;
import com.hambooking.backend.repository.ReservationRepository;
import lombok.RequiredArgsConstructor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;

/**
 * Servicio encargado de actualizar automáticamente el estado de reservas cuya fecha haya expirado.
 *
 * Utiliza anotaciones de modificación y consultas personalizadas para realizar un UPDATE directo
 * en la base de datos, evitando que Hibernate lance validaciones relacionadas con fechas futuras
 * al guardar entidades.
 *
 * El comportamiento principal consiste en:
 * - Convertir reservas en estado PENDING con fecha pasada a CANCELLED.
 * - Convertir reservas en estado CONFIRMED con fecha pasada a COMPLETED.
 */
@Service
@EnableScheduling
@RequiredArgsConstructor
public class ReservationStatusService {

    /** Logger para registrar las actividades automáticas de este servicio. */
    private static final Logger logger = LoggerFactory.getLogger(ReservationStatusService.class);

    /** Repositorio de reservas para invocar la actualización de estados. */
    private final ReservationRepository reservationRepository;

    /**
     * Tarea programada que evalúa y modifica el estado de las reservas que quedaron en el pasado.
     * Se ejecuta de manera automática cada día a la 01:00 AM, así como opcionalmente
     * al iniciarse la aplicación.
     */
    @Scheduled(cron = "0 0 1 * * *")
    public void scheduledUpdate() {
        logger.info("[ReservationStatusService] Tarea diaria — actualizando estados...");
        actualizarEstadosPasados();
    }

    /**
     * Procesa la actualización directa en base de datos para los estados vencidos.
     */
    @Transactional
    public void actualizarEstadosPasados() {
        LocalDate hoy = LocalDate.now();

        int canceladas = reservationRepository.updateStatusForPastReservations(
                Status.CANCELLED, Status.PENDING, hoy);

        int completadas = reservationRepository.updateStatusForPastReservations(
                Status.COMPLETED, Status.CONFIRMED, hoy);

        logger.info("[ReservationStatusService] {} canceladas, {} completadas.",
                canceladas, completadas);
    }
}
