-- ============================================================
-- HAMBOOKING DATABASE SCHEMA v1.3 (FINAL STABLE)
-- ============================================================

DROP DATABASE IF EXISTS hambooking;
CREATE DATABASE IF NOT EXISTS hambooking
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE hambooking;

-- ============================================================
-- 1. USERS
-- ============================================================
CREATE TABLE users (
                       id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
                       dni VARCHAR(9) NOT NULL,
                       first_name VARCHAR(100) NOT NULL,
                       last_name VARCHAR(150) NOT NULL,
                       email VARCHAR(150) NOT NULL,
                       phone VARCHAR(15) NOT NULL,
                       password_hash VARCHAR(255) NOT NULL,
                       role ENUM('ADMIN', 'CLIENT') NOT NULL DEFAULT 'CLIENT',
                       is_active BOOLEAN NOT NULL DEFAULT TRUE,
                       created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                       updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

                       CONSTRAINT uk_users_dni UNIQUE (dni),
                       CONSTRAINT uk_users_email UNIQUE (email),
                       CONSTRAINT chk_dni_format CHECK (dni REGEXP '^[0-9]{8}[A-Za-z]$')
) ENGINE=InnoDB;

CREATE INDEX idx_users_email ON users(email);

-- ============================================================
-- 2. CARVERS
-- ============================================================
CREATE TABLE carvers (
                         id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
                         user_id BIGINT UNSIGNED NOT NULL,
                         specialty VARCHAR(100),
                         experience_years INT UNSIGNED DEFAULT 0,
                         max_hams_per_day INT UNSIGNED DEFAULT 3,
                         is_active BOOLEAN NOT NULL DEFAULT TRUE,
                         created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

                         CONSTRAINT fk_carver_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
                         CONSTRAINT uk_carver_user UNIQUE (user_id)
) ENGINE=InnoDB;

-- ============================================================
-- 3. SERVICES
-- ============================================================
CREATE TABLE services (
                          id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
                          name VARCHAR(100) NOT NULL,
                          description TEXT,
                          duration_minutes INT UNSIGNED NOT NULL,
                          base_price DECIMAL(10,2) NOT NULL,
                          is_active BOOLEAN NOT NULL DEFAULT TRUE,

                          CONSTRAINT uk_service_name UNIQUE (name),
                          CONSTRAINT chk_duration_positive CHECK (duration_minutes > 0),
                          CONSTRAINT chk_price_positive CHECK (base_price >= 0)
) ENGINE=InnoDB;

INSERT INTO services (name, description, duration_minutes, base_price) VALUES
                                                                           ('Jamón', 'Corte profesional de jamón entero', 120, 50.00),
                                                                           ('Paleta', 'Corte de paleta ibérica', 60, 35.00),
                                                                           ('Embutidos', 'Tabla surtida de embutidos', 30, 25.00);

-- ============================================================
-- 4. RESERVATIONS
-- ============================================================
CREATE TABLE reservations (
                              id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
                              client_id BIGINT UNSIGNED NOT NULL,
                              carver_id BIGINT UNSIGNED NOT NULL,
                              service_id BIGINT UNSIGNED NOT NULL,
                              reservation_date DATE NOT NULL,
                              start_time TIME NOT NULL,
                              end_time TIME NOT NULL,
                              status ENUM('PENDING', 'CONFIRMED', 'COMPLETED', 'CANCELLED') NOT NULL DEFAULT 'PENDING',
                              notes TEXT,
                              created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                              updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

                              CONSTRAINT fk_res_client FOREIGN KEY (client_id) REFERENCES users(id) ON DELETE RESTRICT,
                              CONSTRAINT fk_res_carver FOREIGN KEY (carver_id) REFERENCES carvers(id) ON DELETE RESTRICT,
                              CONSTRAINT fk_res_service FOREIGN KEY (service_id) REFERENCES services(id) ON DELETE RESTRICT,

    -- CHECK: Horas entre 10 y 17, y minutos 00 o 30.
                              CONSTRAINT chk_res_hours CHECK (HOUR(start_time) BETWEEN 10 AND 17 AND MINUTE(start_time) IN (0, 30)),
    -- CHECK: Solo Lunes (2) a Viernes (6)
                              CONSTRAINT chk_res_weekday CHECK (DAYOFWEEK(reservation_date) BETWEEN 2 AND 6),
    -- NOTA: La validación de fecha futura (>= CURDATE) se hará en Java.

                              CONSTRAINT uk_reservation_slot UNIQUE (carver_id, reservation_date, start_time)
) ENGINE=InnoDB;

CREATE INDEX idx_res_client_date ON reservations(client_id, reservation_date);
CREATE INDEX idx_res_carver_date_status ON reservations(carver_id, reservation_date, status);

-- ============================================================
-- 5. NOTIFICATIONS
-- ============================================================
CREATE TABLE notifications (
                               id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
                               reservation_id BIGINT UNSIGNED,
                               recipient_type ENUM('CLIENT', 'CARVER', 'ADMIN') NOT NULL,
                               recipient_email VARCHAR(150) NOT NULL,
                               notification_type ENUM('CREATED', 'MODIFIED', 'CANCELLED', 'REMINDER') NOT NULL,
                               subject VARCHAR(255) NOT NULL,
                               message TEXT NOT NULL,
                               is_sent BOOLEAN DEFAULT TRUE,
                               sent_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

                               CONSTRAINT fk_notif_reservation FOREIGN KEY (reservation_id) REFERENCES reservations(id) ON DELETE SET NULL
) ENGINE=InnoDB;

-- ============================================================
-- ADMIN
-- ============================================================
INSERT INTO users (dni, first_name, last_name, email, phone, password_hash, role, is_active)
VALUES ('12345678A', 'System', 'Administrator', 'admin@hambooking.com', '600000000', '$2a$10$N9qo8uLOickgx2ZMRZoMy.MqrqQzBZN0UfGNEsKYGs5qJ8fJ6ZzWq', 'ADMIN', TRUE);