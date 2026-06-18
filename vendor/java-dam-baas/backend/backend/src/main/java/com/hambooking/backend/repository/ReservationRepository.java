package com.hambooking.backend.repository;

import com.hambooking.backend.model.entity.Carver;
import com.hambooking.backend.model.entity.Reservation;
import com.hambooking.backend.model.entity.User;
import com.hambooking.backend.model.enums.Status;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.stereotype.Repository;

import java.time.LocalDate;
import java.util.List;

/**
 * Repositorio para la gestión de persistencia de la entidad {@link Reservation}.
 * Implementa la lógica de acceso a datos para el sistema de reservas y disponibilidad.
 */
@Repository
public interface ReservationRepository extends JpaRepository<Reservation, Long> {

    /**
     * Obtiene todas las reservas realizadas por un cliente específico.
     * @param client Usuario con rol cliente.
     * @return Lista de reservas del cliente.
     */
    List<Reservation> findByClient(User client);

    /**
     * Recupera reservas de un cliente filtradas por su estado actual.
     * @param client Usuario con rol cliente.
     * @param status Estado de la reserva a filtrar.
     * @return Lista de reservas filtradas.
     */
    List<Reservation> findByClientAndStatus(User client, Status status);

    /**
     * Obtiene la agenda de reservas asignadas a un cortador profesional.
     * @param carver Entidad del cortador.
     * @return Lista de reservas asignadas.
     */
    List<Reservation> findByCarver(Carver carver);

    /**
     * Recupera reservas de un cortador en una fecha concreta con estados específicos.
     * Método clave para el cálculo de disponibilidad horaria.
     * @param carver Entidad del cortador.
     * @param reservationDate Fecha de la reserva.
     * @param statuses Lista de estados considerados ocupados (ej. CONFIRMED, PENDING).
     * @return Lista de reservas que ocupan slots.
     */
    List<Reservation> findByCarverAndReservationDateAndStatusIn(
            Carver carver, LocalDate reservationDate, List<Status> statuses);

    /**
     * Obtiene todas las reservas de una fecha con un estado determinado.
     * @param reservationDate Fecha a consultar.
     * @param status Estado de la reserva.
     * @return Lista de reservas coincidentes.
     */
    List<Reservation> findByReservationDateAndStatus(LocalDate reservationDate, Status status);

    /**
     * Recupera reservas dentro de un rango de fechas filtradas por estado.
     * @param startDate Fecha de inicio del rango.
     * @param endDate Fecha de fin del rango.
     * @param status Estado de la reserva.
     * @return Lista de reservas en el intervalo.
     */
    List<Reservation> findByReservationDateBetweenAndStatus(
            LocalDate startDate, LocalDate endDate, Status status);

    /**
     * Cuenta el número de reservas activas de un cliente en una fecha específica.
     * @param client Usuario a consultar.
     * @param date Fecha de interés.
     * @return Cantidad de reservas en estado PENDING o CONFIRMED.
     */
    @Query("SELECT COUNT(r) FROM Reservation r " +
            "WHERE r.client = :client " +
            "AND r.reservationDate = :date " +
            "AND r.status IN ('PENDING', 'CONFIRMED')")
    int countActiveReservationsByClientAndDate(
            @Param("client") User client,
            @Param("date") LocalDate date);

    /**
     * Calcula la suma total de minutos ocupados por un cortador en una fecha.
     * Utilizado para validar el límite de carga de trabajo diaria.
     * @param carver Entidad del cortador.
     * @param date Fecha de interés.
     * @return Suma de duraciones en minutos (0 si no hay reservas).
     */
    @Query("SELECT COALESCE(SUM(s.durationMinutes), 0) FROM Reservation r " +
            "JOIN r.service s " +
            "WHERE r.carver = :carver " +
            "AND r.reservationDate = :date " +
            "AND r.status IN ('PENDING', 'CONFIRMED')")
    int sumActiveMinutesByCarverAndDate(
            @Param("carver") Carver carver,
            @Param("date") LocalDate date);

    /**
     * Realiza una actualización masiva de estados para reservas cuya fecha ha expirado.
     * Evita las validaciones de ciclo de vida de la entidad para permitir el cierre histórico.
     * @param newStatus Nuevo estado (ej. COMPLETED).
     * @param currentStatus Estado actual a transicionar (ej. CONFIRMED).
     * @param fecha Fecha límite (reservas anteriores a esta fecha).
     * @return Número de registros actualizados.
     */
    @Modifying
    @Query("UPDATE Reservation r SET r.status = :newStatus " +
            "WHERE r.reservationDate < :fecha AND r.status = :currentStatus")
    int updateStatusForPastReservations(
            @Param("newStatus") Status newStatus,
            @Param("currentStatus") Status currentStatus,
            @Param("fecha") LocalDate fecha);
}
