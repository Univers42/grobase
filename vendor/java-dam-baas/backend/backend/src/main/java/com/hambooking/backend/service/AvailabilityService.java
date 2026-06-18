package com.hambooking.backend.service;

import com.hambooking.backend.model.entity.Carver;
import com.hambooking.backend.model.entity.Reservation;
import com.hambooking.backend.model.enums.Status;
import com.hambooking.backend.repository.CarverRepository;
import com.hambooking.backend.repository.ReservationRepository;
import com.hambooking.backend.repository.ServiceRepository;
import com.hambooking.backend.exception.BusinessRuleException;
import com.hambooking.backend.exception.ResourceNotFoundException;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.time.LocalDate;
import java.time.LocalTime;
import java.time.DayOfWeek;
import java.util.ArrayList;
import java.util.List;

/**
 * Servicio especializado en el cálculo de disponibilidad horaria para los cortadores.
 * Implementa el algoritmo de generación y filtrado de slots de tiempo para las reservas.
 */
@Service
@RequiredArgsConstructor
public class AvailabilityService {

    /** Hora de apertura predeterminada del establecimiento. */
    private static final LocalTime OPENING_TIME = LocalTime.of(10, 0);
    
    /** Hora de cierre predeterminada del establecimiento. */
    private static final LocalTime CLOSING_TIME = LocalTime.of(18, 0);
    
    /** Duración base de cada bloque de tiempo generado, en minutos. */
    private static final int SLOT_DURATION_MINUTES = 30;

    /** Repositorio de reservas para verificar solapamientos. */
    private final ReservationRepository reservationRepository;
    
    /** Repositorio de cortadores para validar disponibilidad y estado. */
    private final CarverRepository carverRepository;
    
    /** Repositorio de servicios para calcular la duración requerida. */
    private final ServiceRepository serviceRepository;

    /**
     * Obtiene la lista de horas de inicio disponibles para un cortador, fecha y servicio específicos.
     *
     * @param carverId ID del cortador.
     * @param date Fecha a consultar.
     * @param serviceId ID del servicio solicitado (determina la duración necesaria).
     * @return Lista de horas de inicio libres.
     * @throws ResourceNotFoundException Si el cortador o el servicio no existen.
     * @throws BusinessRuleException Si el cortador no está activo o la fecha es fin de semana.
     */
    public List<LocalTime> getAvailableSlots(Long carverId, LocalDate date, Long serviceId) {
        Carver carver = carverRepository.findById(carverId)
                .orElseThrow(() -> new ResourceNotFoundException("Cortador no encontrado"));

        com.hambooking.backend.model.entity.Service service = serviceRepository.findById(serviceId)
                .orElseThrow(() -> new ResourceNotFoundException("Servicio no encontrado"));

        if (!carver.getIsActive()) {
            throw new BusinessRuleException("El cortador seleccionado no está activo");
        }

        DayOfWeek day = date.getDayOfWeek();
        if (day == DayOfWeek.SATURDAY || day == DayOfWeek.SUNDAY) {
            throw new BusinessRuleException("Solo se puede consultar disponibilidad de lunes a viernes");
        }

        List<LocalTime> allSlots = generateAllSlots();
        List<LocalTime> validSlots = filterSlotsByDuration(allSlots, service.getDurationMinutes());
        List<Reservation> activeReservations = getActiveReservations(carver, date);
        
        return removeOccupiedSlots(validSlots, activeReservations, service.getDurationMinutes());
    }

    /**
     * Genera la lista teórica de todos los slots de 30 minutos dentro del horario laboral.
     *
     * @return Lista completa de slots posibles desde la apertura hasta el cierre.
     */
    private List<LocalTime> generateAllSlots() {
        List<LocalTime> slots = new ArrayList<>();
        LocalTime current = OPENING_TIME;

        while (current.isBefore(CLOSING_TIME)) {
            slots.add(current);
            current = current.plusMinutes(SLOT_DURATION_MINUTES);
        }

        return slots;
    }

    /**
     * Filtra los slots eliminando aquellos que no permiten completar la duración del servicio antes del cierre.
     *
     * @param allSlots Lista de todos los slots posibles.
     * @param durationMinutes Duración del servicio contratado.
     * @return Lista de slots con margen de tiempo suficiente para completar el servicio.
     */
    private List<LocalTime> filterSlotsByDuration(List<LocalTime> allSlots, int durationMinutes) {
        List<LocalTime> validSlots = new ArrayList<>();

        for (LocalTime slot : allSlots) {
            LocalTime slotEnd = slot.plusMinutes(durationMinutes);
            if (!slotEnd.isAfter(CLOSING_TIME)) {
                validSlots.add(slot);
            }
        }

        return validSlots;
    }

    /**
     * Recupera las reservas que ya bloquean la agenda del cortador en una fecha.
     *
     * @param carver Entidad del cortador.
     * @param date Fecha de la agenda.
     * @return Lista de reservas en estado PENDING o CONFIRMED para la fecha indicada.
     */
    private List<Reservation> getActiveReservations(Carver carver, LocalDate date) {
        return reservationRepository
                .findByCarverAndReservationDateAndStatusIn(
                        carver,
                        date,
                        List.of(Status.PENDING, Status.CONFIRMED)
                );
    }

    /**
     * Elimina de la lista de slots candidatos aquellos que se solapan con reservas existentes.
     *
     * @param validSlots Lista de slots con duración suficiente.
     * @param activeReservations Reservas actuales en la base de datos para el cortador.
     * @param durationMinutes Duración del nuevo servicio solicitado.
     * @return Lista final de slots disponibles (huecos libres).
     */
    private List<LocalTime> removeOccupiedSlots(List<LocalTime> validSlots,
                                                List<Reservation> activeReservations,
                                                int durationMinutes) {
        List<LocalTime> availableSlots = new ArrayList<>();
        for (LocalTime slot : validSlots) {
            LocalTime slotEnd = slot.plusMinutes(durationMinutes);
            boolean isOccupied = false;
            for (Reservation reservation : activeReservations) {
                boolean overlaps = slot.isBefore(reservation.getEndTime())
                        && slotEnd.isAfter(reservation.getStartTime());
                if (overlaps) {
                    isOccupied = true;
                    break;
                }
            }
            if (!isOccupied) {
                availableSlots.add(slot);
            }
        }
        return availableSlots;
    }
}
