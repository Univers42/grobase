package com.hambooking.backend.service;

import com.hambooking.backend.dto.reservation.CreateReservationDTO;
import com.hambooking.backend.dto.reservation.ReservationResponseDTO;
import com.hambooking.backend.dto.reservation.UpdateReservationDTO;
import com.hambooking.backend.exception.BusinessRuleException;
import com.hambooking.backend.exception.ReservationLimitExceededException;
import com.hambooking.backend.exception.ResourceNotFoundException;
import com.hambooking.backend.exception.TimeSlotNotAvailableException;
import com.hambooking.backend.model.entity.Carver;
import com.hambooking.backend.model.entity.Reservation;
import com.hambooking.backend.model.entity.Service;
import com.hambooking.backend.model.entity.User;
import com.hambooking.backend.model.enums.NotificationType;
import com.hambooking.backend.model.enums.Status;
import com.hambooking.backend.repository.CarverRepository;
import com.hambooking.backend.repository.ReservationRepository;
import com.hambooking.backend.repository.ServiceRepository;
import com.hambooking.backend.repository.UserRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.transaction.annotation.Transactional;

import java.time.DayOfWeek;
import java.time.LocalTime;
import java.util.List;
import java.util.stream.Collectors;

/**
 * Servicio principal de gestión de reservas.
 * Controla la lógica de negocio para la creación, modificación, confirmación y cancelación de reservas,
 * aplicando restricciones de horarios, solapamientos y límites diarios.
 */
@org.springframework.stereotype.Service
@RequiredArgsConstructor
public class ReservationService {

    /** Hora de apertura del local. */
    private static final LocalTime OPENING_TIME = LocalTime.of(10, 0);
    
    /** Hora de cierre del local. */
    private static final LocalTime CLOSING_TIME = LocalTime.of(18, 0);
    
    /** Límite máximo de reservas que un cliente puede tener activas en un mismo día. */
    private static final int MAX_DAILY_RESERVATIONS_PER_CLIENT = 2;
    
    /** Límite máximo de minutos de servicio que un cortador puede asumir al día. */
    private static final int MAX_DAILY_MINUTES_PER_CARVER = 360;

    /** Repositorio de reservas. */
    private final ReservationRepository reservationRepository;
    
    /** Repositorio de usuarios. */
    private final UserRepository userRepository;
    
    /** Repositorio de cortadores. */
    private final CarverRepository carverRepository;
    
    /** Repositorio de servicios. */
    private final ServiceRepository serviceRepository;
    
    /** Servicio de notificaciones para el envío de alertas automáticas. */
    private final NotificationService notificationService;

