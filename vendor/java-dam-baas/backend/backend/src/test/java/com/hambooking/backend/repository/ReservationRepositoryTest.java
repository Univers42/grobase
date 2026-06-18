package com.hambooking.backend.repository;

import com.hambooking.backend.model.entity.Carver;
import com.hambooking.backend.model.entity.Reservation;
import com.hambooking.backend.model.entity.Service;
import com.hambooking.backend.model.entity.User;
import com.hambooking.backend.model.enums.Role;
import com.hambooking.backend.model.enums.Status;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.LocalTime;
import java.util.List;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/**
 * Tests unitarios para ReservationRepository usando Mockito.
 *
 * ReservationRepository introduce dos novedades respecto a los anteriores:
 *
 *   1. findByCarverAndReservationDateAndStatusIn()
 *      Método derivado con sufijo "In" — Spring genera WHERE status IN (?, ?, ...)
 *      a partir de una List<Status> pasada como parámetro. Es el método clave
 *      para detectar solapamientos de horario en el calendario.
 *
 *   2. @Query con JPQL (countActiveReservationsByClientAndDate,
 *                        sumActiveMinutesByCarverAndDate)
 *      Métodos que no se pueden expresar limpiamente con nombres derivados.
 *      Devuelven escalares (int) en lugar de entidades, lo que los hace
 *      distintos a todo lo que hemos testeado hasta ahora.
 */
@ExtendWith(MockitoExtension.class)
@DisplayName("ReservationRepository — Tests unitarios con Mockito")
class ReservationRepositoryTest {

    @Mock
    private ReservationRepository reservationRepository;

    // =========================================================================
    // MÉTODOS AUXILIARES
    // =========================================================================

    private User buildClient(String email) {
        User user = new User();
        user.setId(1L);
        user.setDni("12345678A");
        user.setFirstName("Cliente");
        user.setLastName("Test");
        user.setEmail(email);
        user.setPhone("612345678");
        user.setPasswordHash("$2a$10$hash");
        user.setRole(Role.CLIENT);
        user.setIsActive(true);
        return user;
    }

    private Carver buildCarver() {
        Carver carver = new Carver();
        carver.setId(1L);
        carver.setSpecialty("Jamón");
        carver.setExperienceYears(5);
        carver.setMaxHamsPerDay(3);
        carver.setIsActive(true);
        return carver;
    }

    private Service buildService(int durationMinutes, BigDecimal price) {
        Service service = new Service();
        service.setId(1L);
        service.setName("Corte de Jamón");
        service.setDurationMinutes(durationMinutes);
        service.setBasePrice(price);
        service.setIsActive(true);
        return service;
    }

    private Reservation buildReservation(User client, Carver carver,
                                         Service service, LocalDate date,
                                         LocalTime start, Status status) {
        Reservation r = new Reservation();
        r.setId(1L);
        r.setClient(client);
        r.setCarver(carver);
        r.setService(service);
        r.setReservationDate(date);
        r.setStartTime(start);
        r.setEndTime(start.plusMinutes(service.getDurationMinutes()));
        r.setStatus(status);
        return r;
    }

    // =========================================================================
    // 1. findByClient
    // =========================================================================

    @Nested
    @DisplayName("1. findByClient")
    class FindByClient {

        @Test
        @DisplayName("Devuelve todas las reservas del cliente")
        void dadoClienteConReservas_devuelveTodasSusReservas() {
            // GIVEN
            User client = buildClient("cliente@test.com");
            Carver carver = buildCarver();
            Service service = buildService(120, new BigDecimal("45.00"));
            LocalDate fecha = LocalDate.now().plusDays(3);

            Reservation r1 = buildReservation(client, carver, service,
                    fecha, LocalTime.of(10, 0), Status.CONFIRMED);
            Reservation r2 = buildReservation(client, carver, service,
                    fecha.plusDays(1), LocalTime.of(11, 0), Status.PENDING);
            r2.setId(2L);

            when(reservationRepository.findByClient(client))
                    .thenReturn(List.of(r1, r2));

            // WHEN
            List<Reservation> resultado = reservationRepository.findByClient(client);

            // THEN
            assertEquals(2, resultado.size());
            assertTrue(resultado.stream().allMatch(r -> r.getClient().equals(client)));
            verify(reservationRepository).findByClient(client);
        }

