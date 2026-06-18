# PROPUESTA DE TEMA
## PROYECTO FIN DE CICLO - DAM
### Semestre: 2S2526

---

## 📌 TÍTULO DEL PROYECTO

**JamonBooking - Sistema de Gestión de Reservas para Cortadores de Jamón Serrano**

---

## 📝 RESUMEN DEL PROYECTO

JamonBooking es una aplicación de escritorio con arquitectura cliente-servidor que permite gestionar reservas de servicios de corte de jamón, paleta y embutidos en una tienda especializada. El sistema incluye tres roles diferenciados (Administrador único, Cortadores y Clientes), un calendario interactivo con disponibilidad en tiempo real basado en slots de 30 minutos, control automático de límites de reservas (máximo 2 diarias y 4 semanales por cliente), y gestión completa de estados de reservas (Pendiente, Confirmada, Realizada, Cancelada). Los clientes podrán registrarse automáticamente, visualizar la disponibilidad de cortadores por fecha, realizar reservas con validaciones de horario y capacidad, y modificar o cancelar sus citas con un día de antelación. El administrador tendrá control total sobre cortadores, usuarios y reservas, garantizando la operatividad del negocio mediante la gestión de recursos humanos especializados.

---

## 🛠️ TECNOLOGÍAS Y HERRAMIENTAS QUE SE UTILIZARÁN

### **Tecnologías y herramientas que se utilizarán:**
| Tecnología | Módulo del ciclo relacionado | Justificación / Relación |
|------------|------------------------------|--------------------------|
| **Java 17** | Programación (M03, M06), Programación Multimedia (M08) | Lenguaje principal del ciclo, usado tanto en backend como en frontend (JavaFX). |
| **Spring Boot** | Acceso a Datos (M07), Programación de Servicios (M09) | Framework empresarial para creación de APIs REST. Se relaciona directamente con el desarrollo de servicios web y capa de persistencia. |
| **Hibernate / JPA** | Acceso a Datos (M07) | ORM estándar para el mapeo objeto-relacional. Aplicado en la capa de persistencia con MySQL. |
| **MySQL** | Bases de Datos (M04) | Sistema gestor de bases de datos relacional. Se diseñará una BD con al menos 5 tablas relacionadas. |
| **Maven** | Entornos de Desarrollo (M02) | Herramienta de gestión de dependencias y construcción del proyecto. |
| **JUnit 5** | Programación (M03, M06), Acceso a Datos (M07) | Framework de pruebas unitarias para garantizar la calidad del código backend. |
| **Git / GitHub** | Entornos de Desarrollo (M02) | Control de versiones y trabajo colaborativo, aunque sea individual, siguiendo buenas prácticas profesionales. |
| **JavaFX** | Desarrollo de Interfaces (M05) | Framework sucesor de Swing para interfaces de escritorio modernas. Se justifica por su capacidad de crear UIs atractivas con FXML y CSS. |
| **Scene Builder** | Desarrollo de Interfaces (M05) | Herramienta visual para diseñar las pantallas JavaFX de forma ágil. |
| **RestTemplate / HttpClient** | Acceso a Datos (M07), Programación de Servicios (M09) | Cliente HTTP para consumir la API REST desde la aplicación de escritorio. |
| **IntelliJ IDEA** | Entornos de Desarrollo (M02) | IDE profesional con soporte completo para Spring Boot y JavaFX. |

### **Backend - Servidor API REST**

**Lenguaje de Programación:**
- **Java 17** (Módulo: Programación / Programación Multimedia y Dispositivos Móviles)
  - Lenguaje principal del ciclo formativo, permitiendo aplicar conceptos de POO, colecciones, excepciones y programación funcional.

**Framework y Persistencia:**
- **Spring Boot 3.x** (Módulo: Programación de Servicios y Procesos / Acceso a Datos)
  - Spring Web MVC: Para crear controladores REST que expongan endpoints HTTP.
  - Spring Data JPA: Abstracción sobre Hibernate para operaciones CRUD simplificadas.
  - Spring Security: Gestión de autenticación y autorización basada en roles.
  - Spring Validation: Validación de datos de entrada en DTOs.