    /**
     * Crea una nueva reserva tras validar múltiples reglas de negocio (horarios, límites y solapamientos).
     *
     * @param request DTO con los datos para la creación de la reserva.
     * @return DTO con la información de la reserva generada.
     * @throws ResourceNotFoundException Si el cliente, cortador o servicio no existen.
     * @throws BusinessRuleException Si el cortador no está activo, es fin de semana, o el horario es inválido.
     * @throws ReservationLimitExceededException Si el cliente o el cortador superan sus límites diarios.
     * @throws TimeSlotNotAvailableException Si el horario solicitado se solapa con una reserva existente.
     */
    @Transactional
    public ReservationResponseDTO createReservation(CreateReservationDTO request) {

        User client = userRepository.findById(request.getClientId())
                .orElseThrow(() -> new ResourceNotFoundException("Cliente no encontrado"));
        Carver carver = carverRepository.findById(request.getCarverId())
                .orElseThrow(() -> new ResourceNotFoundException("Cortador no encontrado"));
        Service service = serviceRepository.findById(request.getServiceId())
                .orElseThrow(() -> new ResourceNotFoundException("Servicio no encontrado"));

        if (!carver.getIsActive()) {
            throw new BusinessRuleException("El cortador seleccionado no está activo");
        }

        DayOfWeek day = request.getReservationDate().getDayOfWeek();
        if (day == DayOfWeek.SATURDAY || day == DayOfWeek.SUNDAY) {
            throw new BusinessRuleException("Solo se pueden hacer reservas de lunes a viernes");
        }

        LocalTime endTime = request.getStartTime().plusMinutes(service.getDurationMinutes());
        if (request.getStartTime().isBefore(OPENING_TIME) || endTime.isAfter(CLOSING_TIME)) {
            throw new BusinessRuleException(
                    "La reserva debe estar dentro del horario laboral (10:00 - 18:00)");
        }

        int clientDaily = reservationRepository
                .countActiveReservationsByClientAndDate(client, request.getReservationDate());
        if (clientDaily >= MAX_DAILY_RESERVATIONS_PER_CLIENT) {
            throw new ReservationLimitExceededException(
                    "Has alcanzado el límite de " + MAX_DAILY_RESERVATIONS_PER_CLIENT + " reservas para ese día");
        }

        int carverMinutes = reservationRepository
                .sumActiveMinutesByCarverAndDate(carver, request.getReservationDate());
        if (carverMinutes + service.getDurationMinutes() > MAX_DAILY_MINUTES_PER_CARVER) {
            throw new ReservationLimitExceededException(
                    "El cortador ha alcanzado su límite de horas para ese día");
        }

        List<Reservation> existing = reservationRepository
                .findByCarverAndReservationDateAndStatusIn(
                        carver, request.getReservationDate(),
                        List.of(Status.PENDING, Status.CONFIRMED));

        for (Reservation e : existing) {
            if (request.getStartTime().isBefore(e.getEndTime())
                    && endTime.isAfter(e.getStartTime())) {
                throw new TimeSlotNotAvailableException(
                        "El cortador ya tiene una reserva en ese horario");
            }
        }

        Reservation reservation = new Reservation();
        reservation.setClient(client);
        reservation.setCarver(carver);
        reservation.setService(service);
        reservation.setReservationDate(request.getReservationDate());
        reservation.setStartTime(request.getStartTime());
        reservation.setNotes(request.getNotes());
        reservation.setStatus(Status.PENDING);
        reservation.calculateEndTime();

        Reservation saved = reservationRepository.save(reservation);
        notificationService.sendReservationNotification(saved, NotificationType.CREATED);
        return toDTO(saved);
    }

    /**
     * Confirma una reserva que actualmente se encuentra en estado PENDING.
     *
     * @param id Identificador de la reserva a confirmar.
     * @return DTO con la información de la reserva actualizada.
     * @throws ResourceNotFoundException Si la reserva no existe.
     * @throws BusinessRuleException Si la reserva no está en estado PENDING.
     */
    @Transactional
    public ReservationResponseDTO confirmReservation(Long id) {
        Reservation reservation = reservationRepository.findById(id)
                .orElseThrow(() -> new ResourceNotFoundException("Reserva no encontrada"));

        if (reservation.getStatus() != Status.PENDING) {
            throw new BusinessRuleException(
                    "Solo se pueden confirmar reservas en estado PENDIENTE");
        }

        reservation.setStatus(Status.CONFIRMED);
        Reservation confirmed = reservationRepository.save(reservation);
        return toDTO(confirmed);
    }

