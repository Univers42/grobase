# Documentación para la Memoria del TFG

---

# **Título: 4.2. Diseño e Implementación del Modelo Relacional (MySQL)**

---

## **Objetivo**

Diseñar e implementar el modelo de datos relacional del sistema Hambooking, garantizando la integridad referencial, la coherencia de las reglas de negocio y la optimización del acceso a datos mediante índices y restricciones estructurales.

---

## **Desarrollo**

Se ha procedido al diseño del esquema relacional sobre el SGBD **MySQL 8.0.45**, utilizando el motor de almacenamiento InnoDB para asegurar soporte completo de claves foráneas y transacciones ACID.

El modelo implementado responde al análisis previo de requisitos funcionales y se compone de cinco entidades principales:

1. `users`
2. `carvers`
3. `services`
4. `reservations`
5. `notifications`

El script final (`schema.sql`, versión 1.3) crea la base de datos `hambooking` con codificación `utf8mb4` y colación `utf8mb4_unicode_ci`, garantizando compatibilidad internacional y correcta gestión de caracteres especiales.

---

## 1. Normalización y Diseño del Modelo

El modelo ha sido diseñado siguiendo principios de normalización hasta **Tercera Forma Normal (3FN)**:

* Eliminación de redundancias.
* Separación de entidades conceptualmente independientes.
* Uso de claves primarias y foráneas para establecer relaciones.

### Relaciones principales:

* Un **usuario** puede ser cliente o administrador.
* Un **cortador** es una extensión especializada de un usuario (relación 1:1).
* Un **cliente** puede realizar múltiples reservas (1:N).
* Un **cortador** puede atender múltiples reservas (1:N).
* Una **reserva** pertenece a un único servicio.
* Una **reserva** puede generar múltiples notificaciones (1:N).

Este diseño garantiza un modelo consistente, extensible y desacoplado.

---

## 2. Integridad de Datos

Se han implementado distintos niveles de protección estructural:

### 2.1 Claves Primarias (PK)

Todas las tablas utilizan:

```sql
BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY
```

Esto permite escalabilidad futura sin riesgo de desbordamiento prematuro.

---

### 2.2 Claves Foráneas (FK)

Se han definido restricciones de integridad referencial con distintas políticas:

* `ON DELETE CASCADE` en `carvers` (si se elimina el usuario, se elimina el cortador).
* `ON DELETE RESTRICT` en `reservations` para preservar histórico.
* `ON DELETE SET NULL` en `notifications` para conservar el log aunque la reserva sea eliminada.

Esto garantiza coherencia sin pérdida accidental de información crítica.

---

### 2.3 Restricciones UNIQUE

Se han definido claves únicas para proteger datos sensibles:

* DNI único.
* Email único.
* Slot de reserva único (`carver_id + reservation_date + start_time`).

Este último implementa una regla de negocio crítica: **no puede existir doble reserva para un mismo cortador en el mismo horario.**

---

### 2.4 Restricciones CHECK

Se han incorporado validaciones estructurales directamente en base de datos:

* Formato de DNI mediante expresión regular.
* Duración de servicio mayor que cero.
* Precio base no negativo.
* Horario laboral restringido (10:00–17:30).
* Reservas únicamente de lunes a viernes.

La validación de fecha futura se delega a la capa de negocio en Java, ya que MySQL no permite funciones no deterministas en CHECK constraints.

---

## 3. Optimización mediante Índices

Se han creado índices compuestos estratégicos para mejorar rendimiento en consultas frecuentes:

* Búsqueda de reservas por cliente y fecha.
* Consulta de disponibilidad por cortador.
* Filtrado por estado.

Esto permite que futuras consultas desde la API REST sean eficientes incluso con grandes volúmenes de datos.

---

## 4. Seed Data Inicial

Se han insertado:

* Tres servicios predefinidos (Jamón, Paleta, Embutidos).
* Un usuario administrador inicial.

Esto permite validar rápidamente el sistema tras el despliegue.

---

## 5. Pruebas de Integridad (Testing Manual del Modelo)

Se ha realizado una batería de pruebas manuales desde cliente SQL para verificar:

* Rechazo de duplicados.
* Rechazo de horarios inválidos.
* Rechazo de reservas en fin de semana.
* Rechazo de claves foráneas inexistentes.
* Validación correcta de ENUM.
* Restricción de borrado con reservas asociadas.

El resultado ha sido consistente: todas las restricciones funcionan conforme a los requisitos del sistema.

---

## 6. Principios Aplicados

El diseño implementa los siguientes principios de ingeniería:

* **Integridad estructural primero.**
* **Reglas críticas reforzadas a nivel de base de datos.**
* **Separación de responsabilidades (BD vs lógica de negocio).**
* **Preparación para integración con JPA/Hibernate.**

---

## 7. Conclusión

Con la finalización de esta fase, el proyecto dispone de un modelo relacional robusto, normalizado y protegido frente a inconsistencias estructurales.

La base de datos se encuentra validada y preparada para su integración con la capa de persistencia del backend desarrollado en Spring Boot.

---

## ✅ Cierre del Issue #5

Se considera completada la implementación del subsistema de persistencia a nivel estructural, quedando listo el entorno para el mapeo de entidades JPA y desarrollo de la lógica de negocio.