- **Hibernate / JPA** (Módulo: Acceso a Datos)
  - ORM que mapea entidades Java a tablas relacionales, gestionando relaciones 1:N y N:M.
  - Permite aplicar conceptos de persistencia, transacciones y consultas con JPQL/Criteria API.

**Base de Datos:**
- **MySQL 8** (Módulo: Bases de Datos)
  - SGBD relacional para almacenar usuarios, cortadores, reservas, servicios y notificaciones.
  - Diseño con mínimo 3 tablas relacionadas mediante claves foráneas (FK).
  - Implementación de constraints, índices y normalización hasta 3FN.

**Gestión de Dependencias:**
- **Maven** (Módulo: Entornos de Desarrollo)
  - Gestión automática de librerías (Spring, Hibernate, MySQL Connector, JUnit).
  - Estructura de proyecto estándar con `pom.xml`.

**Testing:**
- **JUnit 5** (Módulo: Entornos de Desarrollo)
  - Pruebas unitarias de servicios y lógica de negocio.
  - Validación de casos críticos: disponibilidad de slots, límites de reservas, solapamientos.

**Servidor de Aplicaciones:**
- **Tomcat Embebido** (integrado en Spring Boot)
  - Despliegue simplificado sin configuración externa de servidor.

---

### **Frontend - Aplicación de Escritorio**

**Framework GUI:**
- **JavaFX 17** (Módulo: Desarrollo de Interfaces / Programación Multimedia y Dispositivos Móviles)
  - Framework moderno para aplicaciones de escritorio, sucesor oficial de Swing (incluido en normativa).
  - Diseño declarativo mediante FXML, separación MVC, soporte CSS para estilos.
  - **Justificación:** Aunque no está explícitamente en el listado de tecnologías válidas, JavaFX es el sucesor oficial de Swing (que sí está incluido). Ofrece capacidades modernas de UI (animaciones, componentes ricos, integración con Scene Builder) manteniendo Java como lenguaje único, lo que simplifica el desarrollo y demuestra coherencia tecnológica en todo el stack.

**Herramientas de Diseño:**
- **Scene Builder** (Módulo: Desarrollo de Interfaces)
  - Diseño visual drag-and-drop de interfaces mediante archivos FXML.
  - Acelera el desarrollo de vistas sin sacrificar calidad.

**Consumo de API REST:**
- **HttpClient (java.net.http)** o **RestTemplate (Spring)**
  - Cliente HTTP para comunicación con el backend mediante JSON.
  - Implementación de peticiones GET, POST, PUT, DELETE.

---

### **Arquitectura General**

**Patrón Arquitectónico:**
- **Cliente-Servidor REST** (Módulo: Sistemas de Gestión Empresarial)
  - Separación clara entre presentación (JavaFX) y lógica/datos (Spring Boot).
  - Comunicación mediante protocolo HTTP con formato JSON.
  - API RESTful siguiendo principios de stateless y recursos bien definidos.

**Control de Versiones:**
- **Git / GitHub** (Módulo: Entornos de Desarrollo)
  - Control de versiones distribuido con repositorio remoto.
  - Historial completo de cambios, ramas para desarrollo y producción.

**Entorno de Desarrollo:**
- **IntelliJ IDEA Community/Ultimate** (Módulo: Entornos de Desarrollo)
  - IDE profesional con soporte integrado para Spring Boot, JavaFX, Maven y Git.

---

### **Relación con Módulos del Ciclo (Resumen)**

| Módulo | Tecnologías Aplicadas |
|--------|----------------------|
| **Programación** | Java 17, POO, Colecciones, Excepciones |
| **Bases de Datos** | MySQL, SQL, Normalización, ER |
| **Acceso a Datos** | Hibernate, JPA, Spring Data, JDBC |
| **Desarrollo de Interfaces** | JavaFX, FXML, Scene Builder, CSS |
| **Programación Multimedia** | JavaFX, Manejo de eventos, Hilos |
| **Programación de Servicios** | Spring Boot, API REST, HTTP, JSON |
| **Sistemas de Gestión Empresarial** | Arquitectura Cliente-Servidor, MVC |
| **Entornos de Desarrollo** | IntelliJ IDEA, Maven, Git, JUnit |