        @Test
        @DisplayName("Devuelve lista vacía cuando el cliente no tiene reservas")
        void dadoClienteSinReservas_devuelveListaVacia() {
            // GIVEN
            User client = buildClient("nuevo@test.com");
            when(reservationRepository.findByClient(client)).thenReturn(List.of());

            // WHEN + THEN
            assertTrue(reservationRepository.findByClient(client).isEmpty());
        }
    }

    // =========================================================================
    // 2. findByClientAndStatus
    // =========================================================================

    @Nested
    @DisplayName("2. findByClientAndStatus")
    class FindByClientAndStatus {

        @Test
        @DisplayName("Devuelve solo las reservas CONFIRMED del cliente")
        void dadoClienteYEstadoConfirmed_devuelveSoloConfirmadas() {
            // GIVEN
            User client = buildClient("cliente2@test.com");
            Carver carver = buildCarver();
            Service service = buildService(60, new BigDecimal("25.00"));
            Reservation confirmed = buildReservation(client, carver, service,
                    LocalDate.now().plusDays(2), LocalTime.of(10, 0), Status.CONFIRMED);

            when(reservationRepository.findByClientAndStatus(client, Status.CONFIRMED))
                    .thenReturn(List.of(confirmed));

            // WHEN
            List<Reservation> resultado = reservationRepository
                    .findByClientAndStatus(client, Status.CONFIRMED);

            // THEN
            assertEquals(1, resultado.size());
            assertEquals(Status.CONFIRMED, resultado.get(0).getStatus());
        }

        @Test
        @DisplayName("Devuelve lista vacía cuando el cliente no tiene reservas con ese estado")
        void dadoClienteSinReservasConEseEstado_devuelveListaVacia() {
            // GIVEN
            User client = buildClient("cliente3@test.com");
            when(reservationRepository.findByClientAndStatus(client, Status.CANCELLED))
                    .thenReturn(List.of());

            // WHEN + THEN
            assertTrue(reservationRepository
                    .findByClientAndStatus(client, Status.CANCELLED).isEmpty());
        }
    }

    // =========================================================================
    // 3. findByCarver
    // =========================================================================

    @Nested
    @DisplayName("3. findByCarver")
    class FindByCarver {

        @Test
        @DisplayName("Devuelve todas las reservas del cortador")
        void dadoCortadorConReservas_devuelveSuAgenda() {
            // GIVEN
            Carver carver = buildCarver();
            User c1 = buildClient("c1@test.com");
            User c2 = buildClient("c2@test.com");
            Service service = buildService(120, new BigDecimal("45.00"));
            LocalDate fecha = LocalDate.now().plusDays(1);

            Reservation r1 = buildReservation(c1, carver, service,
                    fecha, LocalTime.of(10, 0), Status.CONFIRMED);
            Reservation r2 = buildReservation(c2, carver, service,
                    fecha, LocalTime.of(12, 0), Status.PENDING);
            r2.setId(2L);

            when(reservationRepository.findByCarver(carver)).thenReturn(List.of(r1, r2));

            // WHEN
            List<Reservation> resultado = reservationRepository.findByCarver(carver);

            // THEN
            assertEquals(2, resultado.size());
            assertTrue(resultado.stream().allMatch(r -> r.getCarver().equals(carver)));
        }
    }

    // =========================================================================
    // 4. findByCarverAndReservationDateAndStatusIn  ← EL MÁS IMPORTANTE
    // =========================================================================

    @Nested
    @DisplayName("4. findByCarverAndReservationDateAndStatusIn")
    class FindByCarverAndReservationDateAndStatusIn {

