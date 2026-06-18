# Documentación para la Memoria del TFG

**Título: 4.1. Inicialización del Subsistema Backend**

**Objetivo:**
Establecer la estructura base del proyecto servidor utilizando el framework Spring Boot, asegurando la correcta gestión de dependencias y la configuración del entorno de ejecución sobre la JVM.

**Desarrollo:**
Se ha procedido a la generación del módulo `backend` utilizando el inicializador de Spring (Spring Initializr) integrado en IntelliJ IDEA Ultimate. Se han establecido los siguientes parámetros de configuración:

* **Gestor de Dependencias:** Maven.
* **Lenguaje:** Java (JDK 21 LTS).
* **Empaquetado:** JAR.
* **Metadatos del Artefacto:** Group `com.hambooking`, Artifact `backend`.

**Selección de Dependencias:**
Para cubrir los requisitos funcionales del sistema, se han inyectado las siguientes dependencias en el archivo `pom.xml`:

1. **Spring Web:** Para el despliegue del contenedor Tomcat embebido y la exposición de endpoints RESTful.
2. **Spring Data JPA:** Para la capa de persistencia y abstracción de consultas SQL mediante Hibernate.
3. **MySQL Driver:** Conector JDBC para la comunicación con la base de datos relacional.
4. **Lombok:** Librería para la reducción de código repetitivo (boilerplate) mediante anotaciones.
5. **Spring Boot DevTools:** Herramientas para mejorar la experiencia de desarrollo (hot-swapping y reinicio automático).

**Resultado de la Prueba de Concepto:**
Tras la configuración inicial del archivo `application.properties`, se ha ejecutado la clase principal `BackendApplication`. El sistema ha inicializado correctamente el contexto de Spring y ha desplegado el servidor en el puerto `8080` en un tiempo de 3.157 segundos, validando la integridad de la arquitectura base.

---
## 1. El Concepto Clave: "Convention over Configuration"

Antiguamente (hace 10 años), configurar un proyecto Spring requería días escribiendo ficheros XML gigantescos.
Lo que hemos hecho con **Spring Boot** se basa en el principio de **"Convención sobre Configuración"**.

* **¿Qué significa?** Spring asume cosas por ti.
* **Ejemplo:** "Si veo que tienes la librería `mysql-driver` en tu proyecto, *asumo* que querrás conectarte a una base de datos MySQL, así que intento configurarla automáticamente al arrancar".
* **Por eso falló (y funcionó):** Spring vio el driver, intentó conectarse (convención), no pudo (porque no hay BD), pero arrancó el resto.

---

## 2. ¿Qué ha hecho el IDE (IntelliJ) por ti? (Scaffolding)

Cuando le diste a "Create", IntelliJ no solo creó carpetas. Hizo **Scaffolding** (Andamiaje).
Ha creado la **Estructura Estándar de Maven**:

```text
backend/
├── pom.xml                   <-- El cerebro (Gestor de proyecto)
├── src/
│   ├── main/
│   │   ├── java/             <-- Tu código fuente
│   │   └── resources/        <-- Configuración (application.properties, html, etc.)
│   └── test/                 <-- Tests unitarios (JUnit ya viene instalado)

```

**¿Por qué es importante?** Cualquier desarrollador Java del mundo que descargue tu proyecto sabrá exactamente dónde buscar el código. Es un estándar de la industria.

---

## 3. Análisis del Código Inyectado

Solo se han generado dos archivos críticos. Vamos a leerlos como si fuéramos el compilador.

#### A. El Cerebro: `pom.xml` (Project Object Model)

Este archivo XML le dice a Maven qué necesita tu proyecto.

* **Lo que inyectamos:** El bloque `<dependencies>`.
* Ahí están `spring-boot-starter-web`, `spring-boot-starter-data-jpa`, etc.


* **La magia:** Fíjate que no pusimos versiones (ej: `3.1.5`). Solo pusimos el nombre.
* **¿Por qué?** Porque arriba del todo hay un `<parent>spring-boot-starter-parent</parent>`. Ese "padre" gestiona las versiones por ti para que nunca sean incompatibles entre sí. Esto te evita el "Infierno de las Dependencias" (Dependency Hell).



#### B. El Corazón: `BackendApplication.java`

Este es el archivo que arrancó y viste en la consola. Tiene solo 10 líneas, pero hace **todo** el trabajo.

```java
package com.hambooking.backend;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication  // <--- ¡LA CLAVE DE TODO!
public class BackendApplication {

	public static void main(String[] args) {
		SpringApplication.run(BackendApplication.class, args);
	}

}

```

**¿Qué hace realmente la anotación `@SpringBootApplication`?**
Es una "meta-anotación" que agrupa 3 poderes:

1. **`@Configuration`:** Dice "Esta clase puede definir Beans (objetos) de Java".
2. **`@EnableAutoConfiguration`:** Dice "Spring, escanea mi `pom.xml`, mira qué librerías tengo y configúralas tú solo". (Esto es lo que intentó conectar con MySQL).
3. **`@ComponentScan`:** Dice "Busca en este paquete (`com.hambooking.backend`) y en todos sus hijos cualquier clase que yo cree".
* *Importancia:* Gracias a esto, cuando crees mañana el `UsuarioController`, Spring lo encontrará automáticamente sin que tú lo registres manualmente.



---

### 4. ¿Por qué Tomcat "Embebido"?

En el ciclo de DAM tradicional, quizás instalabas un servidor Tomcat en Windows (XAMPP o similar) y desplegabas un archivo `.war`.
Aquí **no**.

* Spring Boot trae un **Tomcat dentro del archivo JAR**.
* **Ventaja:** Tu aplicación es "autocontenida". No dependes de tener un servidor instalado en el ordenador del cliente. Solo necesitas Java.
* **Ejecución:** Al hacer `run`, arranca el Tomcat interno en el puerto 8080.

---

### 5. Resumen: ¿Qué hemos logrado con el Issue #1?

| Concepto | Antes (Java Clásico) | Ahora (Tu TFG) | Por qué es mejor |
| --- | --- | --- | --- |
| **Dependencias** | Descargar .jar y ponerlos en el Classpath | **Maven** (`pom.xml`) | Gestión automática y actualizaciones fáciles. |
| **Servidor** | Instalar Tomcat/Glassfish externo | **Tomcat Embebido** | Portabilidad total. "Build once, run anywhere". |
| **Configuración** | XMLs complejos (`web.xml`) | **Anotaciones** (`@SpringBootApplication`) | Código más limpio y rápido de escribir. |
| **Arranque** | Desplegar WAR en servidor | **`public static void main`** | Arranca como una aplicación normal de Java. |

**Conclusión para tu memoria:**
Has establecido una arquitectura basada en **Microservicios** (aunque sea un monolito ahora mismo, la estructura lo permite), utilizando **Inversión de Control (IoC)** gestionada por Spring, lo que desacopla tu código y facilita el mantenimiento.

## ✅ Cerrando el Issue #1