---

## 🎯 OBJETIVOS

### **Objetivos Generales**

1. **Desarrollar una aplicación completa con arquitectura cliente-servidor REST** que demuestre la integración de tecnologías backend (Spring Boot, JPA, MySQL) y frontend (JavaFX), aplicando los conocimientos adquiridos en todos los módulos del ciclo formativo.

2. **Automatizar la gestión de reservas de servicios especializados** mediante un sistema que optimice la asignación de recursos humanos, controle disponibilidad en tiempo real y prevenga conflictos de horarios, reduciendo errores manuales y mejorando la experiencia del cliente.

3. **Implementar un sistema robusto de autenticación y autorización** con roles diferenciados que garantice la seguridad de los datos y la correcta segregación de funcionalidades según el tipo de usuario.

### **Objetivos Específicos (Funcionalidades Concretas)**

1. **Gestión completa de cortadores:** El administrador puede crear, modificar, consultar y desactivar cortadores de jamón, asignándoles datos profesionales (experiencia, especialidad) y manteniendo un mínimo de 1 cortador activo para operatividad del sistema.

2. **Registro automático de clientes:** Los usuarios pueden registrarse en la aplicación mediante un formulario con validación automática de datos (DNI único, email válido, teléfono, contraseña segura) sin intervención del administrador.

3. **Sistema de autenticación con roles:** Implementar login seguro con encriptación BCrypt y control de acceso diferenciado para Administrador (acceso total), Cortadores (solo notificaciones) y Clientes (gestión personal de reservas).

4. **Calendario de disponibilidad interactivo:** Los clientes pueden visualizar en tiempo real los slots disponibles de cada cortador por fecha, mostrando horarios libres (L-V 10:00-18:00) divididos en bloques de 30 minutos.

5. **Creación de reservas con validaciones:** Los clientes pueden reservar servicios (Corte de Jamón 2h, Paleta 1h, Embutido 30min) seleccionando cortador, fecha y horario, con validaciones automáticas de disponibilidad, límites diarios/semanales y capacidad del cortador.

6. **Gestión de estados de reserva:** El sistema maneja automáticamente cuatro estados (Pendiente, Confirmada, Realizada, Cancelada) con transiciones controladas y actualización diaria de reservas pasadas mediante tareas programadas.

7. **Modificación y cancelación de reservas:** Clientes y administrador pueden modificar o cancelar reservas con mínimo 1 día de antelación, liberando automáticamente los slots del cortador y notificando a los afectados.

8. **Control de límites por cliente:** Validar automáticamente que cada cliente no exceda 2 reservas diarias ni 4 semanales, evitando acaparamiento de turnos y garantizando equidad en el acceso al servicio.

9. **Control de carga de trabajo por cortador:** Limitar a 3 servicios de jamón diarios por cortador (máximo 6 horas efectivas), previniendo sobrecarga y asegurando calidad del servicio.

10. **Historial completo de reservas:** Los clientes pueden consultar sus reservas pasadas, futuras y canceladas, con filtros por estado y fecha, facilitando seguimiento de su actividad.

11. **Sistema de notificaciones simuladas:** Generar logs detallados de notificaciones por email al crear, modificar o cancelar reservas, dirigidas a cliente, cortador asignado y administrador.

12. **Panel de administración integral:** El administrador accede a un dashboard con CRUD completo de usuarios, cortadores y reservas, con capacidad de intervenir en cualquier operación del sistema.

13. **Prevención de solapamientos:** Implementar algoritmos de validación que verifiquen en tiempo real que no existan conflictos de horarios al asignar un cortador, consultando la base de datos y bloqueando slots ocupados.

14. **Bloqueo del sistema sin cortadores:** Si no hay cortadores activos, deshabilitar automáticamente las opciones de reserva tanto para clientes como administrador, mostrando mensaje informativo.

