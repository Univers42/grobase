📝 Documentación para la Memoria del TFG: Entidad Carver
[Guarda esto junto a lo de User para tu apartado de Implementación de Persistencia]

La clase Carver actúa como una extensión del perfil de usuario (User), implementando el patrón de diseño orientado a objetos sobre bases de datos relacionales para separar los datos de autenticación de los atributos puramente profesionales.

Propietario de la Relación (Owning Side): En la relación 1:1 con User, Carver es la entidad propietaria, lo que se define mediante @JoinColumn(name = "user_id", unique = true). Esto asegura que el ID del usuario se guarde como clave foránea en la tabla carvers, garantizando la integridad referencial y cumpliendo la restricción de unicidad estipulada en la base de datos.

Validación de Reglas de Negocio: Se han implementado validaciones críticas de negocio en la capa de persistencia utilizando @Min y @Max. Por ejemplo, maxHamsPerDay asegura que un cortador no pueda tener un límite negativo ni exceder una carga de trabajo humana lógica (máximo 10 servicios), protegiendo al sistema de datos corruptos generados en la capa de servicios.

Seguridad en la Representación de Datos (toString): Para mantener la consistencia al trazar logs y evitar excepciones de carga perezosa (LazyInitializationException), el método toString extrae únicamente la clave primaria de la entidad asociada (user.getId()) en lugar de intentar serializar el objeto User completo.

📝 Documentación para la Memoria del TFG: Entidad Service
[Añade esto a tu sección de Implementación del Backend]

La entidad Service funciona como el catálogo parametrizable del modelo de negocio, mapeando la tabla services. Aunque conceptualmente sencilla, su implementación cuenta con detalles técnicos cruciales para el manejo de datos de facturación y tiempos de reserva.

Precisión Financiera (Manejo de Moneda): Para mapear el campo DECIMAL(10,2) de MySQL, se utiliza la clase java.math.BigDecimal. A diferencia de Double o Float, BigDecimal garantiza una precisión absoluta en cálculos financieros, evitando los clásicos errores de redondeo de la coma flotante en Java. Se restringe con @DecimalMin("0.0") para impedir servicios con precio negativo.

Integridad de Datos Temporales: El campo durationMinutes se asegura con @Positive. Esta validación es crítica, ya que la lógica de negocio futura (Servicios/Controladores) dependerá de este valor para sumar bloques de tiempo (slots) y calcular la hora de finalización (end_time) de las reservas.

Independencia Funcional (Relación Inversa): La clase cuenta con una relación @OneToMany(mappedBy = "service"). Al delegar el mapping a la reserva, se permite que los servicios existan de manera autónoma en el sistema. Los atributos largos se han optimizado utilizando columnDefinition = "TEXT" para evitar el límite estándar de los VARCHAR(255).

📝 Documentación para la Memoria del TFG: Entidad Reservation
[Para añadir a tus apuntes]

La entidad Reservation representa el Core Domain (Dominio Central) del sistema HamBooking. Actúa como el nexo principal, consolidando las relaciones entre las entidades User, Carver y Service mediante relaciones @ManyToOne.

Mapeo Temporal Moderno: Se ha empleado el paquete java.time (LocalDate y LocalTime) introducido en Java 8 para mapear con alta precisión las columnas DATE y TIME de MySQL, abandonando los obsoletos java.util.Date.

Traslado de Lógica de Negocio al Backend: Dado que las bases de datos relacionales prohíben funciones dependientes del tiempo (como CURDATE()) en sus restricciones CHECK, la validación de "reservas futuras" se ha implementado en la capa de persistencia de Java mediante la anotación de Bean Validation @Future en el atributo reservationDate.

Cálculo Pre-Persistencia: La clase encapsula su propia lógica de negocio mediante el método calculateEndTime(). Este método garantiza la integridad de los datos calculando la hora de finalización en base al servicio seleccionado, evitando que la capa de Controladores deba realizar aritmética de fechas, adhiriéndose así al principio de Fat Models, Skinny Controllers.

📝 Documentación para la Memoria del TFG: Entidad Notification
[Último bloque para tu apartado de Implementación de la Capa de Persistencia]

La entidad Notification implementa el registro de auditoría y comunicación del sistema. Sirve como registro histórico inmutable de los correos electrónicos o alertas generadas por los cambios de estado en las reservas.

Relaciones Flexibles (@ManyToOne Nullable): A diferencia de las dependencias estrictas en la entidad Reservation, la Foreign Key reservation_id en Notification permite valores nulos (nullable = true implícito). Esto otorga flexibilidad arquitectónica para que en un futuro se puedan enviar notificaciones genéricas de sistema (ej: recuperación de contraseñas, avisos globales) que no estén atadas al ciclo de vida de una reserva concreta.

Trazabilidad y Tipado Fuerte: Se han implementado dos enumeraciones (RecipientType y NotificationType) almacenadas como STRING en la base de datos. Esto previene la inyección de categorías inválidas y facilita la segmentación de datos para futuras auditorías o paneles de administración.

Protección de Auditoría: El campo sentAt está gestionado por el proveedor de persistencia a través de @CreationTimestamp y blindado con updatable = false. Esto asegura que, una vez persistido el registro de envío, ni siquiera un proceso interno pueda adulterar la marca de tiempo de la notificación.

