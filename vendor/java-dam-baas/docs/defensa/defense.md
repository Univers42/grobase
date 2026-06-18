### 🗄️ FASE 1: La Base (Datos y Persistencia)
**Objetivo:** Dominar cómo se guardan los datos y cómo Java se comunica con MySQL.

* **1. Base de Datos (`database/schema.sql`):**
    * *Qué estudiar:* Repasa tu script SQL final. Entiende las relaciones 1:1, 1:N y las constraints (UNIQUE, CHECK).
    * *Pregunta de Tribunal:* *"¿Por qué separaste `User` de `Carver` en dos tablas en lugar de ponerlo todo en una?"* (Respuesta: Normalización y separación de responsabilidades, no todos los usuarios son cortadores).
* **2. Entidades JPA (`backend/.../model/entity/*.java`):**
    * *Qué estudiar:* Estudia cómo mapeaste las tablas. Entiende las anotaciones de Lombok (`@Data`, `@Builder`), las de JPA (`@Entity`, `@OneToMany`) y el `FetchType.LAZY`.
    * *Pregunta de Tribunal:* *"¿Qué es el problema N+1 en Hibernate y cómo lo has evitado?"* o *"¿Por qué usas FetchType.LAZY en las colecciones?"*
* **3. Repositorios (`backend/.../repository/*.java`):**
    * *Qué estudiar:* Repasa tus interfaces `JpaRepository`. Fíjate en los métodos personalizados (`findByEmail`, consultas derivadas).

### 🧠 FASE 2: El Cerebro (Lógica de Negocio y Excepciones)
**Objetivo:** Explicar cómo el sistema toma decisiones y maneja errores.

* **1. Servicios (`backend/.../service/*.java`):**
    * *Qué estudiar:* Aquí está el *Core*. Céntrate en `ReservationService.java` y `AvailabilityService.java`. ¿Cómo calculas si un cortador está libre? ¿Cómo se procesa una reserva? Entiende la anotación `@Transactional`.
    * *Pregunta de Tribunal:* *"¿Qué ocurre si la base de datos falla a mitad de crear una reserva y una notificación?"* (Respuesta: `@Transactional` hace un rollback y no se guarda nada a medias).
* **2. Excepciones (`backend/.../exception/*.java`):**
    * *Qué estudiar:* El `GlobalExceptionHandler.java` es una joya. Explica cómo interceptas errores de Java y devuelves un `ErrorResponse` limpio en formato JSON al frontend.

### 🌐 FASE 3: La Frontera (API REST y Seguridad)
**Objetivo:** Defender cómo se exponen los datos al mundo exterior de forma segura.

* **1. Controladores (`backend/.../controller/*.java`):**
    * *Qué estudiar:* Revisa `ReservationController.java` y `AuthController.java`. Entiende las anotaciones `@RestController`, `@GetMapping`, `@PostMapping` y el manejo de códigos de estado HTTP (200 OK, 201 Created, 404 Not Found).
* **2. El Patrón DTO (`backend/.../dto/*.java`):**
    * *Qué estudiar:* Compara un `ReservationResponseDTO` con la entidad `Reservation`.
    * *Pregunta de Tribunal:* *"¿Por qué usas DTOs en lugar de devolver las entidades JPA directamente en el Controller?"* (Respuesta: Por seguridad, para no exponer el *PasswordHash* del usuario, y para evitar ciclos infinitos al serializar JSON por culpa de las relaciones bidireccionales).
* **3. Seguridad (`backend/.../config/SecurityConfig.java`):**
    * *Qué estudiar:* ¿Cómo proteges los endpoints? ¿Has implementado JWT, Basic Auth o sesiones? Ten claro el flujo de `LoginRequestDTO` -> `AuthController` -> `LoginResponseDTO`.



[Image of MVC architecture pattern]


### 🖥️ FASE 4: El Cliente (Frontend JavaFX)
**Objetivo:** Explicar cómo el usuario interactúa con la API REST.

* **1. Vistas y Controladores (`frontend/.../fxml/*.fxml` y `frontend/.../controllers/*.java`):**
    * *Qué estudiar:* Entiende el patrón MVC en JavaFX. Cómo un botón en `booking-form.fxml` llama a un método en `BookingController.java`.
* **2. Comunicación con el Backend (`frontend/.../service/ApiClient.java`):**
    * *Qué estudiar:* Este archivo es crítico. Explica cómo JavaFX usa un cliente HTTP (probablemente `java.net.http.HttpClient` o similar) para enviar JSON al backend y cómo mapea el JSON de respuesta a tus objetos `AppDTO`.
    * *Pregunta de Tribunal:* *"¿El frontend ataca directamente a la base de datos?"* (Respuesta: NO. Arquitectura Cliente-Servidor pura. El frontend solo habla con la API REST, lo que permite que mañana podamos hacer una App en Android sin tocar el backend).
* **3. Gestión de Sesión (`SessionManager.java`):**
    * *Qué estudiar:* Cómo mantienes el estado del usuario (token o datos) mientras navega por `admin-dashboard.fxml` o `client-dashboard.fxml`.

### 🧪 FASE 5: Calidad del Software (Testing y Documentación)
**Objetivo:** Demostrar que eres un ingeniero, no solo un "picador de código".

* **1. Tests Unitarios (`backend/src/test/.../*.java`):**
    * *Qué estudiar:* El tribunal se fijará mucho en esta carpeta. Repasa tus `UserTest`, `ReservationTest`, etc. Explica qué es JUnit, qué son los mocks (si los usas) y cómo pruebas las reglas de negocio aisladas de la base de datos.
    * *Pregunta de Tribunal:* *"¿Por qué has hecho tests unitarios?"* (Respuesta: Para garantizar que futuras refactorizaciones no rompan la lógica de negocio, asegurando la calidad y mantenibilidad del software).
* **2. Pruebas HTTP (`backend/src/test/*.http`):**
    * *Qué estudiar:* Muestra cómo utilizabas estos archivos para probar la API antes de construir el frontend en JavaFX.

---

### 💡 Plan de Acción Diario Recomendado (De cara a la defensa)

1.  **Día 1-2 (Backend Core):** Lee los modelos, los DTOs y los Repositorios. Dibuja el diagrama de Entidad-Relación en un papel de memoria.
2.  **Día 3-4 (Lógica y API):** Recorre el camino de una petición. Entra por el `ReservationController`, baja al `ReservationService`, llega al `ReservationRepository` y mira qué devuelve.
3.  **Día 5 (Frontend):** Sigue el flujo inverso. Desde `ApiClient`, mira cómo se llama al backend y cómo se pinta en el `Controller` de JavaFX.
4.  **Día 6 (Testing):** Ejecuta la batería de tests y comprende por qué cada test está escrito.
5.  **Día 7 (Simulacro):** Abre la aplicación, ponla a funcionar en directo, y narra en voz alta lo que ocurre a nivel de código cada vez que haces clic en un botón.

¿Por qué fase te gustaría empezar a repasar a fondo? Podemos coger cualquier archivo de tu árbol (por ejemplo, el `ApiClient.java` o el `ReservationService.java`) y desgranarlo para prepararte el "speech" exacto que darías al tribunal.