---

## 💡 JUSTIFICACIÓN DE LA ELECCIÓN DE LA TEMÁTICA

### **Motivación Personal**

He elegido este proyecto porque representa un **caso de uso real** aplicable a pequeños negocios especializados (tiendas de jamón, peluquerías, talleres, clínicas) que actualmente gestionan citas de forma manual o con herramientas genéricas no adaptadas a sus necesidades. La temática del corte de jamón es **original y diferenciadora** respecto a los típicos proyectos de bibliotecas o tiendas online, lo que hace que el TFG sea más memorable y demuestre creatividad en la concepción del problema a resolver.

Además, me permite aplicar de forma práctica **todos los conocimientos adquiridos en el ciclo**, desde diseño de bases de datos relacionales y modelado de entidades complejas, hasta arquitecturas cliente-servidor modernas con APIs REST, pasando por desarrollo de interfaces gráficas profesionales con JavaFX. La gestión de disponibilidad con slots de tiempo, control de límites y prevención de solapamientos supone un **reto técnico interesante** que va más allá de CRUDs básicos, requiriendo lógica de negocio robusta y validaciones complejas.

### **Aportación del Proyecto**

Con este proyecto aporto una **solución tecnológica completa y funcional** que podría implementarse en negocios reales, optimizando la gestión de recursos humanos especializados y mejorando la experiencia del cliente al eliminar llamadas telefónicas, esperas innecesarias y errores de doble reserva. El sistema automatiza procesos que actualmente son manuales, reduciendo la carga administrativa y permitiendo al negocio escalar sin necesidad de más personal de gestión.

Desde el punto de vista técnico, aporto un **proyecto bien arquitecturado** que sigue buenas prácticas de ingeniería de software: separación de capas (presentación, negocio, datos), uso de patrones de diseño (MVC, DAO, DTO), código limpio y mantenible, y testing automatizado que garantiza la calidad del software.

### **Aprendizaje Esperado**

Realizar este proyecto me permitirá **consolidar y profundizar** en tecnologías clave del ecosistema Java empresarial que son altamente demandadas en el mercado laboral: Spring Boot (el framework más usado para backend en Java), JPA/Hibernate (estándar de facto para persistencia), arquitecturas REST (fundamentales en desarrollo moderno), y desarrollo de aplicaciones de escritorio profesionales con JavaFX.

Además, me enfrentaré a **desafíos reales de lógica de negocio** como el cálculo de disponibilidad en calendarios con restricciones múltiples, gestión de estados con transiciones complejas, validaciones multicapa (frontend, backend, base de datos), y manejo de concurrencia en reservas simultáneas. Estos problemas requieren pensamiento algorítmico, capacidad de abstracción y diseño de soluciones eficientes.

Finalmente, el proyecto me aportará un **portfolio profesional demostrable** que incluye tanto capacidades técnicas (dominio del stack Java/Spring/JavaFX) como habilidades de análisis (requisitos funcionales/no funcionales, diagramas ER, casos de uso) y documentación (memoria técnica completa, manuales de usuario), competencias esenciales para incorporarme con éxito al mercado laboral como desarrollador de aplicaciones multiplataforma.

---

## ✅ CUMPLIMIENTO DE NORMATIVA

- ✅ Aplicación **no publicada previamente** en ningún portal o plataforma
- ✅ **No forma parte** de ejemplos, ejercicios o actividades del ciclo
- ✅ Proyecto **original** y de **elaboración propia**
- ✅ Base teórica de **múltiples módulos** del ciclo formativo
- ✅ Tecnologías del **listado válido** (Spring Boot, Hibernate, JPA, MySQL, Java)
- ✅ **JavaFX justificado** como sucesor de Swing
- ✅ Mínimo **3 tablas relacionadas** en la base de datos (Usuario, Cortador, Reserva, Servicio, Notificación)
- ✅ Complejidad adecuada para demostrar conocimientos del ciclo completo

---

