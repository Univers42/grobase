Perfecto. Vamos a hacerlo bien y con mentalidad estratégica:
primero dejamos **la propuesta completa cerrada y lista para enviar**, y después atacamos la entrega intermedia (casos de uso + clases + estructura de memoria).

Voy a actualizarte todo de forma formal, redactado para copiar y pegar.

---

# 📄 PROPUESTA COMPLETA ACTUALIZADA

---

## 🏷️ Título del proyecto

**HamBooking – Sistema de Gestión de Reservas para Cortadores de Jamón**

---

## 📌 Resumen del proyecto

HamBooking es una aplicación cliente-servidor desarrollada en Java que permite la gestión integral de reservas para cortadores profesionales de jamón en un entorno comercial.

El sistema incluye gestión de usuarios (administrador y clientes), gestión de cortadores como recursos profesionales, catálogo de servicios predefinidos y control de reservas con validaciones de disponibilidad, horarios y límites de uso.

La aplicación consta de un backend REST desarrollado con Spring Boot y persistencia mediante JPA/Hibernate y MySQL, y un frontend de escritorio desarrollado con JavaFX que consume la API mediante HTTP y JSON.

---

## 🛠 Tecnologías y herramientas utilizadas

### BACKEND

* Lenguaje: Java
* Framework: Spring Boot
* ORM: Hibernate / JPA
* Base de datos: MySQL 8
* Gestión de dependencias: Maven
* Testing: JUnit
* Control de versiones: Git / GitHub
* Despliegue: Tomcat embebido
* IDE: IntelliJ IDEA

### FRONTEND

* Tipo: Aplicación de escritorio
* Framework: JavaFX
* Lenguaje: Java
* Consumo API REST: HttpClient (java.net.http)
* IDE: IntelliJ IDEA

### ARQUITECTURA

* Cliente–Servidor REST
* Comunicación HTTP + JSON
* Separación por capas (Controller – Service – Repository)

---

# 📚 Relación con los módulos del ciclo formativo

El proyecto integra competencias de todos los módulos del ciclo DAM:

* **M01 Sistemas informáticos:** Configuración de entorno, despliegue, gestión de servidor.
* **M02 Digitalización aplicada:** Transformación digital de un negocio tradicional.
* **M03 Itinerario empleabilidad I:** Planificación con GitHub Projects y gestión del proyecto.
* **M04A / M04B Programación:** Programación orientada a objetos, arquitectura por capas, gestión de excepciones.
* **M05A / M05B Bases de datos:** Diseño E-R, normalización, constraints, índices y optimización.
* **M06 Lenguajes de marcas:** Uso de JSON y configuración estructurada.
* **M07 Entornos de desarrollo:** Uso profesional de IntelliJ, Maven, Git y JUnit.
* **M08 Inglés profesional:** Código y documentación técnica en inglés.
* **M09 Sostenibilidad:** Reducción de procesos manuales y optimización de recursos.
* **M10 Acceso a datos:** Persistencia con JPA/Hibernate.
* **M11 Desarrollo de interfaces:** Interfaz gráfica con JavaFX.
* **M12 Sistemas de gestión empresarial:** Gestión de clientes, recursos y servicios.
* **M13 Itinerario empleabilidad II:** Documentación y defensa profesional del proyecto.
* **M14 Optativa:** Aplicación práctica según módulo cursado.
* **M15 Programación multimedia y móviles:** Arquitectura REST preparada para consumo multiplataforma.
* **M16 Programación de servicios y procesos:** Implementación de API REST y lógica de negocio.

---

# 🎯 Objetivos del proyecto

## Objetivo general

Desarrollar un sistema software completo que permita gestionar de forma digital las reservas de servicios de corte profesional de jamón, optimizando la organización del negocio y garantizando la integridad y coherencia de los datos.

---

## Objetivos específicos

1. Implementar un sistema de autenticación y control de roles (ADMIN y CLIENT).
2. Permitir al administrador gestionar cortadores y servicios.
3. Diseñar un sistema de reservas con control de disponibilidad por fecha y hora.
4. Implementar validaciones de negocio:

   * Horario laboral (lunes a viernes 10:00–18:00).
   * Slots de 30 minutos.
   * Prevención de solapamientos.
   * Límites de reservas por cliente y por cortador.
5. Implementar persistencia mediante JPA/Hibernate.
6. Desarrollar una API REST documentada y estructurada.
7. Crear una interfaz gráfica funcional en JavaFX.
8. Implementar registro de notificaciones simuladas.
9. Garantizar integridad mediante constraints en base de datos.
10. Aplicar buenas prácticas de desarrollo y control de versiones.

---

# 🧩 Justificación de la elección de la temática

Se ha elegido este proyecto por representar un caso realista de digitalización de un pequeño negocio tradicional, permitiendo aplicar de forma transversal conocimientos adquiridos durante el ciclo formativo.

El proyecto permite integrar desarrollo backend, frontend, bases de datos y arquitectura cliente-servidor en una solución coherente y profesional.

Además, aporta experiencia práctica en el diseño de sistemas empresariales, planificación de proyectos y aplicación de buenas prácticas de ingeniería del software.

---

# ✅ Propuesta lista para enviar

Esta versión ya está completamente formal y alineada con normativa académica.
Es apta para entrega.

---

---

# 🚀 Ahora vamos con la ENTREGA INTERMEDIA

El profesor revisará especialmente:

* Diagrama de Casos de Uso
* Diagrama Entidad–Relación
* Diagrama de Clases
* Estructura de la memoria

El ER ya lo tienes sólido.
Ahora necesitamos preparar los otros dos bien.

---

# 📌 1️⃣ DIAGRAMA DE CASOS DE USO

Actores:

* Administrador
* Cliente

Casos principales:

ADMIN:

* Gestionar cortadores
* Gestionar servicios
* Consultar reservas
* Cambiar estado de reserva

CLIENTE:

* Registrarse
* Iniciar sesión
* Consultar disponibilidad
* Crear reserva
* Modificar reserva
* Cancelar reserva
* Consultar historial

Si quieres, en el siguiente mensaje te lo genero en Mermaid listo para memoria.

---

# 📌 2️⃣ DIAGRAMA DE CLASES

Debe incluir:

Entidades principales:

* User
* Carver
* Service
* Reservation
* Notification

Y además:

* UserService
* ReservationService
* UserRepository
* ReservationRepository
* Controllers

Aquí debemos decidir:

👉 ¿Quieres diagrama conceptual (modelo dominio)?
👉 ¿O diagrama técnico incluyendo capas?

Para entrega intermedia normalmente se pide modelo de clases del dominio.

---

# 📌 3️⃣ ESTRUCTURA DE LA MEMORIA

Recomendada:

1. Introducción
2. Justificación
3. Objetivos
4. Análisis del sistema

   * Requisitos funcionales
   * Requisitos no funcionales
   * Casos de uso
5. Diseño

   * Arquitectura
   * Diagrama ER
   * Diagrama de clases
6. Implementación
7. Pruebas
8. Conclusiones
9. Anexos

---

# 🎯 Siguiente movimiento estratégico

Te propongo este orden:

1. Generamos Diagrama de Casos de Uso
2. Generamos Diagrama de Clases
3. Te estructuro la memoria para la entrega intermedia

Y así envías una entrega muy por encima de la media.

¿Empezamos por el diagrama de casos de uso?