    /**
     * Actualiza la fecha, hora de inicio o notas de una reserva existente en estado PENDING.
     *
     * @param id Identificador de la reserva a actualizar.
     * @param request DTO con los nuevos datos de la reserva.
     * @return DTO con la información de la reserva tras la actualización.
     * @throws ResourceNotFoundException Si la reserva no existe.
     * @throws BusinessRuleException Si la reserva no es modificable o sus horarios son inválidos.
     * @throws TimeSlotNotAvailableException Si el nuevo horario se solapa con otra reserva.
     */
    @Transactional
    public ReservationResponseDTO updateReservation(Long id, UpdateReservationDTO request) {

        Reservation reservation = reservationRepository.findById(id)
                .orElseThrow(() -> new ResourceNotFoundException("Reserva no encontrada"));

        if (reservation.getStatus() != Status.PENDING) {
            throw new BusinessRuleException("Solo se pueden modificar reservas en estado PENDIENTE");
        }

        DayOfWeek day = request.getReservationDate().getDayOfWeek();
        if (day == DayOfWeek.SATURDAY || day == DayOfWeek.SUNDAY) {
            throw new BusinessRuleException("Solo se pueden hacer reservas de lunes a viernes");
        }

        LocalTime endTime = request.getStartTime()
                .plusMinutes(reservation.getService().getDurationMinutes());
        if (request.getStartTime().isBefore(OPENING_TIME) || endTime.isAfter(CLOSING_TIME)) {
            throw new BusinessRuleException(
                    "La reserva debe estar dentro del horario laboral (10:00 - 18:00)");
        }

        List<Reservation> existing = reservationRepository
                .findByCarverAndReservationDateAndStatusIn(
                        reservation.getCarver(), request.getReservationDate(),
                        List.of(Status.PENDING, Status.CONFIRMED));

        for (Reservation e : existing) {
            if (e.getId().equals(id)) continue;
            if (request.getStartTime().isBefore(e.getEndTime())
                    && endTime.isAfter(e.getStartTime())) {
                throw new TimeSlotNotAvailableException(
                        "El cortador ya tiene una reserva en ese horario");
            }
        }

        reservation.setReservationDate(request.getReservationDate());
        reservation.setStartTime(request.getStartTime());
        reservation.setNotes(request.getNotes());
        reservation.calculateEndTime();

        Reservation updated = reservationRepository.save(reservation);
        notificationService.sendReservationNotification(updated, NotificationType.MODIFIED);
        return toDTO(updated);
    }

    /**
     * Cancela una reserva existente si es posible según su estado actual.
     *
     * @param id Identificador de la reserva a cancelar.
     * @throws ResourceNotFoundException Si la reserva no existe.
     * @throws BusinessRuleException Si la reserva ya está cancelada o completada.
     */
    @Transactional
    public void cancelReservation(Long id) {
        Reservation reservation = reservationRepository.findById(id)
                .orElseThrow(() -> new ResourceNotFoundException("Reserva no encontrada"));

        if (reservation.getStatus() == Status.CANCELLED) {
            throw new BusinessRuleException("La reserva ya está cancelada");
        }
        if (reservation.getStatus() == Status.COMPLETED) {
            throw new BusinessRuleException("No se puede cancelar una reserva ya completada");
        }

        reservation.setStatus(Status.CANCELLED);
        Reservation cancelled = reservationRepository.save(reservation);
        notificationService.sendReservationNotification(cancelled, NotificationType.CANCELLED);
    }

    /**
     * Obtiene una lista de todas las reservas registradas en el sistema.
     *
     * @return Lista de DTOs representando todas las reservas.
     */
    @Transactional(readOnly = true)
    public List<ReservationResponseDTO> listAllReservations() {
        return reservationRepository.findAll()
                .stream()
                .map(this::toDTO)
                .collect(Collectors.toList());
    }

    /**
     * Obtiene una lista de todas las reservas asociadas a un cliente específico.
     *
     * @param clientId Identificador del cliente.
     * @return Lista de DTOs con las reservas del cliente.
     * @throws ResourceNotFoundException Si el cliente no existe.
     */
    @Transactional(readOnly = true)
    public List<ReservationResponseDTO> listReservationsByClient(Long clientId) {
        User client = userRepository.findById(clientId)
                .orElseThrow(() -> new ResourceNotFoundException("Cliente no encontrado"));
        return reservationRepository.findByClient(client)
                .stream()
                .map(this::toDTO)
                .collect(Collectors.toList());
    }

    /**
     * Convierte una entidad de Reserva en su correspondiente DTO de respuesta.
     *
     * @param r Entidad de reserva a convertir.
     * @return Objeto ReservationResponseDTO con los datos extraídos.
     */
    private ReservationResponseDTO toDTO(Reservation r) {
        return new ReservationResponseDTO(
                r.getId(),
                r.getClient().getId(),
                r.getClient().getFirstName(),
                r.getClient().getLastName(),
                r.getCarver().getId(),
                r.getCarver().getUser().getFirstName(),
                r.getCarver().getUser().getLastName(),
                r.getService().getId(),
                r.getService().getName(),
                r.getService().getDurationMinutes(),
                r.getReservationDate(),
                r.getStartTime(),
                r.getEndTime(),
                r.getStatus(),
                r.getNotes(),
                r.getCreatedAt()
        );
    }
}