**Alumno/a:** [Tu Nombre y Apellidos]
**Semestre:** 1S2526
**Fecha de entrega propuesta:** [Fecha entre 29 sept - 16 oct 2025]

---

Por supuesto, con toda la información que hemos detallado, podemos rellenar perfectamente la plantilla de propuesta. Aquí tienes las respuestas listas para copiar y pegar directamente en el formulario de entrega.

---

## 📋 **PROPUESTA DE PROYECTO FINAL DE CICLO (DAM)**

---

### **Título del proyecto:**
**JamonBooking – Sistema de Gestión de Reservas para Servicios de Corte de Jamón**

---

### **Resumen del proyecto:**
JamonBooking es una aplicación de escritorio con arquitectura cliente-servidor REST que permite gestionar reservas de servicios de corte de jamón, paleta y embutidos en una tienda especializada. El sistema cuenta con tres roles: administrador (único), cortadores (recurso gestionado) y clientes (usuarios registrados). Los clientes pueden consultar la disponibilidad de cortadores mediante un calendario interactivo de slots de 30 minutos, realizar reservas con límites diarios y semanales, y cancelar o modificar sus citas con 24 horas de antelación. El administrador gestiona el alta/baja de cortadores, asigna horarios fijos semanales y supervisa todas las reservas. Las notificaciones se simulan mediante un sistema de logs en base de datos. Todo el desarrollo sigue una arquitectura limpia y profesional, utilizando tecnologías estándar del sector.

---

### **Tecnologías y herramientas que se utilizarán:**
| Tecnología | Módulo del ciclo relacionado | Justificación / Relación |
|------------|------------------------------|--------------------------|
| **Java 17** | Programación (M03, M06), Programación Multimedia (M08) | Lenguaje principal del ciclo, usado tanto en backend como en frontend (JavaFX). |
| **Spring Boot** | Acceso a Datos (M07), Programación de Servicios (M09) | Framework empresarial para creación de APIs REST. Se relaciona directamente con el desarrollo de servicios web y capa de persistencia. |
| **Hibernate / JPA** | Acceso a Datos (M07) | ORM estándar para el mapeo objeto-relacional. Aplicado en la capa de persistencia con MySQL. |
| **MySQL** | Bases de Datos (M04) | Sistema gestor de bases de datos relacional. Se diseñará una BD con al menos 5 tablas relacionadas. |
| **Maven** | Entornos de Desarrollo (M02) | Herramienta de gestión de dependencias y construcción del proyecto. |
| **JUnit 5** | Programación (M03, M06), Acceso a Datos (M07) | Framework de pruebas unitarias para garantizar la calidad del código backend. |
| **Git / GitHub** | Entornos de Desarrollo (M02) | Control de versiones y trabajo colaborativo, aunque sea individual, siguiendo buenas prácticas profesionales. |
| **JavaFX** | Desarrollo de Interfaces (M05) | Framework sucesor de Swing para interfaces de escritorio modernas. Se justifica por su capacidad de crear UIs atractivas con FXML y CSS. |
| **Scene Builder** | Desarrollo de Interfaces (M05) | Herramienta visual para diseñar las pantallas JavaFX de forma ágil. |
| **RestTemplate / HttpClient** | Acceso a Datos (M07), Programación de Servicios (M09) | Cliente HTTP para consumir la API REST desde la aplicación de escritorio. |
| **IntelliJ IDEA** | Entornos de Desarrollo (M02) | IDE profesional con soporte completo para Spring Boot y JavaFX. |

---

### **Objetivos:**

#### **Objetivos generales:**
1. Desarrollar una aplicación funcional de escritorio con arquitectura cliente-servidor REST que resuelva un problema real de gestión de reservas.
2. Implementar todas las capas de una aplicación empresarial: presentación (JavaFX), negocio (Spring Boot) y datos (JPA/MySQL).
3. Demostrar la integración de tecnologías aprendidas a lo largo del ciclo formativo en un proyecto unificado.