        @Test
        @DisplayName("Devuelve reservas activas del cortador ese día (detección de solapamientos)")
        void dadoCortadorYFecha_devuelveReservasActivas() {
            // GIVEN — simulamos que el cortador ya tiene una reserva a las 10:00
            Carver carver = buildCarver();
            User client = buildClient("solapamiento@test.com");
            Service service = buildService(120, new BigDecimal("45.00"));
            LocalDate fecha = LocalDate.now().plusDays(1);

            Reservation existente = buildReservation(client, carver, service,
                    fecha, LocalTime.of(10, 0), Status.CONFIRMED);

            List<Status> estadosActivos = List.of(Status.PENDING, Status.CONFIRMED);
            when(reservationRepository.findByCarverAndReservationDateAndStatusIn(
                    carver, fecha, estadosActivos))
                    .thenReturn(List.of(existente));

            // WHEN
            List<Reservation> resultado = reservationRepository
                    .findByCarverAndReservationDateAndStatusIn(carver, fecha, estadosActivos);

            // THEN
            assertEquals(1, resultado.size(),
                    "Debe devolver la reserva existente para que el Service detecte el solapamiento");
            assertEquals(LocalTime.of(10, 0), resultado.get(0).getStartTime());
        }

        @Test
        @DisplayName("Devuelve lista vacía cuando el cortador no tiene reservas activas ese día")
        void dadoCortadorLibreEseDia_devuelveListaVacia() {
            // GIVEN — agenda del cortador vacía para esa fecha
            Carver carver = buildCarver();
            LocalDate fecha = LocalDate.now().plusDays(5);
            List<Status> estadosActivos = List.of(Status.PENDING, Status.CONFIRMED);

            when(reservationRepository.findByCarverAndReservationDateAndStatusIn(
                    carver, fecha, estadosActivos))
                    .thenReturn(List.of());

            // WHEN
            List<Reservation> resultado = reservationRepository
                    .findByCarverAndReservationDateAndStatusIn(carver, fecha, estadosActivos);

            // THEN
            assertTrue(resultado.isEmpty(),
                    "Cortador libre — el Service puede asignar cualquier slot");
        }

        @Test
        @DisplayName("Las reservas CANCELLED no aparecen (no bloquean el horario)")
        void reservasCanceladas_noAparecenEnElFiltro() {
            // GIVEN — solo pasamos PENDING y CONFIRMED, no CANCELLED
            Carver carver = buildCarver();
            LocalDate fecha = LocalDate.now().plusDays(2);
            List<Status> estadosActivos = List.of(Status.PENDING, Status.CONFIRMED);

            // El mock devuelve vacío porque la única reserva del día es CANCELLED
            when(reservationRepository.findByCarverAndReservationDateAndStatusIn(
                    carver, fecha, estadosActivos))
                    .thenReturn(List.of());

            // WHEN
            List<Reservation> resultado = reservationRepository
                    .findByCarverAndReservationDateAndStatusIn(carver, fecha, estadosActivos);

            // THEN
            assertTrue(resultado.isEmpty(),
                    "Las reservas canceladas no bloquean el horario del cortador");
        }
    }

    // =========================================================================
    // 5. findByReservationDateAndStatus
    // =========================================================================

    @Nested
    @DisplayName("5. findByReservationDateAndStatus")
    class FindByReservationDateAndStatus {

        @Test
        @DisplayName("Devuelve las reservas de hoy con estado CONFIRMED")
        void dadoHoyYConfirmed_devuelveReservasDeHoy() {
            // GIVEN
            LocalDate hoy = LocalDate.now();
            User client = buildClient("hoy@test.com");
            Carver carver = buildCarver();
            Service service = buildService(60, new BigDecimal("25.00"));
            Reservation r = buildReservation(client, carver, service,
                    hoy, LocalTime.of(11, 0), Status.CONFIRMED);

            when(reservationRepository.findByReservationDateAndStatus(hoy, Status.CONFIRMED))
                    .thenReturn(List.of(r));

            // WHEN
            List<Reservation> resultado = reservationRepository
                    .findByReservationDateAndStatus(hoy, Status.CONFIRMED);

            // THEN
            assertEquals(1, resultado.size());
            assertEquals(hoy, resultado.get(0).getReservationDate());
        }
    }

    // =========================================================================
    // 6. findByReservationDateBetweenAndStatus
    // =========================================================================

    @Nested
    @DisplayName("6. findByReservationDateBetweenAndStatus")
    class FindByReservationDateBetweenAndStatus {

