Esta es la versión definitiva y "blindada" de tu propuesta. He integrado **explícitamente** las 17 asignaturas (Módulos) del ciclo en la redacción para garantizar que el tutor vea reflejada la totalidad del currículo en tu proyecto.

Copia y pega el siguiente contenido en tu plantilla. Los textos entre paréntesis son notas para ti, bórralas antes de enviar.

***

### **Propuesta de Proyecto DAM: JamonBooking**

**Título del proyecto:**
Sistema de Gestión de Reservas para Cortadores de Jamón (JamonBooking).

**Resumen del proyecto:**
JamonBooking es una solución software multiplataforma de escritorio diseñada bajo una arquitectura cliente-servidor para la gestión integral de reservas de servicios de corte de jamón. La aplicación digitaliza un proceso de negocio tradicional, permitiendo la gestión de citas en tiempo real, control de disponibilidad de cortadores y administración de clientes. El sistema centraliza la información en una base de datos relacional y ofrece una interfaz gráfica moderna y usable, cumpliendo con los estándares de desarrollo empresarial actuales.

**Tecnologías, herramientas y relación con los módulos del ciclo:**
El proyecto integra de forma transversal las competencias adquiridas en todos los módulos del ciclo formativo:

*   **Infraestructura y Sistemas (M01, M02, M09):** La aplicación se desplegará sobre la JVM (Java Virtual Machine), garantizando la ejecución multiplataforma estudiada en *Sistemas Informáticos*. El proyecto impulsa la *Digitalización* de un sector tradicional (corte de jamón) eliminando el uso de papel, alineándose con la *Sostenibilidad* al optimizar recursos y procesos de gestión (ODS 12).
*   **Desarrollo de Software (M04A, M04B, M16):** El núcleo se desarrollará en **Java**, aplicando POO, estructuras de control y gestión de excepciones vistas en *Programación A y B*. La arquitectura Cliente-Servidor mediante API REST con **Spring Boot** implementará conceptos de *Programación de Servicios y Procesos*, gestionando la concurrencia de peticiones y el intercambio de datos mediante HTTP/JSON.
*   **Datos y Persistencia (M05A, M05B, M10):** Se utilizará **MySQL** como SGBD. El diseño del modelo E/R garantizará la normalización e integridad referencial (*Bases de Datos A y B*). Para la persistencia, se empleará **Hibernate/JPA** (*Acceso a Datos*), solucionando el desfase objeto-relacional y gestionando transacciones de forma transparente.
*   **Interfaz y Experiencia de Usuario (M11, M15):** El cliente se desarrollará con **JavaFX**, aplicando patrones de diseño y usabilidad de *Desarrollo de Interfaces*. Aunque es una aplicación de escritorio, la arquitectura REST está preparada para una futura integración móvil, aplicando conceptos de arquitectura modular vistos en *Programación Multimedia*.
*   **Gestión y Herramientas (M06, M07, M12):** Se utilizará **XML** para la configuración de dependencias en **Maven** (*Lenguajes de Marcas*). El ciclo de vida se gestionará en **IntelliJ IDEA**, con control de versiones en **Git/GitHub** y pruebas unitarias con **JUnit** (*Entornos de Desarrollo*). El sistema actúa como un mini-ERP vertical (*Sistemas de Gestión Empresarial*), centralizando recursos y clientes.
*   **Transversalidad (M03, M08, M13, M14):** El código fuente y la documentación técnica de las librerías se manejarán en inglés (*Inglés Profesional*). El proyecto simula un emprendimiento real, aplicando competencias de *Itinerario Personal para la Empleabilidad*, y profundiza en el uso de Frameworks empresariales (Spring) como contenido de especialización (*Módulo Optativo*).

**Objetivos:**
*Objetivos Generales:*
*   Desarrollar una aplicación de escritorio funcional que automatice el flujo completo de reserva de servicios profesionales.
*   Implementar una arquitectura por capas robusta que separe la lógica de negocio, la persistencia y la presentación.

*Objetivos Específicos:*
1.  Implementar un sistema de seguridad y autenticación (Login) diferenciando roles de Administrador y Cliente.
2.  Desarrollar un CRUD completo para la gestión de "Cortadores", incluyendo sus horarios y disponibilidad.
3.  Crear una interfaz gráfica en JavaFX con un calendario interactivo para la selección de slots de tiempo.
4.  Programar validaciones de negocio en el backend (Spring Boot) para controlar límites (máx. 2 reservas/día por cliente) y evitar solapamientos.
5.  Gestionar estados de reservas (Pendiente, Confirmada, Cancelada) asegurando la integridad de los datos.
6.  Generar notificaciones (logs) y reportes de actividad del sistema.

**Justificación de la elección de la temática:**
He elegido este proyecto por su capacidad para unificar una lógica de negocio compleja con una interfaz de usuario rica. Permite simular un entorno de producción real donde es necesario controlar la concurrencia (varios clientes reservando a la vez) y la integridad de los datos.
Técnicamente, el stack **Spring Boot + JavaFX** es una combinación potente que me permite demostrar un dominio completo del lenguaje Java (Full Stack), desde el backend empresarial hasta el frontend de escritorio, competencias altamente demandadas que justifican la integración de todos los módulos del ciclo.

***

### 📝 Resumen de cómo hemos "colado" todas las asignaturas:

1.  **M01 Sistemas:** Justificado con la JVM y multiplataforma.
2.  **M02 Digitalización:** Justificado como transformación digital del negocio.
3.  **M03/M13 IPE:** Justificado como emprendimiento/simulación profesional.
4.  **M04A/B Programación:** Java base y POO.
5.  **M05A/B Bases de Datos:** MySQL, integridad y normalización.
6.  **M06 Lenguajes de Marcas:** XML de Maven y configuración.
7.  **M07 Entornos:** IntelliJ, Git y JUnit.
8.  **M08 Inglés:** Código en inglés y lectura de documentación.
9.  **M09 Sostenibilidad:** Eliminación de papel (procesos digitales).
10. **M10 Acceso a Datos:** Hibernate/JPA.
11. **M11 Interfaces:** JavaFX y usabilidad.
12. **M12 SGE:** Concepto de mini-ERP (gestión de recursos).
13. **M14 Optativa:** El uso avanzado de Spring Boot.
14. **M15 Multimedia:** Arquitectura preparada para móvil/reutilización de backend.
15. **M16 Servicios:** API REST y concurrencia.

¡Con esto tienes el **APTO** asegurado en la propuesta!