#### **Objetivos específicos (funcionalidades concretas):**
1. **Sistema de autenticación y roles:** Permitir el inicio de sesión seguro (BCrypt) con dos roles: Administrador y Cliente.
2. **Registro automático de clientes:** Los clientes pueden registrarse con DNI, nombre, apellidos, email, teléfono y contraseña, con validaciones de unicidad y formato.
3. **Gestión completa de cortadores (CRUD):** El administrador puede crear, consultar, modificar y desactivar cortadores, incluyendo datos personales, especialidad y horario fijo semanal (L-V 10:00-18:00).
4. **Definición de servicios fijos:** La aplicación ofrecerá tres tipos de servicio predefinidos (jamón 2h, paleta 1h, embutido 30 min) con precios informativos.
5. **Visualización de disponibilidad en calendario interactivo:** El cliente podrá seleccionar fecha y servicio, y el sistema mostrará una matriz de cortadores y slots de 30 minutos indicando disponibilidad en tiempo real.
6. **Creación de reservas con validaciones:** El sistema permitirá reservar un servicio siempre que el cliente no supere los límites (2/día, 4/semana) y el cortador tenga disponibilidad sin solapamientos y no exceda su carga máxima (3 jamones/día).
7. **Gestión de estados de reserva:** Las reservas tendrán cuatro estados (Pendiente, Confirmada, Realizada, Cancelada), actualizándose automáticamente tras la fecha de finalización.
8. **Modificación y cancelación de reservas:** Los clientes podrán modificar o cancelar sus reservas futuras siempre que queden al menos 24 horas antes del inicio.
9. **Historial de reservas por cliente:** Cada cliente podrá consultar todas sus reservas pasadas y futuras, filtradas por estado.
10. **Notificaciones simuladas:** Ante cada acción de creación, modificación o cancelación, se generará un registro en la tabla de notificaciones (log) que podrá consultar el administrador.
11. **Bloqueo automático del sistema de reservas:** Si no hay ningún cortador activo, la aplicación impedirá realizar nuevas reservas, mostrando un mensaje informativo.
12. **Panel de administración completo:** El administrador tendrá acceso a un dashboard con la lista de todas las reservas, posibilidad de cancelarlas, y gestión de usuarios y cortadores.

---

### **Justificación de la elección de la temática:**
He elegido este proyecto porque combina varios intereses personales y profesionales. Por un lado, siempre me ha atraído el sector gastronómico y de productos de calidad, como el jamón ibérico, y detecté una oportunidad de aplicar la tecnología a un nicho muy concreto que actualmente gestiona sus reservas de forma manual. 

Con este proyecto pretendo aportar una solución real, sencilla e intuitiva que permita a pequeñas tiendas especializadas digitalizar sus procesos de reserva, mejorando la experiencia del cliente y optimizando la carga de trabajo de los cortadores. A nivel formativo, el proyecto me permitirá afianzar conceptos clave del ciclo: diseño de bases de datos relacionales, desarrollo de APIs REST con Spring Boot, persistencia con JPA/Hibernate, creación de interfaces de usuario con JavaFX e integración cliente-servidor. 

Además, considero que es un proyecto perfectamente acotado, realista para los plazos de entrega y lo suficientemente completo para demostrar todas las competencias adquiridas durante el ciclo. La originalidad de la temática y la aplicación práctica de tecnologías demandadas en el mercado laboral (Spring Boot, JPA, JavaFX, MySQL) supondrán un valor añadido tanto en mi formación como en mi futuro perfil profesional.

---

✅ **La propuesta cumple con todos los requisitos de la normativa:**
- Título claro y descriptivo.
- Resumen breve con funcionalidades principales.
- Relación explícita de tecnologías con los módulos del ciclo.
- Objetivos concretos, medibles y alcanzables (12 funcionalidades).
- Justificación personal y profesional sólida.
- Tecnologías alineadas con la tabla de ILERNA (las no listadas se justifican).
- Compromiso de originalidad implícito.

Ya solo queda que la revises, añadas tus datos personales y la entregues en la tarea habilitada entre el **29 de septiembre y el 16 de octubre de 2025**. ¡Mucha suerte!