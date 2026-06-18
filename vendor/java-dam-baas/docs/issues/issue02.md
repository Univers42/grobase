## 📄 Documentación Técnica: Inicialización del Frontend

### 4.2. Inicialización del Subsistema Frontend (Cliente de Escritorio)

**Objetivo:**
Establecer la arquitectura base de la aplicación cliente utilizando **JavaFX**, asegurando una estricta separación entre la lógica de presentación y la lógica de negocio, así como preparar el entorno para la comunicación asíncrona con el Backend.

**Tecnologías y Arquitectura:**
Se ha optado por una arquitectura **MVC (Modelo-Vista-Controlador)** nativa de JavaFX, gestionada mediante un módulo Maven independiente (`frontend`) para garantizar el desacoplamiento del servidor.

* **Framework Gráfico:** JavaFX 21 (LTS).
* **Gestión de Dependencias:** Maven.
* **Sistema de Módulos:** Java Platform Module System (JPMS).

**1. Gestión de Dependencias (`pom.xml`):**
Para dotar al cliente de las capacidades necesarias, se han inyectado las siguientes librerías en el descriptor del proyecto:

* **`javafx-controls`:** Provee los componentes gráficos estándar (Botones, Tablas, Campos de texto).
* **`javafx-fxml`:** Permite definir las interfaces de usuario mediante archivos XML (`.fxml`), separando el diseño visual del código Java.
* **`controlsfx`:** Librería de extensiones que aporta componentes UI avanzados y notificaciones nativas de escritorio.
* **`jackson-databind`:** *Componente crítico.* Se ha incluido anticipadamente para permitir la serialización y deserialización de objetos Java a formato JSON, necesaria para el consumo de la API REST del backend.

**2. Configuración del Sistema de Módulos (`module-info.java`):**
Dado que JavaFX opera bajo el sistema modular de Java 9+, se ha configurado explícitamente la exposición de paquetes para permitir la inyección de dependencias y la reflexión en tiempo de ejecución:

```java
module com.hambooking.frontend {
    // Requerimientos del sistema
    requires javafx.controls;
    requires javafx.fxml;
    requires org.controlsfx.controls;
    requires com.fasterxml.jackson.databind;

    // Apertura para reflexión (necesario para cargar FXML y mapear JSON)
    opens com.hambooking.frontend to javafx.fxml;
    
    // Exportación del paquete principal
    exports com.hambooking.frontend;
}

```

**3. Estructura y Refactorización del Código Base:**
Se ha eliminado el código autogenerado por defecto ("Hello World") para establecer una nomenclatura acorde al dominio del problema (**HamBooking**):

* **Clase Principal (`HamBookingApp.java`):** Punto de entrada de la aplicación. Configura el escenario principal (`Stage`), carga la vista inicial y define las dimensiones de la ventana.
* **Controlador Principal (`MainController.java`):** Gestiona la lógica de interacción de la vista principal, sirviendo como intermediario entre la interfaz y los servicios de datos.
* **Vista Principal (`main-view.fxml`):** Definición declarativa de la interfaz gráfica inicial.

**4. Configuración del Ciclo de Construcción:**
Se ha configurado el plugin `javafx-maven-plugin` para permitir la ejecución de la aplicación desde la línea de comandos, asegurando la portabilidad entre diferentes entornos de desarrollo (IDEs) y sistemas operativos (Linux Fedora, Windows, macOS).

* **Comando de ejecución:** `mvn clean javafx:run`
* **Clase Main configurada:** `com.hambooking.frontend.HamBookingApp`

---

### 🧠 Análisis para tu Defensa (El "Por qué")

Si el tribunal te pregunta por qué te ha costado configurar esto o por qué usas estos archivos, aquí tienes la "chuleta":

1. **¿Por qué `jackson` en el frontend?**
* *Respuesta:* "Porque el Backend me envía texto en formato JSON. Java no entiende JSON nativamente, así que uso Jackson para convertir ese texto en objetos Java (`Usuario`, `Reserva`) que mi interfaz pueda mostrar."


2. **¿Por qué `module-info.java`?**
* *Respuesta:* "Desde Java 9, el JDK es modular. JavaFX necesita permisos explícitos (`opens`) para poder leer mis archivos FXML y mis controladores privados usando reflexión. Sin este archivo, la aplicación lanzaría excepciones de seguridad al arrancar."


3. **¿Por qué separar Backend y Frontend en módulos distintos?**
* *Respuesta:* "Para simular una arquitectura real de microservicios o cliente-servidor distribuida. Esto me permite, en el futuro, cambiar el frontend por una web (React/Angular) sin tocar ni una línea del backend, o viceversa."

---