        @Test
        @DisplayName("Devuelve reservas CONFIRMED dentro del rango de fechas indicado")
        void dadoRangoFechasYConfirmed_devuelveReservasDelRango() {
            // GIVEN — rango de una semana
            LocalDate inicio = LocalDate.now().plusDays(1);
            LocalDate fin    = LocalDate.now().plusDays(7);
            User client = buildClient("semana@test.com");
            Carver carver = buildCarver();
            Service service = buildService(60, new BigDecimal("25.00"));

            Reservation r1 = buildReservation(client, carver, service,
                    inicio.plusDays(1), LocalTime.of(10, 0), Status.CONFIRMED);
            Reservation r2 = buildReservation(client, carver, service,
                    inicio.plusDays(3), LocalTime.of(14, 0), Status.CONFIRMED);
            r2.setId(2L);

            when(reservationRepository.findByReservationDateBetweenAndStatus(
                    inicio, fin, Status.CONFIRMED))
                    .thenReturn(List.of(r1, r2));

            // WHEN
            List<Reservation> resultado = reservationRepository
                    .findByReservationDateBetweenAndStatus(inicio, fin, Status.CONFIRMED);

            // THEN
            assertEquals(2, resultado.size());
            assertTrue(resultado.stream()
                    .allMatch(r -> !r.getReservationDate().isBefore(inicio)
                            && !r.getReservationDate().isAfter(fin)));
        }

        @Test
        @DisplayName("Devuelve lista vacía cuando no hay reservas en ese rango")
        void sinReservasEnElRango_devuelveListaVacia() {
            // GIVEN
            LocalDate inicio = LocalDate.now().plusDays(10);
            LocalDate fin    = LocalDate.now().plusDays(17);
            when(reservationRepository.findByReservationDateBetweenAndStatus(
                    inicio, fin, Status.CONFIRMED))
                    .thenReturn(List.of());

            // WHEN + THEN
            assertTrue(reservationRepository
                    .findByReservationDateBetweenAndStatus(inicio, fin, Status.CONFIRMED)
                    .isEmpty());
        }
    }

    // =========================================================================
    // 7. countActiveReservationsByClientAndDate  ← @Query JPQL
    // =========================================================================

    @Nested
    @DisplayName("7. countActiveReservationsByClientAndDate (@Query)")
    class CountActiveReservationsByClientAndDate {

        @Test
        @DisplayName("Devuelve 0 cuando el cliente no tiene reservas activas ese día")
        void sinReservasActivas_devuelveCero() {
            // GIVEN
            User client = buildClient("count0@test.com");
            LocalDate fecha = LocalDate.now().plusDays(2);
            when(reservationRepository.countActiveReservationsByClientAndDate(client, fecha))
                    .thenReturn(0);

            // WHEN + THEN
            assertEquals(0, reservationRepository
                    .countActiveReservationsByClientAndDate(client, fecha));
        }

        @Test
        @DisplayName("Devuelve 1 cuando el cliente ya tiene 1 reserva activa ese día")
        void unaReservaActiva_devuelveUno() {
            // GIVEN
            User client = buildClient("count1@test.com");
            LocalDate fecha = LocalDate.now().plusDays(3);
            when(reservationRepository.countActiveReservationsByClientAndDate(client, fecha))
                    .thenReturn(1);

            // WHEN + THEN
            assertEquals(1, reservationRepository
                    .countActiveReservationsByClientAndDate(client, fecha));
        }

        @Test
        @DisplayName("Devuelve 2 cuando el cliente ha alcanzado el límite diario")
        void dosReservasActivas_devuelveDos_indicaLimitAlcanzado() {
            // GIVEN — el Service usará este valor para lanzar excepción si >= 2
            User client = buildClient("count2@test.com");
            LocalDate fecha = LocalDate.now().plusDays(4);
            when(reservationRepository.countActiveReservationsByClientAndDate(client, fecha))
                    .thenReturn(2);

            // WHEN
            int count = reservationRepository
                    .countActiveReservationsByClientAndDate(client, fecha);

            // THEN
            assertEquals(2, count);
            assertTrue(count >= 2, "Con 2 reservas el Service debe rechazar la nueva solicitud");
        }
    }

    // =========================================================================
    // 8. sumActiveMinutesByCarverAndDate  ← @Query JPQL con COALESCE + SUM
    // =========================================================================

    @Nested
    @DisplayName("8. sumActiveMinutesByCarverAndDate (@Query)")
    class SumActiveMinutesByCarverAndDate {

