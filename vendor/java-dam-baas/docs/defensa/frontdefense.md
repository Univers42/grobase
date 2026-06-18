│ Plan de Acción: Refactorización a "Clean Frontend"                                  │
│                                                                                     │
│ Este plan establece una estrategia de refactorización incremental y exhaustiva para │
│ el frontend de HamBooking. Se ejecutará paso a paso, priorizando la precisión, la   │
│ revisión continua, la documentación (Javadoc) y las pruebas tras cada fase o        │
│ agrupación lógica.                                                                  │
│                                                                                     │
│ La BASE_URL se mantendrá hardcodeada por el momento.                                │
│                                                                                     │
│ Fase 1: Infraestructura Base (Navegación y Alertas)                                 │
│ Objetivo: Centralizar funciones transversales para reducir la duplicación de código │
│ en los controladores.                                                               │
│  * 1.1 ViewManager: Crear un servicio centralizado para la gestión y cambio de      │
│    escenas (FXML), eliminando los métodos navigateTo duplicados.                    │
│  * 1.2 AlertHelper: Implementar una utilidad estática para uniformar los diálogos   │
│    de error, información y confirmación (Alert).                                    │
│  * 1.3 Documentación y Validación:                                                  │
│    * Añadir Javadoc estándar a ViewManager y AlertHelper.                           │
│    * Refactorizar un controlador piloto (ej. LoginController) para validar el       │
│      funcionamiento.                                                                │
│    * Revisión de código y aprobación antes de continuar.                            │
│                                                                                     │
│ Fase 2: Refactorización de DTOs                                                     │
│ Objetivo: Desacoplar las clases internas masivas (AppDTO, AuthDTO) en archivos      │
│ individuales que representen fielmente el contrato con el backend.                  │
│  * 2.1 Extracción: Mover cada clase interna (ej. UserResponse, LoginRequest) a su   │
│    propio archivo dentro de com.hambooking.frontend.dto.                            │
│  * 2.2 Documentación: Añadir Javadoc descriptivo a cada DTO y a sus atributos       │
│    principales.                                                                     │
│  * 2.3 Validación: Revisar que la deserialización con Jackson sigue funcionando y   │
│    compila sin errores. Revisión de código.                                         │
│                                                                                     │
│ Fase 3: Capa de Servicios (Lógica de Negocio)                                       │
│ Objetivo: Aislar los controladores de los detalles HTTP (ApiClient) introduciendo   │
│ servicios específicos.                                                              │
│  * 3.1 Creación de Servicios: Implementar AuthService, ReservationService,          │
│    UserService, CarverService, etc.                                                 │
│  * 3.2 Integración: Refactorizar los controladores para que consuman estos          │
│    servicios.                                                                       │
│  * 3.3 Documentación y Pruebas:                                                     │
│    * Javadoc exhaustivo en las interfaces/clases de servicio.                       │
│    * Implementar tests unitarios para los servicios (validando la lógica sin        │
│      necesidad de levantar UI).                                                     │
│    * Revisión de código de todos los servicios.                                     │
│                                                                                     │
│ Fase 4: Modernización de Concurrencia en Controladores                              │
│ Objetivo: Reemplazar el uso de new Thread(...) manual por las herramientas          │
│ oficiales de concurrencia de JavaFX (Task y Service).                               │
│  * 4.1 Migración a Task/Service: Actualizar los controladores para delegar llamadas │
│    de red a Task, manejando onSucceeded, onFailed y actualizando la UI de forma     │
│    segura.                                                                          │
│  * 4.2 Mejora de UX: Integrar deshabilitación de botones y cursores de carga        │
│    durante las tareas asíncronas.                                                   │
│  * 4.3 Documentación y Pruebas de UI:                                               │
│    * Javadoc en los controladores refactorizados.                                   │
│    * Introducir TestFX para automatizar la validación de los flujos principales     │
│      (Login, Registro, Reserva) y asegurar que la UI no se bloquea.                 │
│    * Revisión final.   