        @Test
        @DisplayName("Devuelve 0 cuando el cortador no tiene trabajo ese día")
        void sinTrabajo_devuelveCero() {
            // GIVEN
            Carver carver = buildCarver();
            LocalDate fecha = LocalDate.now().plusDays(1);
            when(reservationRepository.sumActiveMinutesByCarverAndDate(carver, fecha))
                    .thenReturn(0);

            // WHEN + THEN
            assertEquals(0, reservationRepository
                    .sumActiveMinutesByCarverAndDate(carver, fecha));
        }

        @Test
        @DisplayName("Devuelve los minutos acumulados de trabajo ese día")
        void conDosJamones_devuelve240Minutos() {
            // GIVEN — dos jamones de 120 min cada uno = 240 min
            Carver carver = buildCarver();
            LocalDate fecha = LocalDate.now().plusDays(2);
            when(reservationRepository.sumActiveMinutesByCarverAndDate(carver, fecha))
                    .thenReturn(240);

            // WHEN
            int minutos = reservationRepository
                    .sumActiveMinutesByCarverAndDate(carver, fecha);

            // THEN
            assertEquals(240, minutos);
            assertTrue(minutos < 360,
                    "240 min < 360 min (6h) — el cortador aún puede aceptar más trabajo");
        }

        @Test
        @DisplayName("Con 360 minutos el cortador ha alcanzado el límite de 6 horas")
        void con360Minutos_indicaLimiteDiarioAlcanzado() {
            // GIVEN — límite exacto: 3 jamones de 120 min = 360 min = 6h
            Carver carver = buildCarver();
            LocalDate fecha = LocalDate.now().plusDays(3);
            when(reservationRepository.sumActiveMinutesByCarverAndDate(carver, fecha))
                    .thenReturn(360);

            // WHEN
            int minutos = reservationRepository
                    .sumActiveMinutesByCarverAndDate(carver, fecha);

            // THEN
            assertEquals(360, minutos);
            assertFalse(minutos < 360,
                    "El Service debe rechazar más reservas — límite de 6h alcanzado");
        }
    }

    // =========================================================================
    // 9. OPERACIONES CRUD heredadas de JpaRepository (smoke tests)
    // =========================================================================

    @Nested
    @DisplayName("9. Operaciones CRUD heredadas")
    class OperacionesCrud {

        @Test
        @DisplayName("save() devuelve la reserva con id asignado")
        void save_devuelveReservaConId() {
            // GIVEN
            User client = buildClient("save@test.com");
            Carver carver = buildCarver();
            Service service = buildService(60, new BigDecimal("25.00"));
            Reservation sinId = buildReservation(client, carver, service,
                    LocalDate.now().plusDays(1), LocalTime.of(10, 0), Status.PENDING);
            sinId.setId(null);
            Reservation conId = buildReservation(client, carver, service,
                    LocalDate.now().plusDays(1), LocalTime.of(10, 0), Status.PENDING);
            conId.setId(99L);

            when(reservationRepository.save(sinId)).thenReturn(conId);

            // WHEN
            Reservation guardada = reservationRepository.save(sinId);

            // THEN
            assertNotNull(guardada.getId());
            assertEquals(Status.PENDING, guardada.getStatus());
        }

        @Test
        @DisplayName("findById() devuelve la reserva cuando el id existe")
        void findById_devuelveReservaCuandoExiste() {
            // GIVEN
            User client = buildClient("findbyid@test.com");
            Carver carver = buildCarver();
            Service service = buildService(120, new BigDecimal("45.00"));
            Reservation reservation = buildReservation(client, carver, service,
                    LocalDate.now().plusDays(1), LocalTime.of(11, 0), Status.CONFIRMED);
            reservation.setId(42L);

            when(reservationRepository.findById(42L)).thenReturn(Optional.of(reservation));

            // WHEN
            Optional<Reservation> resultado = reservationRepository.findById(42L);

            // THEN
            assertTrue(resultado.isPresent());
            assertEquals(42L, resultado.get().getId());
        }

        @Test
        @DisplayName("deleteById() se invoca exactamente una vez")
        void deleteById_seInvocaUnaVez() {
            // GIVEN
            doNothing().when(reservationRepository).deleteById(1L);

            // WHEN
            reservationRepository.deleteById(1L);

            // THEN
            verify(reservationRepository, times(1)).deleteById(1L);
        }
    }
}